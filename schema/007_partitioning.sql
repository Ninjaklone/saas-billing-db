-- Not yet implemented - Still looking to improve the query.
-- psql -h localhost -U postgres -d saas-billing-db -f .\schema\007_partitioning.sql
-- =============================================================================
-- Migration: 007_partitioning
-- Phase:     7
-- Date:      2025-05-24
-- Author:    Gara Kinkinsoko Joshua
-- =============================================================================
-- Partitions two tables by month on their timestamp column:
--   1. invoices        — partitioned on created_at
--   2. api_usage_events — partitioned on recorded_at
--
-- Strategy: rename existing table, recreate as partitioned, copy data,
-- drop backup. Requires a maintenance window — see below.
--
-- Maintenance window requirement:
--   Both tables are unavailable for writes during the copy step.
--   Estimated window for seed data: < 5 seconds.
--   Estimated window for 1M rows:   2-5 minutes depending on I/O.
--   Schedule during lowest-traffic period. Notify application team before
--   starting. Have a rollback plan ready (see ROLLBACK section at the end).
--
-- Design decisions: /docs/design_decisions.md — Phase 7
-- =============================================================================

BEGIN;
-- ===========================================================================
-- INVOICES
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Step 1 — rename existing table to backup
-- ---------------------------------------------------------------------------
ALTER TABLE invoices RENAME TO invoices_old;

-- Rename associated indexes and constraints to avoid conflicts
ALTER INDEX invoices_pkey                RENAME TO invoices_old_pkey;
ALTER INDEX invoices_tenant_id_idx       RENAME TO invoices_old_tenant_id_idx;
ALTER INDEX invoices_tenant_status_idx   RENAME TO invoices_old_tenant_status_idx;
ALTER INDEX invoices_subscription_id_idx RENAME TO invoices_old_subscription_id_idx;
ALTER INDEX invoices_created_at_idx      RENAME TO invoices_old_created_at_idx;


-- ---------------------------------------------------------------------------
-- Step 2 — create new partitioned table
-- ---------------------------------------------------------------------------
-- CREATE TABLE invoices (
--     id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
--     tenant_id       UUID        NOT NULL REFERENCES tenants(id),
--     subscription_id UUID        NOT NULL REFERENCES subscriptions(id),
--     amount_cents    INT         NOT NULL,
--     status          TEXT        NOT NULL,
--     due_date        DATE        NOT NULL,
--     paid_at         TIMESTAMPTZ,
--     created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

--     CONSTRAINT invoices_amount_non_negative CHECK (amount_cents >= 0),
--     CONSTRAINT invoices_status_valid        CHECK (status IN ('draft', 'open', 'paid', 'void', 'uncollectible')),
--     CONSTRAINT invoices_paid_consistency    CHECK (
--         (status = 'paid' AND paid_at IS NOT NULL)
--         OR (status <> 'paid' AND paid_at IS NULL)
--     ),
--     CONSTRAINT invoices_paid_after_created  CHECK (paid_at IS NULL OR paid_at >= created_at),
--     CONSTRAINT invoices_due_date_valid      CHECK (due_date >= created_at::DATE)
-- ) PARTITION BY RANGE (created_at);

-- COMMENT ON TABLE invoices
--     IS 'Financial ledger. APPEND-ONLY. Partitioned by month on created_at.';

-- invoices: composite primary key including the partition key
CREATE TABLE invoices (
    id              UUID        NOT NULL DEFAULT gen_random_uuid(),
    tenant_id       UUID        NOT NULL REFERENCES tenants(id),
    subscription_id UUID        NOT NULL REFERENCES subscriptions(id),
    amount_cents    INT         NOT NULL,
    status          TEXT        NOT NULL,
    due_date        DATE        NOT NULL,
    paid_at         TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT invoices_pkey PRIMARY KEY (id, created_at),

    CONSTRAINT invoices_amount_non_negative CHECK (amount_cents >= 0),
    CONSTRAINT invoices_status_valid        CHECK (status IN ('draft', 'open', 'paid', 'void', 'uncollectible')),
    CONSTRAINT invoices_paid_consistency    CHECK (
        (status = 'paid' AND paid_at IS NOT NULL)
        OR (status <> 'paid' AND paid_at IS NULL)
    ),
    CONSTRAINT invoices_paid_after_created  CHECK (paid_at IS NULL OR paid_at >= created_at),
    CONSTRAINT invoices_due_date_valid      CHECK (due_date >= created_at::DATE)
) PARTITION BY RANGE (created_at);


