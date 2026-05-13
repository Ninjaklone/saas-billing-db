-- =============================================================================
-- Migration: 004_audit_log
-- Phase:     4
-- Date:      2025-05-13
-- Author:    Gara Kinkinsoko Joshua
-- =============================================================================
-- Adds two objects:
--   1. billing_audit_log — append-only table recording status changes on
--                          subscriptions and invoices
--   2. Triggers on subscriptions and invoices that write to billing_audit_log
--      when status changes
-- Note: Depending on the type of db, what might be tracked to serve as an audit will
-- change though there are alternatives to manually tracking like debezium, pgAudit, SQL
-- Server Audit, etc.
--
-- Design decisions: /docs/design_decisions.md — Phase 4
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. billing_audit_log
-- ---------------------------------------------------------------------------
-- Append-only. No UPDATE or DELETE, ever.
-- One row per status change on subscriptions or invoices.
-- changed_by is current_user at the DB level. In production, override with
-- SET LOCAL app.current_user_id = '<user_uuid>' before the triggering
-- Not that I plan to build the application side of this project.
-- statement so the application user is recorded instead.

CREATE TABLE billing_audit_log (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    table_name  TEXT        NOT NULL,
    row_id      UUID        NOT NULL,
    changed_by  TEXT        NOT NULL DEFAULT current_user,
    old_status  TEXT        NOT NULL,
    new_status  TEXT        NOT NULL,
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT audit_log_table_name_valid CHECK (
        table_name IN ('subscriptions', 'invoices')
    ),

    -- A status change that goes nowhere is not a change.
    CONSTRAINT audit_log_status_changed CHECK (old_status <> new_status)
);

COMMENT ON TABLE  billing_audit_log            IS 'Append-only status change log for subscriptions and invoices. No UPDATE or DELETE, ever.';
COMMENT ON COLUMN billing_audit_log.changed_by IS 'Database user by default. Override with SET LOCAL app.current_user_id for application-level identity.';
COMMENT ON COLUMN billing_audit_log.row_id     IS 'UUID of the changed row in the source table.';


-- Indexes
-- row_id + table_name — primary lookup: full audit history for a specific row
CREATE INDEX audit_log_row_idx
    ON billing_audit_log (table_name, row_id);

-- changed_at — time-range queries across the full audit log
CREATE INDEX audit_log_changed_at_idx
    ON billing_audit_log (changed_at);


-- ---------------------------------------------------------------------------
-- 2. Trigger function
-- ---------------------------------------------------------------------------
-- Single function handles both subscriptions and invoices.
-- TG_TABLE_NAME is the built-in Postgres variable for the triggering table.
-- Fires only when OLD.status <> NEW.status — silent on all other updates.
-- changed_by prefers app.current_user_id if set, falls back to current_user.

CREATE OR REPLACE FUNCTION fn_log_status_change()
RETURNS TRIGGER AS $$
BEGIN
    -- Only write an audit row when status actually changed.
    -- The trigger is defined with WHEN (OLD.status <> NEW.status) but this
    -- guard is kept as a safeguard in case the trigger definition changes.
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;

    INSERT INTO billing_audit_log (
        table_name,
        row_id,
        changed_by,
        old_status,
        new_status,
        changed_at
    ) VALUES (
        TG_TABLE_NAME,
        NEW.id,
        COALESCE(
            current_setting('app.current_user_id', TRUE),
            current_user
        ),
        OLD.status,
        NEW.status,
        now()
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fn_log_status_change()
    IS 'Writes a row to billing_audit_log on status change. Used by triggers on subscriptions and invoices.';


-- ---------------------------------------------------------------------------
-- 3. Triggers
-- ---------------------------------------------------------------------------

-- subscriptions
CREATE TRIGGER trg_subscriptions_status_change
    AFTER UPDATE OF status
    ON subscriptions
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION fn_log_status_change();

COMMENT ON TRIGGER trg_subscriptions_status_change ON subscriptions
    IS 'Fires after status column changes on subscriptions. Writes to billing_audit_log.';


-- invoices
CREATE TRIGGER trg_invoices_status_change
    AFTER UPDATE OF status
    ON invoices
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION fn_log_status_change();

COMMENT ON TRIGGER trg_invoices_status_change ON invoices
    IS 'Fires after status column changes on invoices. Writes to billing_audit_log.';