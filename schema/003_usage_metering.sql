-- =============================================================================
-- Migration: 003_usage_metering
-- Phase:     3
-- Date:      2025-05-12
-- Author:    Gara Kinkinsoko Joshua
-- =============================================================================
-- Adds two objects:
--   1. api_usage_events  — hourly bucketed API call counts per tenant
--   2. billing_summaries — materialized view aggregating usage per tenant
--                          per billing cycle
--
-- Design decisions: /docs/design_decisions.md — Phase 3
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. api_usage_events
-- ---------------------------------------------------------------------------
-- One row per tenant per hour per endpoint.
-- Counts are aggregated at the application layer before insert —
-- this is not a per-request log table.
--
-- Partitioned by month on recorded_at (Phase 7 will implement this).
-- The schema is designed now to make migration as non-breaking 
-- as I can get it to be:
--   - recorded_at is TIMESTAMPTZ, not DATE
--   - tenant_id + recorded_at + endpoint is the natural unique key
--   - no SERIAL — UUID pk is partition-safe

CREATE TABLE api_usage_events (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   UUID        NOT NULL REFERENCES tenants(id),
    recorded_at TIMESTAMPTZ NOT NULL,   -- truncated to the hour at insert
    endpoint    TEXT        NOT NULL,   -- e.g. '/api/v1/invoices'
    event_count INT         NOT NULL,

    CONSTRAINT api_usage_events_count_positive CHECK (event_count > 0),

    -- One row per tenant per hour per endpoint.
    -- Prevents double-counting if the aggregation job runs twice.
    -- Stuff like this is a must. Idempotency is of the utmost when record keeping.
    CONSTRAINT api_usage_events_unique UNIQUE (tenant_id, recorded_at, endpoint)
);

COMMENT ON TABLE  api_usage_events             IS 'Hourly bucketed API call counts per tenant per endpoint. Not a per-request log.';
COMMENT ON COLUMN api_usage_events.recorded_at IS 'Bucket timestamp truncated to the hour. Enforced at application layer: date_trunc(''hour'', now()).';
COMMENT ON COLUMN api_usage_events.event_count IS 'Total API calls in this bucket. Must be > 0 — zero-count rows are never inserted.';
COMMENT ON COLUMN api_usage_events.endpoint    IS 'API endpoint path, e.g. /api/v1/invoices. Normalised before insert — no query strings.';


-- Indexes for api_usage_events
-- tenant_id first — all usage queries are tenant-scoped.
CREATE INDEX api_usage_events_tenant_id_idx
    ON api_usage_events (tenant_id);

-- Composite for the most common query shape:
-- usage for a tenant within a time range.
CREATE INDEX api_usage_events_tenant_recorded_idx
    ON api_usage_events (tenant_id, recorded_at);

-- recorded_at alone — for platform-wide time-range scans
-- (ops dashboards, anomaly detection across all tenants).
CREATE INDEX api_usage_events_recorded_at_idx
    ON api_usage_events (recorded_at);


-- ---------------------------------------------------------------------------
-- 2. billing_summaries (materialized view)
-- ---------------------------------------------------------------------------
-- Pre-aggregated usage per tenant per billing cycle.
-- Joins api_usage_events to subscriptions to align usage with the
-- billing period the usage falls within.
--
-- Refreshed on a schedule — run REFRESH MATERIALIZED VIEW CONCURRENTLY
-- billing_summaries at the end of each billing cycle or on demand.
-- CONCURRENTLY allows reads during refresh (requires a UNIQUE index —
-- see below).
--
-- What one row represents:
--   The total API calls a tenant made within a specific subscription
--   billing period, broken down by endpoint.