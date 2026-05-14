-- ---------------------------------------------------------------------------
-- The trigger function found in ./schema/004_audit_log
-- Decided to break it up for modularity sake
-- ---------------------------------------------------------------------------
-- Trigger function
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
-- Triggers
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