-- ---------------------------------------------------------------------------
-- Step 3 — create monthly partitions
-- ---------------------------------------------------------------------------
-- Historical: 2023-01 through 2024-12
-- Current:    2025-01 through 2025-06
-- Future:     2025-07 through 2025-09 (3 months ahead)
-- Default:    catches any row outside the explicit partition range

CREATE TABLE invoices_2023_01 PARTITION OF invoices
    FOR VALUES FROM ('2023-01-01') TO ('2023-02-01');
CREATE TABLE invoices_2023_02 PARTITION OF invoices
    FOR VALUES FROM ('2023-02-01') TO ('2023-03-01');
CREATE TABLE invoices_2023_03 PARTITION OF invoices
    FOR VALUES FROM ('2023-03-01') TO ('2023-04-01');
CREATE TABLE invoices_2023_04 PARTITION OF invoices
    FOR VALUES FROM ('2023-04-01') TO ('2023-05-01');
CREATE TABLE invoices_2023_05 PARTITION OF invoices
    FOR VALUES FROM ('2023-05-01') TO ('2023-06-01');
CREATE TABLE invoices_2023_06 PARTITION OF invoices
    FOR VALUES FROM ('2023-06-01') TO ('2023-07-01');
CREATE TABLE invoices_2023_07 PARTITION OF invoices
    FOR VALUES FROM ('2023-07-01') TO ('2023-08-01');
CREATE TABLE invoices_2023_08 PARTITION OF invoices
    FOR VALUES FROM ('2023-08-01') TO ('2023-09-01');
CREATE TABLE invoices_2023_09 PARTITION OF invoices
    FOR VALUES FROM ('2023-09-01') TO ('2023-10-01');
CREATE TABLE invoices_2023_10 PARTITION OF invoices
    FOR VALUES FROM ('2023-10-01') TO ('2023-11-01');
CREATE TABLE invoices_2023_11 PARTITION OF invoices
    FOR VALUES FROM ('2023-11-01') TO ('2023-12-01');
CREATE TABLE invoices_2023_12 PARTITION OF invoices
    FOR VALUES FROM ('2023-12-01') TO ('2024-01-01');

CREATE TABLE invoices_2024_01 PARTITION OF invoices
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');
CREATE TABLE invoices_2024_02 PARTITION OF invoices
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');
CREATE TABLE invoices_2024_03 PARTITION OF invoices
    FOR VALUES FROM ('2024-03-01') TO ('2024-04-01');
CREATE TABLE invoices_2024_04 PARTITION OF invoices
    FOR VALUES FROM ('2024-04-01') TO ('2024-05-01');
CREATE TABLE invoices_2024_05 PARTITION OF invoices
    FOR VALUES FROM ('2024-05-01') TO ('2024-06-01');
CREATE TABLE invoices_2024_06 PARTITION OF invoices
    FOR VALUES FROM ('2024-06-01') TO ('2024-07-01');
CREATE TABLE invoices_2024_07 PARTITION OF invoices
    FOR VALUES FROM ('2024-07-01') TO ('2024-08-01');
CREATE TABLE invoices_2024_08 PARTITION OF invoices
    FOR VALUES FROM ('2024-08-01') TO ('2024-09-01');
CREATE TABLE invoices_2024_09 PARTITION OF invoices
    FOR VALUES FROM ('2024-09-01') TO ('2024-10-01');
