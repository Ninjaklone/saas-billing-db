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