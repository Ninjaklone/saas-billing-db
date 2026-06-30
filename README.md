# saas-billing-db

A production-grade, multi-tenant SaaS billing database built in PostgreSQL —
designed and documented as a portfolio project demonstrating database
administration skills: schema design, indexing, partitioning, replication,
connection pooling, and monitoring.

**Status:** DBA track complete (Phases 1–9). This document closes out
Phase 10.

---

## What this is

A billing system backend for a hypothetical multi-tenant SaaS platform.
Tenants subscribe to plans, get metered on API usage, receive invoices, and
have their billing events audited. The schema and supporting infrastructure
are built the way a real billing system would be built — not a toy schema,
but one that handles financial integrity, tenant isolation, time-series
data, and the operational concerns (pooling, replication, monitoring) that
come with running this in production.

**Why billing:** every serious company has a billing problem. It touches
nearly every hard database concept naturally — tenancy isolation, financial
data integrity, time-series patterns at scale, audit logging, and the kind
of write/read load that forces real decisions about indexing and
partitioning.

---

## Architecture

                    ┌─────────────┐
                    │ Application │
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │  pgBouncer  │   transaction pooling mode
                    │  (Phase 6)  │   pool_size=9, max_client_conn=200
                    └──────┬──────┘
                           │
            ┌──────────────┴─────────────────┐
            │                                │
     ┌──────▼───────┐               ┌────────▼────────┐
     │   Primary    │  ── WAL ──►   │  Sync standby   │
     │  PostgreSQL  │  streaming    │   PostgreSQL    │
     │  (Phase 8)   │               │   (Phase 8)     │
     └──────┬───────┘               └─────────────────┘
            │
    ┌───────┴─────┬──────────────────────┐
    │             │                      │
┌───▼─────┐  ┌────▼───────┐    ┌─────────▼─────────┐
│ Core    │  │ invoices   │    │ api_usage_events  │
│ tables  │  │(partitioned│    │  (partitioned     │
│         │  │ by month,  │    │   by month,       │
│         │  │ Phase 7)   │    │   Phase 7)        │
└─────────┘  └────────────┘    └───────────────────┘
│
┌──────▼──────┐
│ pg_stat_    │   slow query log @ 200ms
│ statements  │   (Phase 9)
└─────────────┘
---

## Schema overview

Five core tables plus four supporting tables, built incrementally across
Phases 1–5:

| Table | Purpose | Added |
|---|---|---|
| `tenants` | Customer companies, soft-deleted | Phase 1 |
| `plans` | Pricing tiers, retirable via `is_active` | Phase 1 |
| `users` | Tenant-scoped users | Phase 1 |
| `subscriptions` | Plan enrollments, one active per tenant enforced at DB level | Phase 1 |
| `invoices` | Append-only financial ledger, partitioned by month | Phase 1 / 7 |
| `api_usage_events` | Hourly bucketed API usage, partitioned by month | Phase 3 / 7 |
| `billing_summaries` | Materialized view — usage vs. plan limit per billing cycle | Phase 3 |
| `billing_audit_log` | Append-only status change history | Phase 4 |
| `plan_change_events` | Proration record for every plan upgrade/downgrade | Phase 5 |

Full entity-relationship diagram: [`docs/schema_diagram.png`](docs/schema_diagram.png)
(generated via dbdiagram.io).

---

## Running this locally

### Prerequisites

- PostgreSQL 15+
- `psql` on your PATH

### Setup

```bash
createdb saas_billing

psql -d saas_billing -f schema.sql
psql -d saas_billing -f schema/002_indexes.sql
psql -d saas_billing -f schema/003_usage_metering.sql
psql -d saas_billing -f schema/004_audit_log.sql
psql -d saas_billing -f schema/005_proration.sql
psql -d saas_billing -f schema/005_partitioning.sql
psql -d saas_billing -f seed.sql
```

Verify the load:

```bash
psql -d saas_billing -f tests/assertions.sql
```

Every line should print `PASS`.

### Exploring the data

```bash
psql -d saas_billing -f queries/billing_summary.sql
psql -d saas_billing -f queries/invoice_history.sql
psql -d saas_billing -f queries/tenant_usage.sql
```

Query performance documentation, including `EXPLAIN ANALYZE` before/after
comparisons for every index in `schema/002_indexes.sql`, is in
[`queries/README.md`](queries/README.md).

---

## What each phase demonstrates

| Phase | Focus | Where to look |
|---|---|---|
| 1 | Core schema, constraints, soft deletes, append-only design | `schema.sql`, `seed.sql` |
| 2 | Indexing strategy, partial indexes, query performance | `schema/002_indexes.sql`, `queries/README.md` |
| 3 | Time-series usage metering, materialized views | `schema/003_usage_metering.sql` |
| 4 | Audit logging via triggers | `schema/004_audit_log.sql` |
| 5 | Proration calculation, mid-cycle plan changes | `schema/005_proration.sql` |
| 6 | Connection pooling, pool sizing math | `docs/pgbouncer_setup.md` |
| 7 | Declarative partitioning, zero-data-loss migration tradeoffs | `schema/005_partitioning.sql`, `docs/partitioning_guide.md` |
| 8 | Streaming replication, failover runbook | `docs/replication_setup.md` |
| 9 | Query monitoring, key production metrics | `monitoring/` |

Every non-obvious decision across all nine phases — and the reasoning
behind it — is recorded in [`docs/design_decisions.md`](docs/design_decisions.md).
This is the single most useful file in the repo for understanding *why*
the schema looks the way it does, not just what it looks like.

---

## Design principles

A few rules were held to without exception across all nine phases —
documented in full in `docs/design_decisions.md`, summarized here:

- **Money is always `INT` cents.** Never `FLOAT`, never `NUMERIC`.
- **All timestamps are `TIMESTAMPTZ`.** Never bare `TIMESTAMP`.
- **`invoices` and `billing_audit_log` are append-only.** No `UPDATE`, no
  `DELETE`, ever. Status transitions are tracked, not overwritten.
- **Every tenant-scoped table has a `NOT NULL` `tenant_id` foreign key.**
  No exceptions.
- **UUID primary keys throughout**, via `gen_random_uuid()`. No `SERIAL`.
- **No ORM.** Every query in this repo is raw SQL.
- **Every schema change is a migration file**, never an undocumented
  `ALTER TABLE`.

---

## Cloud deployment

This schema targets two managed Postgres environments:

- **AWS RDS** — `docs/replication_setup.md` documents self-managed
  streaming replication; on RDS, Multi-AZ provides the same guarantee
  natively. `docs/pgbouncer_setup.md` documents the RDS Proxy equivalent.
- **GCP CloudSQL** — same schema, same migrations. CloudSQL's built-in
  high availability and Query Insights map to the replication and
  monitoring setups documented here.

Neither deployment has been executed against a live cloud account as part
of this repo — the documentation describes the path to do so, written
from hands-on local replication and pooling setups.

---

## Roadmap — data engineering track (Phases 11–14)

The DBA track (this README's scope) is complete. I plan to extend scope using a
modern data platform on top of the existing PostgreSQL billing
data:

| Phase | Focus |
|---|---|
| 11 | Kafka → Airflow pipeline, raw data lake on S3/GCS |
| 12 | Apache Iceberg lakehouse + Trino query layer |
| 13 | PySpark distributed processing + dbt bronze/silver/gold models |
| 14 | Great Expectations data quality checks + DataHub lineage |

These phases are not yet started. The billing data already in PostgreSQL
is the intended upstream source for all four phases when work begins.

---

## License

This is a portfolio project. Schema, queries, and documentation are
provided as-is for demonstration purposes.