CREATE TABLE invoices_2024_10 PARTITION OF invoices
    FOR VALUES FROM ('2024-10-01') TO ('2024-11-01');
CREATE TABLE invoices_2024_11 PARTITION OF invoices
    FOR VALUES FROM ('2024-11-01') TO ('2024-12-01');
CREATE TABLE invoices_2024_12 PARTITION OF invoices
    FOR VALUES FROM ('2024-12-01') TO ('2025-01-01');

CREATE TABLE invoices_2025_01 PARTITION OF invoices
    FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');
CREATE TABLE invoices_2025_02 PARTITION OF invoices
    FOR VALUES FROM ('2025-02-01') TO ('2025-03-01');
CREATE TABLE invoices_2025_03 PARTITION OF invoices
    FOR VALUES FROM ('2025-03-01') TO ('2025-04-01');
CREATE TABLE invoices_2025_04 PARTITION OF invoices
    FOR VALUES FROM ('2025-04-01') TO ('2025-05-01');
CREATE TABLE invoices_2025_05 PARTITION OF invoices
    FOR VALUES FROM ('2025-05-01') TO ('2025-06-01');
CREATE TABLE invoices_2025_06 PARTITION OF invoices
    FOR VALUES FROM ('2025-06-01') TO ('2025-07-01');

-- Future partitions — 3 months ahead
CREATE TABLE invoices_2025_07 PARTITION OF invoices
    FOR VALUES FROM ('2025-07-01') TO ('2025-08-01');
CREATE TABLE invoices_2025_08 PARTITION OF invoices
    FOR VALUES FROM ('2025-08-01') TO ('2025-09-01');
CREATE TABLE invoices_2025_09 PARTITION OF invoices
    FOR VALUES FROM ('2025-09-01') TO ('2025-10-01');

-- Default partition — catches rows outside all explicit ranges.
-- If this partition grows, partition creation has fallen behind schedule.
CREATE TABLE invoices_default PARTITION OF invoices DEFAULT;


-- ---------------------------------------------------------------------------
-- Step 4 — recreate indexes on the partitioned table
-- ---------------------------------------------------------------------------
-- Indexes on a partitioned parent automatically apply to all partitions
-- and any future partitions created later.

CREATE INDEX invoices_tenant_id_idx
    ON invoices (tenant_id);

CREATE INDEX invoices_tenant_status_idx
    ON invoices (tenant_id, status);

CREATE INDEX invoices_subscription_id_idx
    ON invoices (subscription_id);

CREATE INDEX invoices_created_at_idx
    ON invoices (created_at)
    WHERE status NOT IN ('void', 'draft');


-- ---------------------------------------------------------------------------
-- Step 5 — recreate audit trigger on partitioned table
-- ---------------------------------------------------------------------------
-- Triggers on a partitioned parent fire for all partitions automatically.

CREATE TRIGGER trg_invoices_status_change
    AFTER UPDATE OF status
    ON invoices
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION fn_log_status_change();


-- ---------------------------------------------------------------------------
-- Step 6 — copy data from backup table
-- ---------------------------------------------------------------------------
-- Run this inside a transaction. If anything fails, ROLLBACK restores
-- invoices_old with all original data intact.

INSERT INTO invoices
SELECT * FROM invoices_old;


-- ---------------------------------------------------------------------------
-- Step 7 — verify row counts match before dropping backup
-- ---------------------------------------------------------------------------
-- Run these manually and confirm both counts are equal before proceeding.
-- Do not drop invoices_old until counts match.

-- SELECT COUNT(*) FROM invoices_old;
-- SELECT COUNT(*) FROM invoices;
-- SELECT COUNT(*) FROM invoices WHERE tableoid::regclass::text = 'invoices_default';
-- -- Last query must return 0 — no rows in the default partition.


-- ---------------------------------------------------------------------------
-- Step 8 — drop backup table
-- ---------------------------------------------------------------------------
-- Uncomment only after verifying row counts in Step 7.

-- DROP TABLE invoices_old;


