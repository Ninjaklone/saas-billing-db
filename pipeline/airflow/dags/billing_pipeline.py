"""
billing_pipeline.py
-------------------
Airflow DAG: billing_pipeline

Schedule:   @hourly
Catchup:    False — historical hours are not backfilled. The producer
            watermark handles picking up from where the last run left off,
            regardless of how many scheduled intervals were missed.

Task flow:
    run_producer → run_consumer → verify_s3_landing

Idempotency:
    - run_producer: watermark-based. Re-running the same DAG interval does
      not re-publish already-published records (they are below the watermark).
    - run_consumer: S3 key existence check. Re-running never produces
      duplicate files.
    - verify_s3_landing: read-only, always safe to re-run.

Phase scope:
    Phase 11 — Postgres (via billing_audit_log) → Kafka → S3 raw landing zone.
    Phase 12 will add an Iceberg ingestion task after verify_s3_landing.

JD requirements addressed:
    Large-scale data pipelines — collection, processing, curation, publishing
    Orchestration with Airflow
    ETL/ELT with Kafka
"""

import logging
import os
import sys
from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.python import PythonOperator

# /opt/airflow/kafka_scripts is volume-mounted from ./pipeline/kafka
# in docker-compose.yml — this is where billing_producer and billing_consumer live.
sys.path.insert(0, "/opt/airflow/kafka_scripts")

from billing_producer import run_producer
from billing_consumer import run_consumer

log = logging.getLogger(__name__)

default_args = {
    "owner": "gara",
    "retries": 2,
    "retry_delay": timedelta(minutes=5),
    "email_on_failure": False,
    "depends_on_past": False,
}


def verify_s3_landing(**context):
    """
    Confirms the S3 raw landing zone contains objects.

    Soft check — logs a warning rather than failing the DAG when S3 is empty.
    An empty landing zone is valid when no billing activity occurred since the
    last watermark (e.g. overnight on a quiet tenant). A hard failure here
    would cause unnecessary alerts in those cases.

    Phase 12 will replace this with a Great Expectations freshness check.
    """
    import boto3

    s3 = boto3.client("s3")
    bucket = os.environ["S3_RAW_LANDING_BUCKET"]

    response = s3.list_objects_v2(Bucket=bucket, Prefix="raw/", MaxKeys=1)
    count = response.get("KeyCount", 0)

    if count > 0:
        log.info(
            "S3 landing zone verified — objects present in s3://%s/raw/", bucket
        )
    else:
        log.warning(
            "S3 landing zone is empty — no events landed this run. "
            "If this is unexpected, check: (1) billing_audit_log has data "
            "newer than the current watermark, (2) Kafka topics are receiving "
            "messages (check Kafka UI on port 8081), (3) AWS credentials in .env."
        )


with DAG(
    dag_id="billing_pipeline",
    description=(
        "Phase 11 — Billing events: Postgres (billing_audit_log) "
        "→ Kafka → S3 raw landing zone"
    ),
    schedule_interval="@hourly",
    start_date=datetime(2026, 1, 1),
    catchup=False,
    default_args=default_args,
    tags=["billing", "phase-11", "kafka", "s3"],
    doc_md=__doc__,
) as dag:

    produce = PythonOperator(
        task_id="run_producer",
        python_callable=run_producer,
        doc_md="""
        Reads billing_audit_log records newer than the current watermark.
        Routes by table_name:
          invoices      → billing.invoice.created
          subscriptions → billing.subscription.changed
        Watermark (Airflow Variable: billing_producer_watermark) is advanced
        only after a confirmed Kafka flush — never on partial delivery.
        """,
    )

    consume = PythonOperator(
        task_id="run_consumer",
        python_callable=run_consumer,
        doc_md="""
        Polls Kafka topics for up to 60 seconds.
        Writes each event to: s3://{bucket}/raw/{topic}/{date}/{audit_log_id}.json
        Skips keys that already exist in S3 — idempotent by design.
        Commits Kafka offsets only after a confirmed S3 write.
        """,
    )

    verify = PythonOperator(
        task_id="verify_s3_landing",
        python_callable=verify_s3_landing,
        doc_md="""
        Confirms S3 raw landing zone has objects.
        Soft check — warns but does not fail on empty bucket.
        To be replaced by Great Expectations freshness check in Phase 14.
        """,
    )

    produce >> consume >> verify
