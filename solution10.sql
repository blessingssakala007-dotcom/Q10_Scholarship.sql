
-- Q10 - Scholarship Application Assessment
-- Qualify: age 18-25 inclusive AND income <= K3000 AND average_mark >= 70
-- Statuses: PENDING, APPROVED, REJECTED

-- (a) Tables
CREATE TABLE IF NOT EXISTS students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE IF NOT EXISTS applications (
    application_id SERIAL PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id),
    age_at_application INT NOT NULL CHECK (age_at_application > 0),
    monthly_income NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark NUMERIC(5,2) NOT NULL CHECK (average_mark >= 0 AND average_mark <= 100),
    submitted_on DATE NOT NULL,
    status VARCHAR(10) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','APPROVED','REJECTED'))
);

CREATE TABLE IF NOT EXISTS decision_audit (
    audit_id SERIAL PRIMARY KEY,
    application_id INT NOT NULL REFERENCES applications(application_id),
    old_status VARCHAR(10),
    new_status VARCHAR(10) NOT NULL,
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- (b) Function: eligible?
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark must not be NULL';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive: %', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income must not be negative: %', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100: %', p_mark;
    END IF;
    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark >= 70;
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure: assess one application
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
AS $$
DECLARE
    r RECORD;
    v_eligible BOOLEAN;
BEGIN
    SELECT * INTO r FROM applications WHERE application_id = p_application_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application: %', p_application_id;
    END IF;
    IF r.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % is already assessed: %', p_application_id, r.status;
    END IF;
    v_eligible := fn_scholarship_eligible(r.age_at_application, r.monthly_income, r.average_mark);
    UPDATE applications
    SET status = CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$ LANGUAGE plpgsql;

-- (d) Trigger: log actual status changes only, using OLD and NEW
CREATE OR REPLACE FUNCTION trg_decision_audit_fn()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO decision_audit(application_id, old_status, new_status, changed_at)
        VALUES (NEW.application_id, OLD.status, NEW.status, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_decision_audit ON applications;
CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW EXECUTE FUNCTION trg_decision_audit_fn();

-- (a) Seed data: 6 PENDING, qualifying + non-qualifying + boundary, across 3+ students
INSERT INTO students(student_number, full_name) VALUES
('STU001', 'Chanda Mwila'),
('STU002', 'Grace Banda'),
('STU003', 'Peter Phiri')
ON CONFLICT (student_number) DO NOTHING;

INSERT INTO applications(student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
(1, 20, 2500.00, 85.00, '2026-01-05', 'PENDING'), -- qualifies
(1, 26, 2500.00, 85.00, '2026-01-06', 'PENDING'), -- fails age
(2, 18, 3000.00, 70.00, '2026-01-05', 'PENDING'), -- boundary: qualifies (18, 3000, 70)
(2, 25, 3000.00, 70.00, '2026-01-07', 'PENDING'), -- boundary: qualifies (25, 3000, 70)
(3, 22, 3500.00, 90.00, '2026-01-06', 'PENDING'), -- fails income
(3, 19, 2000.00, 65.00, '2026-01-08', 'PENDING')  -- fails mark
ON CONFLICT DO NOTHING;

-- (e) View: approved only, omit household income
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- (f) Index: applications by status within a submitted_on range
-- Justification: Equality on status + range on submitted_on matches
-- WHERE status = ? AND submitted_on BETWEEN ? AND ? exactly,
-- so Postgres seeks instead of scanning all applications.
CREATE INDEX IF NOT EXISTS idx_applications_status_date
ON applications(status, submitted_on);

-- Matching query + plan:
-- EXPLAIN SELECT * FROM applications WHERE status = 'PENDING' AND submitted_on BETWEEN '2026-01-01' AND '2026-01-31';
EXPLAIN SELECT * FROM applications WHERE status = 'PENDING' AND submitted_on BETWEEN '2026-01-01' AND '2026-01-31';

-- (g) Scheduled job: assess all PENDING, FOR loop through procedure
-- Rerun does not reassess completed ones (loop only PENDING),
-- so no duplicate audit entries.
CREATE OR REPLACE PROCEDURE pr_assess_pending()
AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT application_id FROM applications WHERE status = 'PENDING' ORDER BY application_id LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Test: assess all pending, rerun must do nothing:
CALL pr_assess_pending();
CALL pr_assess_pending();

-- Schedule every Monday at 08:00 (pg_cron):
-- SELECT cron.schedule('assess-pending-weekly', '0 8 * * 1',
--   $$CALL pr_assess_pending()$$);

-- Checks:
SELECT * FROM v_approved_applicants;
SELECT fn_scholarship_eligible(20, 2500, 85);
SELECT fn_scholarship_eligible(18, 3000, 70);
SELECT * FROM applications ORDER BY application_id;
SELECT * FROM decision_audit ORDER BY audit_id;