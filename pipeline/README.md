# Pipeline — Phase 11: Kafka + Airflow

## What this phase builds

A billing event pipeline that moves data from PostgreSQL outward into a raw
data lake on S3, orchestrated by Airflow. This is the first phase of the data
engineering track and establishes the pattern all subsequent phases build on.

```
billing_audit_log (Postgres)
        │
        ▼
billing_producer.py  ──────►  billing.invoice.created      (Kafka topic)
                              billing.subscription.changed  (Kafka topic)
                                        │
                                        ▼
                              billing_consumer.py
                                        │
                                        ▼
                              s3://{bucket}/raw/{topic}/{date}/{audit_log_id}.json
```

Airflow DAG (`billing_pipeline`) runs hourly and orchestrates:
`run_producer → run_consumer → verify_s3_landing`

---

## Design decisions

### Why billing_audit_log as the source?

The audit log (Phase 4) already captures every INSERT/UPDATE on the tables we
care about, with a stable UUID primary key per change event. Using it as the
producer source means:

- No change to the application layer — triggers fire on the DB side
- Every event has a natural idempotency key (`billing_audit_log.id`)
- Historical events are available from day one (no cold-start problem)

The alternative (polling source tables directly for changed rows) requires
either a `updated_at` column on every table or a CDC tool. The audit log
already gives us both the what and the when.

### Why billing_audit_log.id as the idempotency key?

A UUID per change event is globally unique and stable — it never changes after
insert. Using it as:

- The Kafka message **key** → Kafka routes the same logical event to the same
  partition on re-publish (consistent ordering within a tenant's events)
- The **S3 filename** → `{audit_log_id}.json` means a re-run of the consumer
  overwrites to the same key, never creates a duplicate file

A composite key (`entity_id + event_type + occurred_at`) would work but is
more complex to derive and more fragile if any component changes type or
format. The audit log UUID is the cleaner choice.

### Why a fixed poll window on the consumer?

The consumer exits after `POLL_TIMEOUT_SECONDS` (60s) rather than running
as a long-lived daemon. This makes it:

- Safe to call from an Airflow PythonOperator (tasks must terminate)
- Observable — Airflow tracks start/end time, retries, and logs per run
- Restartable — Kafka offsets are committed per message, so a crash mid-run
  leaves no gap

The tradeoff is latency: events are delayed up to one hourly interval.
For a billing system this is acceptable. For real-time requirements, the
consumer would be deployed as a separate long-running service outside Airflow.

### Why catchup=False on the DAG?

The producer uses a watermark (Airflow Variable), not Airflow's execution
date, to determine which records to publish. Backfilling historical DAG runs
would re-run the producer against the same watermark each time, producing
no additional events. `catchup=False` prevents unnecessary task queuing when
the Codespace has been stopped for several hours.

### Topic naming convention

`billing.invoice.created`, `billing.subscription.changed`

Pattern: `{domain}.{entity}.{past-tense-event}`. Dot-separated hierarchy
makes it easy to apply wildcard consumers (`billing.*`) at the namespace
level in Phase 12 without reconfiguring individual topics.

---

## How to run manually (for testing outside Airflow)

```bash
# From inside the Codespace terminal

# Trigger the producer directly
docker compose exec airflow-webserver python /opt/airflow/kafka_scripts/billing_producer.py

# Trigger the consumer directly
docker compose exec airflow-webserver python /opt/airflow/kafka_scripts/billing_consumer.py

# Check what landed in Kafka (Kafka UI)
# Open port 8081 from the Codespace Ports tab
# Topics → billing.invoice.created → Messages

# Check what landed in S3
aws s3 ls s3://${S3_RAW_LANDING_BUCKET}/raw/ --recursive
```

---

## JD requirements addressed

| Requirement | Deliverable |
|---|---|
| Large-scale data pipelines — collection, processing, curation, publishing | `billing_producer.py` + `billing_consumer.py` + `billing_pipeline.py` DAG |
| Orchestration with Airflow | `billing_pipeline.py` — hourly DAG, retry logic, task dependencies |
| ETL/ELT with Kafka | Kafka producer/consumer pattern with idempotent delivery |

---

## What comes next (Phase 12)

The raw JSON files landing in `s3://{bucket}/raw/` are the input for Phase 12,
which ingests them into Apache Iceberg tables and exposes them via Trino.
The `verify_s3_landing` task in the DAG will be extended with a proper
Great Expectations freshness check in Phase 14.