-- ===========================================================================
-- API_USAGE_EVENTS
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Step 1 — rename existing table to backup
-- ---------------------------------------------------------------------------
ALTER TABLE api_usage_events RENAME TO api_usage_events_old;

ALTER INDEX api_usage_events_pkey
    RENAME TO api_usage_events_old_pkey;
ALTER INDEX api_usage_events_tenant_id_idx
    RENAME TO api_usage_events_old_tenant_id_idx;
ALTER INDEX api_usage_events_tenant_recorded_idx
    RENAME TO api_usage_events_old_tenant_recorded_idx;
ALTER INDEX api_usage_events_recorded_at_idx
    RENAME TO api_usage_events_old_recorded_at_idx;
ALTER INDEX api_usage_events_unique 
	RENAME TO api_usage_events_old_unique;


-- ---------------------------------------------------------------------------
-- Step 2 — create new partitioned table
-- ---------------------------------------------------------------------------
-- CREATE TABLE api_usage_events (
--     id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
--     tenant_id   UUID        NOT NULL REFERENCES tenants(id),
--     recorded_at TIMESTAMPTZ NOT NULL,
--     endpoint    TEXT        NOT NULL,
--     event_count INT         NOT NULL,

--     CONSTRAINT api_usage_events_count_positive CHECK (event_count > 0),
--     CONSTRAINT api_usage_events_unique UNIQUE (tenant_id, recorded_at, endpoint)
-- ) PARTITION BY RANGE (recorded_at);

-- COMMENT ON TABLE api_usage_events
--     IS 'Hourly bucketed API call counts per tenant per endpoint. Partitioned by month on recorded_at.';


-- api_usage_events: same composite key fix
CREATE TABLE api_usage_events (
    id          UUID        NOT NULL DEFAULT gen_random_uuid(),
    tenant_id   UUID        NOT NULL REFERENCES tenants(id),
    recorded_at TIMESTAMPTZ NOT NULL,
    endpoint    TEXT        NOT NULL,
    event_count INT         NOT NULL,

    CONSTRAINT api_usage_events_pkey PRIMARY KEY (id, recorded_at),

    CONSTRAINT api_usage_events_count_positive CHECK (event_count > 0),
    CONSTRAINT api_usage_events_unique UNIQUE (tenant_id, recorded_at, endpoint)
) PARTITION BY RANGE (recorded_at);

-- ---------------------------------------------------------------------------
-- Step 3 — create monthly partitions
-- ---------------------------------------------------------------------------

CREATE TABLE api_usage_events_2023_01 PARTITION OF api_usage_events
    FOR VALUES FROM ('2023-01-01') TO ('2023-02-01');
CREATE TABLE api_usage_events_2023_02 PARTITION OF api_usage_events
    FOR VALUES FROM ('2023-02-01') TO ('2023-03-01');
CREATE TABLE api_usage_events_2023_03 PARTITION OF api_usage_events
    FOR VALUES FROM ('2023-03-01') TO ('2023-04-01');
CREATE TABLE api_usage_events_2023_04 PARTITION OF api_usage_events
    FOR VALUES FROM ('2023-04-01') TO ('2023-05-01');
CREATE TABLE api_usage_events_2023_05 PARTITION OF api_usage_events
    FOR VALUES FROM ('2023-05-01') TO ('2023-06-01');
CREATE TABLE api_usage_events_2023_06 PARTITION OF api_usage_events
    FOR VALUES FROM ('2023-06-01') TO ('2023-07-01');
CREATE TABLE api_usage_events_2023_07 PARTITION OF api_usage_events
    FOR VALUES FROM ('2023-07-01') TO ('2023-08-01');
CREATE TABLE api_usage_events_2023_08 PARTITION OF api_usage_events
    FOR VALUES FROM ('2023-08-01') TO ('2023-09-01');
CREATE TABLE api_usage_events_2023_09 PARTITION OF api_usage_events
    FOR VALUES FROM ('2023-09-01') TO ('2023-10-01');
