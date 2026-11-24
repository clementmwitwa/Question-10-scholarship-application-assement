-- ICT371 Advanced Database | Question 10: Scholarship Application Assessment
-- Student: Clement Mwitwa | Student No: 202406171 | PostgreSQL
-- Eligible only if: age 18..25 inclusive AND monthly income <= K3,000 AND average mark >= 70.

DROP SCHEMA IF EXISTS q10_scholarship CASCADE;
CREATE SCHEMA q10_scholarship;
SET search_path = q10_scholarship, public;

/* ===================== (a) Database and seed data ===================== */
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INTEGER       NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER       NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE          NOT NULL,
    status             VARCHAR(10)   NOT NULL DEFAULT 'PENDING',
    CONSTRAINT ck_app_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER     NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP   NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
    ('202406171', 'Clement Mwitwa'),
    ('202406172', 'Mary Banda'),
    ('202406173', 'Peter Phiri');

-- Six PENDING applications: qualifying, non-qualifying and boundary cases.
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
    (1, 18, 3000.00, 70.00, CURRENT_DATE - 6),   -- 1 all boundaries met        -> APPROVED
    (1, 25, 1500.00, 85.00, CURRENT_DATE - 5),   -- 2 upper age boundary        -> APPROVED
    (2, 17, 1000.00, 90.00, CURRENT_DATE - 4),   -- 3 too young                 -> REJECTED
    (2, 26,  500.00, 80.00, CURRENT_DATE - 3),   -- 4 too old                   -> REJECTED
    (3, 20, 3000.01, 75.00, CURRENT_DATE - 2),   -- 5 income one ngwee too high -> REJECTED
    (3, 22, 2000.00, 69.99, CURRENT_DATE - 1);   -- 6 mark just below 70        -> REJECTED

/* ===================== (b) Function ===================== */
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INTEGER, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark must not be NULL';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive, got %', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income must not be negative, got %', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100, got %', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25 AND p_income <= 3000 AND p_mark >= 70;
END;
$$;

/* ===================== (c) Procedure ===================== */
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    v_app applications%ROWTYPE;
BEGIN
    SELECT * INTO v_app FROM applications WHERE application_id = p_application_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Application % does not exist', p_application_id;
    END IF;
    IF v_app.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % was already assessed (status: %)', p_application_id, v_app.status;
    END IF;

    UPDATE applications
    SET status = CASE WHEN fn_scholarship_eligible(v_app.age_at_application, v_app.monthly_income, v_app.average_mark)
                      THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$;

/* ===================== (d) Trigger ===================== */
CREATE OR REPLACE FUNCTION trg_fn_decision_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (NEW.application_id, OLD.status, NEW.status, now());
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_applications_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)    -- unchanged status: no audit entry
EXECUTE FUNCTION trg_fn_decision_audit();

-- Function tests (boundaries)
SELECT fn_scholarship_eligible(18, 3000, 70)      AS lower_boundaries,   -- t
       fn_scholarship_eligible(25, 3000, 100)     AS upper_age,          -- t
       fn_scholarship_eligible(26, 100, 90)       AS too_old,            -- f
       fn_scholarship_eligible(20, 3000.01, 90)   AS income_too_high,    -- f
       fn_scholarship_eligible(20, 100, 69.99)    AS mark_too_low;       -- f
DO $$ BEGIN PERFORM fn_scholarship_eligible(NULL, 100, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, -1, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(0, 100, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 100, 101);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;

-- Procedure tests
CALL pr_assess_application(1);                     -- approved
DO $$ BEGIN CALL pr_assess_application(1);         -- already assessed
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_assess_application(99);        -- unknown
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;

-- Trigger test: an update that leaves status unchanged creates no audit entry
UPDATE applications SET monthly_income = monthly_income WHERE application_id = 2;
SELECT * FROM decision_audit;          -- only application 1: PENDING -> APPROVED

/* ===================== (e) View ===================== */
-- Shows only the required columns; household income is deliberately left out.
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

/* ===================== (f) Index ===================== */
-- Justification: the search is "status = X within a submitted_on range": equality column first,
-- range column second, so the B-tree jumps to one status and reads only the requested dates.
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);
ANALYZE applications;

SET enable_seqscan = off;   -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT * FROM applications
WHERE status = 'PENDING' AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

/* ===================== (g) Scheduled job ===================== */
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT application_id FROM applications WHERE status = 'PENDING' ORDER BY application_id
    LOOP
        CALL pr_assess_application(r.application_id);   -- completed applications are never touched
    END LOOP;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
-- Every Monday at 08:00 (pg_cron time zone).
SELECT cron.schedule('q10_assess_pending_weekly', '0 8 * * 1',
                     $$CALL q10_scholarship.pr_assess_pending()$$);

CALL pr_assess_pending();
CALL pr_assess_pending();      -- rerun: nothing is PENDING, so nothing is reassessed or re-audited
SELECT application_id, age_at_application, monthly_income, average_mark, status FROM applications ORDER BY 1;
SELECT * FROM decision_audit ORDER BY audit_id;          -- exactly 6 rows (one per application)
SELECT * FROM v_approved_applicants;                     -- applications 1 and 2
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q10_assess_pending_weekly';
