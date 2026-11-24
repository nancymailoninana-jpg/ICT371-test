
-- PostgreSQL (PL/pgSQL). Scheduling uses the pg_cron extension.
-- Safe to re-run. gross = basic + allowance; net = gross-deduction
-- =====================================================================

DROP TABLE IF EXISTS salary_audit, payroll, employees CASCADE;
DROP FUNCTION IF EXISTS fn_net_pay(INT) CASCADE;
DROP FUNCTION IF EXISTS trg_employees_salary_audit() CASCADE;
DROP PROCEDURE IF EXISTS pr_process_payroll(DATE);

-- ---------------------------------------------------------------------
-- (a) Database
-- ---------------------------------------------------------------------
CREATE TABLE employees (
    employee_id  SERIAL        PRIMARY KEY,
    full_name    VARCHAR(100)  NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (deduction >= 0),
    active       BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL        PRIMARY KEY,
    employee_id INT           NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE          NOT NULL,
    gross_pay   NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
    net_pay     NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
    CONSTRAINT uq_payroll_employee_month UNIQUE (employee_id, pay_month),
    CONSTRAINT ck_pay_month_first_day CHECK (EXTRACT(DAY FROM pay_month) = 1)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL        PRIMARY KEY,
    employee_id INT           NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP     NOT NULL DEFAULT now()
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Patrick Mulenga', 6000.00, 800.00, 700.00, TRUE),
    ('Esther Bwalya',   8500.00, 1200.00, 1100.00, TRUE),
    ('Joseph Daka',     4500.00, 500.00,  450.00, TRUE),
    ('Ruth Nkandu',     7000.00, 900.00,  850.00, TRUE),    -- becomes inactive later
    ('Samuel Phiri',    5000.00, 600.00,  550.00, FALSE);   -- inactive from the start

-- ---------------------------------------------------------------------
-- (b) Function: fn_net_pay
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_net NUMERIC(12,2);
BEGIN
    SELECT basic_salary + allowance - deduction
      INTO v_net
      FROM employees
     WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$;

-- ---------------------------------------------------------------------
-- (c) Procedure: pr_process_payroll (query FOR loop)
--     Existing employee/month rows are left unchanged (ON CONFLICT DO NOTHING).
--     Any error aborts the whole call, so no partial payroll is stored.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    r     RECORD;
    v_net NUMERIC(12,2);
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'p_month must be the first day of a month (got %)', p_month;
    END IF;

    FOR r IN
        SELECT employee_id, basic_salary, allowance
        FROM employees
        WHERE active
        ORDER BY employee_id
    LOOP
        v_net := fn_net_pay(r.employee_id);     -- raises on invalid calculation

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month, r.basic_salary + r.allowance, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger: audit real basic_salary changes
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_employees_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_employees_salary_audit();

-- ---------------------------------------------------------------------
-- (a) continued: payroll data for two months
-- ---------------------------------------------------------------------
-- Month 1: two months ago (Ruth is still active)
CALL pr_process_payroll(date_trunc('month', CURRENT_DATE - INTERVAL '2 months')::date);

-- Ruth leaves; Patrick gets a raise (audited by the trigger)
UPDATE employees SET active = FALSE WHERE employee_id = 4;
UPDATE employees SET basic_salary = 6500.00 WHERE employee_id = 1;

-- Month 2: last month (Ruth no longer processed, history kept)
CALL pr_process_payroll(date_trunc('month', CURRENT_DATE - INTERVAL '1 month')::date);

-- ---------------------------------------------------------------------
-- (e) View: v_payroll_report (history kept for employees who became inactive)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.employee_id,
       e.full_name,
       p.pay_month,
       p.gross_pay,
       p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

-- ---------------------------------------------------------------------
-- (f) Index: report filtered by pay_month across all employees
--     The unique index is (employee_id, pay_month); pay_month is its SECOND
--     column, so it cannot be used efficiently for a pay_month-only filter.
--     A single-column index on pay_month does not duplicate it.
-- ---------------------------------------------------------------------
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);

ANALYZE payroll;
SET enable_seqscan = off;
EXPLAIN
SELECT *
FROM v_payroll_report
WHERE pay_month = date_trunc('month', CURRENT_DATE - INTERVAL '1 month')::date;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- (g) Scheduled job: 02:00 on the 1st of every month, previous month
-- ---------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule('payroll_monthly', '0 2 1 * *',
    $$CALL pr_process_payroll(date_trunc('month', CURRENT_DATE - INTERVAL '1 month')::date)$$);

-- Inspect the job
SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'payroll_monthly';

-- Inspect its run history
SELECT jobid, runid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'payroll_monthly')
ORDER BY start_time DESC;

-- To remove it later:  SELECT cron.unschedule('payroll_monthly');

-- =====================================================================
-- DEMONSTRATION / TESTS
-- =====================================================================
SELECT employee_id, full_name, fn_net_pay(employee_id) AS net_pay FROM employees ORDER BY 1;

DO $$ BEGIN PERFORM fn_net_pay(999);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_process_payroll(CURRENT_DATE - 1);     -- not a month start (unless today is the 2nd)
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;

-- Rerun a processed month: nothing changes, nothing duplicates
SELECT COUNT(*) AS rows_before FROM payroll;
CALL pr_process_payroll(date_trunc('month', CURRENT_DATE - INTERVAL '1 month')::date);
SELECT COUNT(*) AS rows_after  FROM payroll;

-- Invalid calculation fails the whole call: make a deduction larger than pay, then restore
UPDATE employees SET deduction = 99999 WHERE employee_id = 3;
DO $$ BEGIN CALL pr_process_payroll(date_trunc('month', CURRENT_DATE)::date);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
SELECT COUNT(*) AS rows_for_current_month FROM payroll
WHERE pay_month = date_trunc('month', CURRENT_DATE)::date;           -- 0: nothing inserted
UPDATE employees SET deduction = 450.00 WHERE employee_id = 3;

-- Unchanged salary must not be audited
UPDATE employees SET basic_salary = basic_salary WHERE employee_id = 2;

SELECT * FROM salary_audit ORDER BY audit_id;     -- only Patrick's raise
SELECT * FROM v_payroll_report ORDER BY pay_month, employee_id;