CREATE TABLE api_usage_events_2023_10 PARTITION OF api_usage_events
    FOR VALUES FROM ('2023-10-01') TO ('2023-11-01');
CREATE TABLE api_usage_events_2023_11 PARTITION OF api_usage_events
    FOR VALUES FROM ('2023-11-01') TO ('2023-12-01');
CREATE TABLE api_usage_events_2023_12 PARTITION OF api_usage_events
    FOR VALUES FROM ('2023-12-01') TO ('2024-01-01');

CREATE TABLE api_usage_events_2024_01 PARTITION OF api_usage_events
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');
CREATE TABLE api_usage_events_2024_02 PARTITION OF api_usage_events
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');
CREATE TABLE api_usage_events_2024_03 PARTITION OF api_usage_events
    FOR VALUES FROM ('2024-03-01') TO ('2024-04-01');
CREATE TABLE api_usage_events_2024_04 PARTITION OF api_usage_events
    FOR VALUES FROM ('2024-04-01') TO ('2024-05-01');
CREATE TABLE api_usage_events_2024_05 PARTITION OF api_usage_events
    FOR VALUES FROM ('2024-05-01') TO ('2024-06-01');
CREATE TABLE api_usage_events_2024_06 PARTITION OF api_usage_events
    FOR VALUES FROM ('2024-06-01') TO ('2024-07-01');
CREATE TABLE api_usage_events_2024_07 PARTITION OF api_usage_events
    FOR VALUES FROM ('2024-07-01') TO ('2024-08-01');
CREATE TABLE api_usage_events_2024_08 PARTITION OF api_usage_events
    FOR VALUES FROM ('2024-08-01') TO ('2024-09-01');
CREATE TABLE api_usage_events_2024_09 PARTITION OF api_usage_events
    FOR VALUES FROM ('2024-09-01') TO ('2024-10-01');
CREATE TABLE api_usage_events_2024_10 PARTITION OF api_usage_events
    FOR VALUES FROM ('2024-10-01') TO ('2024-11-01');
CREATE TABLE api_usage_events_2024_11 PARTITION OF api_usage_events
    FOR VALUES FROM ('2024-11-01') TO ('2024-12-01');
CREATE TABLE api_usage_events_2024_12 PARTITION OF api_usage_events
    FOR VALUES FROM ('2024-12-01') TO ('2025-01-01');

CREATE TABLE api_usage_events_2025_01 PARTITION OF api_usage_events
    FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');
CREATE TABLE api_usage_events_2025_02 PARTITION OF api_usage_events
    FOR VALUES FROM ('2025-02-01') TO ('2025-03-01');
CREATE TABLE api_usage_events_2025_03 PARTITION OF api_usage_events
    FOR VALUES FROM ('2025-03-01') TO ('2025-04-01');
CREATE TABLE api_usage_events_2025_04 PARTITION OF api_usage_events
    FOR VALUES FROM ('2025-04-01') TO ('2025-05-01');
CREATE TABLE api_usage_events_2025_05 PARTITION OF api_usage_events
    FOR VALUES FROM ('2025-05-01') TO ('2025-06-01');
CREATE TABLE api_usage_events_2025_06 PARTITION OF api_usage_events
    FOR VALUES FROM ('2025-06-01') TO ('2025-07-01');

-- Future partitions
CREATE TABLE api_usage_events_2025_07 PARTITION OF api_usage_events
    FOR VALUES FROM ('2025-07-01') TO ('2025-08-01');
CREATE TABLE api_usage_events_2025_08 PARTITION OF api_usage_events
    FOR VALUES FROM ('2025-08-01') TO ('2025-09-01');
CREATE TABLE api_usage_events_2025_09 PARTITION OF api_usage_events
    FOR VALUES FROM ('2025-09-01') TO ('2025-10-01');

-- Default partition
CREATE TABLE api_usage_events_default PARTITION OF api_usage_events DEFAULT;


