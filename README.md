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