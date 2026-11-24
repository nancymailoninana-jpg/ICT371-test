-- =====================================================================
-- Library fines database (MySQL 8.0+)
-- Fine rule: K2 per day after due_on. Returned on the due date = K0.
-- Run with:  mysql -u root -p < library_fines_db.sql
-- =====================================================================
DROP DATABASE IF EXISTS library_db;
CREATE DATABASE library_db;
USE library_db;

-- =====================================================================
-- (a) TABLES
-- =====================================================================
CREATE TABLE books (
    book_id INT AUTO_INCREMENT PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE loans (
    loan_id       INT AUTO_INCREMENT PRIMARY KEY,
    book_id       INT           NOT NULL,
    borrower_name VARCHAR(100)  NOT NULL,
    borrowed_on   DATE          NOT NULL,
    due_on        DATE          NOT NULL,
    returned_on   DATE          NULL,
    fine_amount   DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    CONSTRAINT fk_loans_book FOREIGN KEY (book_id) REFERENCES books (book_id),
    CONSTRAINT chk_due_after_borrow CHECK (due_on >= borrowed_on),
    CONSTRAINT chk_return_after_borrow CHECK (returned_on IS NULL OR returned_on >= borrowed_on),
    CONSTRAINT chk_fine_nonneg CHECK (fine_amount >= 0)
) ENGINE=InnoDB;

CREATE TABLE loan_audit (
    audit_id          INT AUTO_INCREMENT PRIMARY KEY,
    loan_id           INT      NOT NULL,
    old_returned_on   DATE     NULL,
    new_returned_on   DATE     NULL,
    changed_at        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_audit_loan FOREIGN KEY (loan_id) REFERENCES loans (loan_id)
) ENGINE=InnoDB;

CREATE TABLE overdue_summary (
    snapshot_date DATE          PRIMARY KEY,
    overdue_count INT           NOT NULL DEFAULT 0,
    total_fine    DECIMAL(12,2) NOT NULL DEFAULT 0.00
) ENGINE=InnoDB;

INSERT INTO books (title) VALUES
    ('Things Fall Apart'),
    ('Introduction to Algorithms'),
    ('A Brief History of Time');

-- Six loans, dates relative to today so the overdue cases stay overdue.
-- Fines on open loans are computed on demand; fine_amount is stored at return.
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Alice Banda',   CURDATE() - INTERVAL 20 DAY, CURDATE() - INTERVAL  6 DAY),  -- 1 open, overdue
    (1, 'Brian Phiri',   CURDATE() - INTERVAL  5 DAY, CURDATE() + INTERVAL  9 DAY),  -- 2 open, on time
    (2, 'Chipo Mwale',   CURDATE() - INTERVAL 30 DAY, CURDATE() - INTERVAL 16 DAY),  -- 3 will be returned late
    (2, 'Daniel Zulu',   CURDATE() - INTERVAL 20 DAY, CURDATE() - INTERVAL 10 DAY),  -- 4 will be returned on due date
    (3, 'Esther Tembo',  CURDATE() - INTERVAL 12 DAY, CURDATE() - INTERVAL  2 DAY),  -- 5 open, overdue
    (3, 'Farai Lungu',   CURDATE() - INTERVAL  3 DAY, CURDATE() + INTERVAL 11 DAY);  -- 6 open, on time

DELIMITER $$

-- =====================================================================
-- (b) FUNCTION
-- =====================================================================
CREATE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS DECIMAL(10,2)
READS SQL DATA
BEGIN
    DECLARE v_due DATE;
    DECLARE v_ret DATE;
    DECLARE v_end DATE;
    DECLARE v_days INT;

    IF p_as_of IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'As-of date is required';
    END IF;

    SET v_due = (SELECT due_on FROM loans WHERE loan_id = p_loan_id);
    IF v_due IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown loan';
    END IF;

    SET v_ret = (SELECT returned_on FROM loans WHERE loan_id = p_loan_id);

    -- A returned loan stops accumulating fines at its return date
    IF v_ret IS NULL THEN
        SET v_end = p_as_of;
    ELSE
        SET v_end = LEAST(p_as_of, v_ret);
    END IF;

    SET v_days = GREATEST(DATEDIFF(v_end, v_due), 0);   -- on the due date = 0
    RETURN 2.00 * v_days;
END$$

-- =====================================================================
-- (c) PROCEDURE
-- =====================================================================
CREATE PROCEDURE pr_return_loan(IN p_loan_id INT, IN p_returned_on DATE)
BEGIN
    DECLARE v_borrowed DATE;
    DECLARE v_returned DATE;
    DECLARE v_fine     DECIMAL(10,2);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_returned_on IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Return date is required';
    END IF;

    START TRANSACTION;

    SELECT borrowed_on, returned_on
      INTO v_borrowed, v_returned
      FROM loans
     WHERE loan_id = p_loan_id
       FOR UPDATE;

    IF v_borrowed IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown loan';
    END IF;
    IF v_returned IS NOT NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Loan already returned';
    END IF;
    IF p_returned_on < v_borrowed THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Return date is before borrow date';
    END IF;

    -- Compute first into a variable: a function that reads LOANS cannot be
    -- called inside an UPDATE of LOANS. The loan is still open here, so the
    -- function measures up to p_returned_on, which is the final fine.
    SET v_fine = fn_loan_fine(p_loan_id, p_returned_on);

    UPDATE loans
       SET returned_on = p_returned_on,
           fine_amount = v_fine
     WHERE loan_id = p_loan_id;          -- one statement: both values together

    COMMIT;
END$$

-- =====================================================================
-- (d) TRIGGER
-- =====================================================================
CREATE TRIGGER trg_loans_return_audit
AFTER UPDATE ON loans
FOR EACH ROW
BEGIN
    IF NOT (OLD.returned_on <=> NEW.returned_on) THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
        VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
    END IF;
END$$

-- =====================================================================
-- (g) REFRESH PROCEDURE (idempotent)
-- Overdue as of p_as_of = borrowed by then, due before then, and not yet
-- returned on that date (returned later, or never). Each fine is
-- calculated as of p_as_of.
-- =====================================================================
CREATE PROCEDURE pr_refresh_overdue(IN p_as_of DATE)
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_as_of IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'As-of date is required';
    END IF;

    START TRANSACTION;

    DELETE FROM overdue_summary WHERE snapshot_date = p_as_of;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
      FROM loans
     WHERE borrowed_on <= p_as_of
       AND due_on < p_as_of
       AND (returned_on IS NULL OR returned_on > p_as_of);

    COMMIT;
END$$

DELIMITER ;

-- =====================================================================
-- (e) VIEW
-- =====================================================================
CREATE VIEW v_overdue_loans AS
SELECT l.loan_id,
       b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
  FROM loans l
  JOIN books b ON b.book_id = l.book_id
 WHERE l.returned_on IS NULL
   AND l.due_on < CURRENT_DATE;

-- =====================================================================
-- (f) INDEX
-- Query: WHERE book_id = ? AND returned_on IS NULL
-- Equality on book_id, then IS NULL on returned_on: both columns are
-- matched inside the index, so only that book's open loans are read.
-- (It also replaces the single-column FK index on book_id.)
-- =====================================================================
CREATE INDEX idx_loans_book_returned ON loans (book_id, returned_on);

-- =====================================================================
-- Return two loans through the procedure (also fills loan_audit)
-- =====================================================================
CALL pr_return_loan(3, CURDATE() - INTERVAL 10 DAY);   -- 6 days late  -> K12
CALL pr_return_loan(4, CURDATE() - INTERVAL 10 DAY);   -- on due date  -> K0

-- =====================================================================
-- TESTS / DEMONSTRATIONS
-- =====================================================================
-- (a)/(c) results
SELECT loan_id, borrower_name, due_on, returned_on, fine_amount FROM loans;

-- (b)
SELECT fn_loan_fine(1, CURDATE()) AS open_overdue_loan1,          -- 12.00
       fn_loan_fine(2, CURDATE()) AS on_time_loan2,               -- 0.00
       fn_loan_fine(3, CURDATE()) AS returned_late_stops_at_12,   -- 12.00
       fn_loan_fine(4, CURDATE()) AS returned_on_due_date;        -- 0.00
-- SELECT fn_loan_fine(99, CURDATE());                            -- error: Unknown loan

-- (c) invalid returns (run one at a time; each errors, nothing changes)
-- CALL pr_return_loan(99, CURDATE());                    -- unknown loan
-- CALL pr_return_loan(3,  CURDATE());                    -- already returned
-- CALL pr_return_loan(1,  CURDATE() - INTERVAL 30 DAY);  -- before borrowed_on

-- (d) audit rows from the two returns; a no-change update adds nothing
UPDATE loans SET returned_on = returned_on WHERE loan_id = 3;
UPDATE loans SET borrower_name = borrower_name WHERE loan_id = 1;
SELECT * FROM loan_audit ORDER BY audit_id;

-- (e)
SELECT * FROM v_overdue_loans;

-- (f)
ANALYZE TABLE loans;
EXPLAIN
SELECT loan_id, borrower_name, due_on
  FROM loans
 WHERE book_id = 1
   AND returned_on IS NULL;

-- (g) rerun: row is replaced, not duplicated
CALL pr_refresh_overdue(CURDATE());                    -- expect 2 loans, K16
CALL pr_refresh_overdue(CURDATE());
CALL pr_refresh_overdue(CURDATE() - INTERVAL 12 DAY);  -- loan 3 not yet returned then: 1 loan, K8
SELECT * FROM overdue_summary ORDER BY snapshot_date;

-- Scheduled job: every day at 00:10 for CURRENT_DATE
SET GLOBAL event_scheduler = ON;

CREATE EVENT ev_refresh_overdue_daily
ON SCHEDULE EVERY 1 DAY
STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 DAY + INTERVAL 10 MINUTE)
DO CALL pr_refresh_overdue(CURRENT_DATE);

SHOW EVENTS FROM library_db;