-- ---------------------------------------------------------------------------
-- Step 4 — recreate indexes
-- ---------------------------------------------------------------------------
CREATE INDEX api_usage_events_tenant_id_idx
    ON api_usage_events (tenant_id);

CREATE INDEX api_usage_events_tenant_recorded_idx
    ON api_usage_events (tenant_id, recorded_at);

CREATE INDEX api_usage_events_recorded_at_idx
    ON api_usage_events (recorded_at);


-- ---------------------------------------------------------------------------
-- Step 5 — copy data from backup table
-- ---------------------------------------------------------------------------
INSERT INTO api_usage_events
SELECT * FROM api_usage_events_old;

END;
-- ---------------------------------------------------------------------------
-- Step 6 — verify row counts
-- ---------------------------------------------------------------------------
-- SELECT COUNT(*) FROM api_usage_events_old;
-- SELECT COUNT(*) FROM api_usage_events;
-- SELECT COUNT(*) FROM api_usage_events
--     WHERE tableoid::regclass::text = 'api_usage_events_default';
-- -- Last query must return 0.


-- ---------------------------------------------------------------------------
-- Step 7 — drop backup table
-- ---------------------------------------------------------------------------
-- Uncomment only after verifying row counts in Step 6.

-- DROP TABLE api_usage_events_old;


-- ===========================================================================
-- ONGOING PARTITION MAINTENANCE
-- ===========================================================================
-- New partitions must be created before the month they cover begins.
-- Run this script on the first of each month, or automate via pg_cron:
--
-- SELECT cron.schedule(
--     'create-monthly-partitions',
--     '0 0 1 * *',    -- midnight on the first of every month
--     $$ <insert partition creation statements for next month here> $$
-- );
--
-- Example — add this each month for the month three months ahead:
--
-- CREATE TABLE invoices_2025_10 PARTITION OF invoices
--     FOR VALUES FROM ('2025-10-01') TO ('2025-11-01');
--
-- CREATE TABLE api_usage_events_2025_10 PARTITION OF api_usage_events
--     FOR VALUES FROM ('2025-10-01') TO ('2025-11-01');
--
-- Monitor the default partition monthly:
-- SELECT COUNT(*) FROM invoices WHERE tableoid::regclass::text = 'invoices_default';
-- SELECT COUNT(*) FROM api_usage_events
--     WHERE tableoid::regclass::text = 'api_usage_events_default';
-- Any non-zero count means a partition is missing — create it and move the rows.


-- ===========================================================================
-- ROLLBACK PLAN
-- ===========================================================================
-- If anything fails before Step 8 (DROP TABLE), the backup tables are intact
-- or just systematically wrap the query in transactions like a sane person.
-- To rollback:
--
-- For invoices:
--   DROP TABLE invoices;
--   ALTER TABLE invoices_old RENAME TO invoices;
--   ALTER INDEX invoices_old_pkey RENAME TO invoices_pkey;
--   ALTER INDEX invoices_old_tenant_id_idx RENAME TO invoices_tenant_id_idx;
--   ALTER INDEX invoices_old_tenant_status_idx RENAME TO invoices_tenant_status_idx;
--   ALTER INDEX invoices_old_subscription_id_idx RENAME TO invoices_subscription_id_idx;
--   ALTER INDEX invoices_old_created_at_idx RENAME TO invoices_created_at_idx;
--
-- For api_usage_events:
--   DROP TABLE api_usage_events;
--   ALTER TABLE api_usage_events_old RENAME TO api_usage_events;
--   ALTER INDEX api_usage_events_old_pkey RENAME TO api_usage_events_pkey;
--   ALTER INDEX api_usage_events_old_tenant_id_idx RENAME TO api_usage_events_tenant_id_idx;
--   ALTER INDEX api_usage_events_old_tenant_recorded_idx RENAME TO api_usage_events_tenant_recorded_idx;
--   ALTER INDEX api_usage_events_old_recorded_at_idx RENAME TO api_usage_events_recorded_at_idx;
-- ===========================================================================