"""
billing_consumer.py
-------------------
Reads billing events from Kafka topics and writes each event as a JSON file
to the S3 raw landing zone.

S3 key structure:
    raw/{topic}/{YYYY-MM-DD}/{audit_log_id}.json

    Example:
    raw/billing.invoice.created/2026-07-10/a1b2c3d4-...uuid....json

Idempotency design:
    Before writing, the consumer checks whether the S3 key already exists
    (HEAD request). If it does, the message is committed and skipped. This
    means re-running the consumer — or replaying Kafka offsets from earliest —
    will never produce duplicate files in S3.

Poll window:
    The consumer runs for POLL_TIMEOUT_SECONDS then exits cleanly. This makes
    it safe to call from an Airflow PythonOperator on a schedule rather than
    running as a long-lived daemon process.

Offset commit strategy:
    Manual commit (enable.auto.commit=False). Offsets are committed only after
    a confirmed S3 write or a confirmed duplicate skip. If the process dies
    before committing, the same message is redelivered on the next run and
    the S3 idempotency check handles it.

JD requirement addressed:
    Large-scale data pipelines — collection, processing, curation, publishing
    Data schemas, storage solutions, query interfaces
"""

import json
import logging
import os
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError
from confluent_kafka import Consumer, KafkaError, KafkaException

log = logging.getLogger(__name__)

KAFKA_BOOTSTRAP = os.environ["KAFKA_BOOTSTRAP_SERVERS"]
S3_BUCKET = os.environ["S3_RAW_LANDING_BUCKET"]
TOPICS = ["billing.invoice.created", "billing.subscription.changed"]

# How long to poll before exiting. Set to 60s so the Airflow task completes
# within a reasonable timeout. Increase if event volume is high enough that
# 60s is insufficient to drain the lag.
POLL_TIMEOUT_SECONDS = 60


def s3_key(topic: str, audit_log_id: str, event_date: str) -> str:
    """
    Derive a deterministic, human-readable S3 key from event metadata.
    Partitioned by date for efficient Iceberg ingestion in Phase 12.
    """
    return f"raw/{topic}/{event_date}/{audit_log_id}.json"


def key_exists(s3_client, bucket: str, key: str) -> bool:
    """
    Check if an S3 object already exists using a HEAD request.
    Returns True if the object exists, False if 404.
    Re-raises on any other error (permissions, network, etc.).
    """
    try:
        s3_client.head_object(Bucket=bucket, Key=key)
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] == "404":
            return False
        raise


def run_consumer(**context):
    """
    Main entry point — called by Airflow PythonOperator.

    Polls Kafka for up to POLL_TIMEOUT_SECONDS. For each message:
      1. Derives the S3 key from topic + audit_log_id + event date.
      2. Checks if the key already exists (idempotency guard).
      3. Writes the event JSON to S3 if the key is new.
      4. Commits the Kafka offset after a confirmed write or skip.

    Exits cleanly when the poll window expires or all partitions reach EOF.
    """
    s3 = boto3.client("s3")

    consumer = Consumer({
        "bootstrap.servers": KAFKA_BOOTSTRAP,
        "group.id": "billing-raw-landing-consumer",
        "auto.offset.reset": "earliest",    # start from beginning if no committed offset
        "enable.auto.commit": False,        # manual commit only
    })

    consumer.subscribe(TOPICS)
    log.info("Consumer subscribed to: %s", TOPICS)

    written = 0
    skipped = 0
    deadline = datetime.now(timezone.utc).timestamp() + POLL_TIMEOUT_SECONDS

    try:
        while datetime.now(timezone.utc).timestamp() < deadline:
            msg = consumer.poll(timeout=1.0)

            if msg is None:
                continue

            if msg.error():
                if msg.error().code() == KafkaError._PARTITION_EOF:
                    # All messages in this partition consumed — exit early
                    log.info(
                        "Reached end of partition %s[%d]",
                        msg.topic(), msg.partition(),
                    )
                    break
                raise KafkaException(msg.error())

            # Parse payload
            payload = json.loads(msg.value().decode("utf-8"))
            audit_log_id = payload["audit_log_id"]
            event_date = payload["changed_at"][:10]     # YYYY-MM-DD
            key = s3_key(msg.topic(), audit_log_id, event_date)

            # Idempotency check
            if key_exists(s3, S3_BUCKET, key):
                log.info("Duplicate — skipping: s3://%s/%s", S3_BUCKET, key)
                consumer.commit(message=msg)
                skipped += 1
                continue

            # Write to S3
            s3.put_object(
                Bucket=S3_BUCKET,
                Key=key,
                Body=json.dumps(payload, indent=2, default=str),
                ContentType="application/json",
            )

            # Commit offset only after confirmed S3 write
            consumer.commit(message=msg)
            log.info("Written: s3://%s/%s", S3_BUCKET, key)
            written += 1

    finally:
        consumer.close()
        log.info(
            "Consumer finished — written: %d | skipped (duplicate): %d",
            written, skipped,
        )
