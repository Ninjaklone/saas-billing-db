-- ---------------------------------------------------------------------------
-- fn_calculate_proration()
-- ---------------------------------------------------------------------------
-- Calculates the proration amounts for a mid-cycle plan change.
--
-- Arguments:
--   p_tenant_id       — the tenant changing plan
--   p_old_plan_id     — the plan they are leaving
--   p_new_plan_id     — the plan they are moving to
--   p_effective_at    — the exact moment the change takes effect
--   p_period_start    — start of the current billing cycle
--   p_period_end      — end of the current billing cycle
--
-- Returns a single row with the calculated amounts and a record inserted
-- into plan_change_events. The caller is responsible for:
--   1. Creating the new subscription row
--   2. Inserting the proration invoice into invoices using net_cents
--
-- Daily rate calculation:
--   Monthly plans: price_cents / actual days in the month
--   Annual plans:  price_cents / 365
--
-- days_remaining is calculated as:
--   (p_period_end::date - p_effective_at::date)
-- This is inclusive of the change date — the tenant is credited for
-- the day of the change on the old plan and charged for it on the new plan.
-- The net effect is correct because both rates apply to the same day count.

CREATE OR REPLACE FUNCTION fn_calculate_proration(
    p_tenant_id     UUID,
    p_old_plan_id   UUID,
    p_new_plan_id   UUID,
    p_effective_at  TIMESTAMPTZ,
    p_period_start  TIMESTAMPTZ,
    p_period_end    TIMESTAMPTZ,
    p_subscription_id UUID
)
RETURNS TABLE (
    days_remaining  INT,
    days_in_cycle   INT,
    old_daily_rate  NUMERIC,
    new_daily_rate  NUMERIC,
    credit_cents    INT,
    charge_cents    INT,
    net_cents       INT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_old_price_cents   INT;
    v_new_price_cents   INT;
    v_old_cycle         TEXT;
    v_new_cycle         TEXT;
    v_days_remaining    INT;
    v_days_in_cycle     INT;
    v_old_daily_rate    NUMERIC;
    v_new_daily_rate    NUMERIC;
    v_credit_cents      INT;
    v_charge_cents      INT;
    v_net_cents         INT;
BEGIN

    -- Fetch old plan details
    SELECT price_cents, billing_cycle
    INTO v_old_price_cents, v_old_cycle
    FROM plans
    WHERE id = p_old_plan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Old plan not found: %', p_old_plan_id;
    END IF;

    -- Fetch new plan details
    SELECT price_cents, billing_cycle
    INTO v_new_price_cents, v_new_cycle
    FROM plans
    WHERE id = p_new_plan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'New plan not found: %', p_new_plan_id;
    END IF;

    -- Calculate total days in the billing cycle
    v_days_in_cycle := (p_period_end::date - p_period_start::date);

    IF v_days_in_cycle <= 0 THEN
        RAISE EXCEPTION 'Invalid billing period: period_end must be after period_start';
    END IF;

    -- Calculate days remaining from effective_at to period_end
    -- Minimum 1 — a same-day change still processes one day of proration
    v_days_remaining := GREATEST(
        (p_period_end::date - p_effective_at::date),
        1
    );

    IF v_days_remaining > v_days_in_cycle THEN
        RAISE EXCEPTION 'effective_at % is before the period start %',
            p_effective_at, p_period_start;
    END IF;

    -- Daily rate: price / days in cycle
    -- Uses actual cycle length, not a fixed 30 or 365
    -- NULLIF guards against zero division (should never happen given checks above)
    v_old_daily_rate := v_old_price_cents::NUMERIC / NULLIF(v_days_in_cycle, 0);
    v_new_daily_rate := v_new_price_cents::NUMERIC / NULLIF(v_days_in_cycle, 0);

    -- Credit: unused days on old plan (rounded down — favour the platform)
    v_credit_cents := FLOOR(v_old_daily_rate * v_days_remaining);

    -- Charge: remaining days on new plan (rounded up — favour the platform)
    v_charge_cents := CEIL(v_new_daily_rate * v_days_remaining);

    -- Net: positive = tenant owes more (upgrade), negative = tenant is owed (downgrade)
    v_net_cents := v_charge_cents - v_credit_cents;

    -- Record the plan change event
    INSERT INTO plan_change_events (
        tenant_id,
        subscription_id,
        old_plan_id,
        new_plan_id,
        effective_at,
        days_remaining,
        days_in_cycle,
        credit_cents,
        charge_cents,
        net_cents
    ) VALUES (
        p_tenant_id,
        p_subscription_id,
        p_old_plan_id,
        p_new_plan_id,
        p_effective_at,
        v_days_remaining,
        v_days_in_cycle,
        v_credit_cents,
        v_charge_cents,
        v_net_cents
    );

    -- Return the calculated amounts to the caller
    RETURN QUERY SELECT
        v_days_remaining,
        v_days_in_cycle,
        v_old_daily_rate,
        v_new_daily_rate,
        v_credit_cents,
        v_charge_cents,
        v_net_cents;

END;
$$;

COMMENT ON FUNCTION fn_calculate_proration(UUID, UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, UUID)
    IS 'Calculates proration amounts for a mid-cycle plan change. Inserts a row into plan_change_events and returns the amounts. Caller is responsible for creating the new subscription and proration invoice.';