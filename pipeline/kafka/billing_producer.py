"""
billing_producer.py
-------------------
Reads new records from billing_audit_log (since last watermark) and publishes
them to the appropriate Kafka topic.

Topic routing:
    invoices table      → billing.invoice.created
    subscriptions table → billing.subscription.changed
    (all other tables skipped — not in Phase 11 scope)

Idempotency design:
    Each message is keyed by billing_audit_log.id (UUID). The producer
    advances the watermark ONLY after all messages in a batch are confirmed
    delivered (producer.flush() succeeds). If the process dies mid-batch,
    the same records are re-published on the next run — the consumer handles
    deduplication on the S3 write side using the same key.

Watermark:
    Stored as Airflow Variable 'billing_producer_watermark' (ISO 8601
    timestamp). Defaults to epoch on first run. Updated atomically after
    a confirmed flush — never advanced on partial delivery.

JD requirement addressed:
    Large-scale data pipelines — collection, processing, curation, publishing
    ETL/ELT with Kafka
"""

import json
import logging
import os

import psycopg2
import psycopg2.extras
from confluent_kafka import Producer
from confluent_kafka.admin import AdminClient, NewTopic

log = logging.getLogger(__name__)

# Topic routing — maps billing_audit_log.table_name to Kafka topic.
# Naming convention: event-driven, past tense, dot-separated hierarchy.
TOPIC_MAP = {
    "invoices": "billing.invoice.created",
    "subscriptions": "billing.subscription.changed",
}

KAFKA_BOOTSTRAP = os.environ["KAFKA_BOOTSTRAP_SERVERS"]
DB_CONFIG = {
    "host": os.environ["BILLING_DB_HOST"],
    "port": os.environ["BILLING_DB_PORT"],
    "dbname": os.environ["BILLING_DB_NAME"],
    "user": os.environ["BILLING_DB_USER"],
    "password": os.environ["BILLING_DB_PASSWORD"],
}


def ensure_topics(bootstrap_servers: str) -> None:
    """
    Create Kafka topics if they do not already exist.
    Safe to call repeatedly — existing topics are left unchanged.
    Single partition, replication factor 1: appropriate for a single-broker
    KRaft cluster. Adjust for multi-broker production deployments.
    """
    admin = AdminClient({"bootstrap.servers": bootstrap_servers})
    existing = admin.list_topics(timeout=10).topics.keys()

    to_create = [
        NewTopic(topic, num_partitions=1, replication_factor=1)
        for topic in TOPIC_MAP.values()
        if topic not in existing
    ]

    if not to_create:
        log.info("All topics already exist — skipping creation")
        return

    futures = admin.create_topics(to_create)
    for topic, future in futures.items():
        try:
            future.result()
            log.info("Created topic: %s", topic)
        except Exception as e:
            # Topic may have been created by a concurrent process — safe to ignore
            log.warning("Topic %s: %s", topic, e)


def get_watermark() -> str:
    """
    Read the last-processed timestamp from Airflow Variable.
    Returns epoch string on first run so all existing audit log records
    are included in the first batch.
    """
    from airflow.models import Variable
    return Variable.get(
        "billing_producer_watermark",
        default_var="1970-01-01T00:00:00+00:00",
    )


def set_watermark(ts: str) -> None:
    """Advance the watermark. Called only after a confirmed flush."""
    from airflow.models import Variable
    Variable.set("billing_producer_watermark", ts)
    log.info("Watermark advanced to: %s", ts)


def delivery_report(err, msg):
    """
    Callback fired by producer.poll() / producer.flush() for each message.
    Raising here causes flush() to raise, which prevents watermark advancement
    on partial delivery — the safe failure mode.
    """
    if err:
        log.error("Delivery failed for key %s: %s", msg.key(), err)
        raise RuntimeError(f"Kafka delivery failed for key {msg.key()}: {err}")
    log.debug(
        "Delivered key=%s to %s [partition %d offset %d]",
        msg.key(), msg.topic(), msg.partition(), msg.offset(),
    )


def run_producer(**context):
    """
    Main entry point — called by Airflow PythonOperator.

    Queries billing_audit_log for records newer than the current watermark,
    publishes each to its routed Kafka topic, then advances the watermark
    after a confirmed flush. Idempotent: a failed flush leaves the watermark
    unchanged so the same batch is retried on the next DAG run.
    """
    watermark = get_watermark()
    log.info("Producer starting — watermark: %s", watermark)

    ensure_topics(KAFKA_BOOTSTRAP)

    producer = Producer({
        "bootstrap.servers": KAFKA_BOOTSTRAP,
        "acks": "all",           # wait for broker to confirm write
        "retries": 3,
        "retry.backoff.ms": 500,
    })

    conn = psycopg2.connect(**DB_CONFIG)
    cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    # Pull records for routed tables only, ordered oldest-first so the
    # watermark always advances monotonically.
    cur.execute(
        """
        SELECT
            id,
            table_name,
            row_id,
            old_status,
            new_status,
            changed_at,
            changed_by
        FROM billing_audit_log
        WHERE changed_at > %s
          AND table_name = ANY(%s)
        ORDER BY changed_at ASC
        """,
        (watermark, list(TOPIC_MAP.keys())),
    )

    rows = cur.fetchall()
    log.info("Found %d new audit log records since %s", len(rows), watermark)

    if not rows:
        log.info("No new records — nothing to publish")
        cur.close()
        conn.close()
        return

    new_watermark = watermark
    published = 0

    for row in rows:
        topic = TOPIC_MAP[row["table_name"]]

        # Payload includes audit_log_id at the top level so the consumer
        # can derive the S3 key without parsing nested fields.
        # billing_audit_log tracks status transitions (old_status -> new_status)
        # on a given row_id, not full before/after row snapshots.
        payload = {
            "audit_log_id": str(row["id"]),
            "table_name": row["table_name"],
            "row_id": str(row["row_id"]),
            "old_status": row["old_status"],
            "new_status": row["new_status"],
            "changed_at": row["changed_at"].isoformat(),
            "changed_by": row["changed_by"],
        }

        producer.produce(
            topic=topic,
            key=str(row["id"]),                         # billing_audit_log.id
            value=json.dumps(payload, default=str),
            on_delivery=delivery_report,
        )
        producer.poll(0)    # trigger delivery callbacks without blocking
        new_watermark = row["changed_at"].isoformat()
        published += 1

    # flush() blocks until all in-flight messages are confirmed or fails with
    # an exception — the watermark is only advanced on success.
    producer.flush(timeout=30)
    log.info("Published %d events to Kafka", published)

    set_watermark(new_watermark)

    cur.close()
    conn.close()