-- =====================================================================
-- University hostel allocation database (MySQL 8.0+)
-- Rules: ACTIVE allocations occupy beds, ENDED ones are history only.
--        Max ACTIVE per room = capacity; max one ACTIVE per student.
-- Run with:  mysql -u root -p < hostel_db.sql
-- =====================================================================
DROP DATABASE IF EXISTS hostel_db;
CREATE DATABASE hostel_db;
USE hostel_db;

-- =====================================================================
-- (a) TABLES
-- =====================================================================
CREATE TABLE students (
    student_id     INT AUTO_INCREMENT PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE rooms (
    room_id     INT AUTO_INCREMENT PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INT         NOT NULL,
    CONSTRAINT chk_room_capacity CHECK (capacity > 0)
) ENGINE=InnoDB;

CREATE TABLE allocations (
    allocation_id INT AUTO_INCREMENT PRIMARY KEY,
    student_id    INT  NOT NULL,
    room_id       INT  NOT NULL,
    allocated_on  DATE NOT NULL,
    released_on   DATE NULL,
    status        ENUM('ACTIVE','ENDED') NOT NULL DEFAULT 'ACTIVE',

    -- Backstop for "one ACTIVE allocation per student": holds the student_id
    -- only while ACTIVE (NULL otherwise), and UNIQUE allows many NULLs, so any
    -- number of ENDED rows are fine but a second ACTIVE row is impossible.
    active_student INT GENERATED ALWAYS AS
        (IF(status = 'ACTIVE', student_id, NULL)) STORED,

    CONSTRAINT fk_alloc_student FOREIGN KEY (student_id) REFERENCES students (student_id),
    CONSTRAINT fk_alloc_room    FOREIGN KEY (room_id)    REFERENCES rooms (room_id),
    CONSTRAINT chk_status_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL)),
    CONSTRAINT chk_release_after_alloc CHECK (released_on IS NULL OR released_on >= allocated_on),
    UNIQUE KEY uq_one_active_per_student (active_student)
) ENGINE=InnoDB;

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id       INT  NOT NULL,
    occupied_beds INT  NOT NULL,
    free_beds     INT  NOT NULL,
    PRIMARY KEY (snapshot_date, room_id),
    CONSTRAINT fk_snap_room FOREIGN KEY (room_id) REFERENCES rooms (room_id),
    CONSTRAINT chk_snap_occupied CHECK (occupied_beds >= 0),
    CONSTRAINT chk_snap_free     CHECK (free_beds >= 0)
) ENGINE=InnoDB;

INSERT INTO students (student_number, full_name) VALUES
    ('S2026001', 'Amina Khan'),
    ('S2026002', 'Brian Otieno'),
    ('S2026003', 'Chipo Mwale'),
    ('S2026004', 'Daniel Zulu'),
    ('S2026005', 'Esther Tembo'),
    ('S2026006', 'Farai Lungu');

INSERT INTO rooms (room_number, capacity) VALUES
    ('R101', 2),    -- will be full
    ('R102', 3),    -- will be partly occupied
    ('R103', 2),    -- empty (only ended history)
    ('R104', 3);    -- empty (never used)

DELIMITER $$

-- =====================================================================
-- (b) FUNCTION
-- =====================================================================
CREATE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT
READS SQL DATA
BEGIN
    DECLARE v_capacity INT;

    SET v_capacity = (SELECT capacity FROM rooms WHERE room_id = p_room_id);

    IF v_capacity IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown room';
    END IF;

    -- Only ACTIVE allocations occupy beds; ENDED rows are ignored
    RETURN v_capacity - (SELECT COUNT(*)
                           FROM allocations
                          WHERE room_id = p_room_id
                            AND status = 'ACTIVE');
END$$

-- =====================================================================
-- (c) PROCEDURE
-- =====================================================================
CREATE PROCEDURE pr_allocate_room(
    IN p_student_id   INT,
    IN p_room_id      INT,
    IN p_allocated_on DATE
)
BEGIN
    DECLARE v_capacity INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_student_id IS NULL OR p_room_id IS NULL OR p_allocated_on IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'All parameters are required';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown student';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM rooms WHERE room_id = p_room_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown room';
    END IF;

    START TRANSACTION;

    -- Lock the room row: allocations for one room are processed one at a time,
    -- so two sessions cannot both take the last bed
    SELECT capacity INTO v_capacity
      FROM rooms
     WHERE room_id = p_room_id
       FOR UPDATE;

    IF EXISTS (SELECT 1 FROM allocations
                WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Student already has an ACTIVE allocation';
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Room is full';
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');

    COMMIT;
END$$

-- =====================================================================
-- (d) TRIGGERS
-- MySQL has no "BEFORE INSERT OR UPDATE" trigger, so the same rules are
-- written as two triggers, one per event. They protect against direct SQL.
-- Only the UPDATE trigger excludes the row being changed.
-- =====================================================================
CREATE TRIGGER trg_alloc_before_insert
BEFORE INSERT ON allocations
FOR EACH ROW
BEGIN
    DECLARE v_capacity INT;
    DECLARE v_in_room  INT;
    DECLARE v_student  INT;

    IF NEW.status = 'ACTIVE' THEN
        SET v_capacity = (SELECT capacity FROM rooms WHERE room_id = NEW.room_id);

        SELECT COUNT(*) INTO v_student
          FROM allocations
         WHERE student_id = NEW.student_id AND status = 'ACTIVE';
        IF v_student > 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Student already has an ACTIVE allocation';
        END IF;

        SELECT COUNT(*) INTO v_in_room
          FROM allocations
         WHERE room_id = NEW.room_id AND status = 'ACTIVE';
        IF v_in_room >= v_capacity THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Room capacity exceeded';
        END IF;
    END IF;
END$$

CREATE TRIGGER trg_alloc_before_update
BEFORE UPDATE ON allocations
FOR EACH ROW
BEGIN
    DECLARE v_capacity INT;
    DECLARE v_in_room  INT;
    DECLARE v_student  INT;

    IF NEW.status = 'ACTIVE' THEN
        SET v_capacity = (SELECT capacity FROM rooms WHERE room_id = NEW.room_id);

        SELECT COUNT(*) INTO v_student
          FROM allocations
         WHERE student_id = NEW.student_id
           AND status = 'ACTIVE'
           AND allocation_id <> NEW.allocation_id;      -- exclude the row being updated
        IF v_student > 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Student already has an ACTIVE allocation';
        END IF;

        SELECT COUNT(*) INTO v_in_room
          FROM allocations
         WHERE room_id = NEW.room_id
           AND status = 'ACTIVE'
           AND allocation_id <> NEW.allocation_id;      -- exclude the row being updated
        IF v_in_room >= v_capacity THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Room capacity exceeded';
        END IF;
    END IF;
END$$

-- =====================================================================
-- (g) REFRESH PROCEDURE (idempotent: one row per date and room)
-- =====================================================================
CREATE PROCEDURE pr_refresh_occupancy()
BEGIN
    DECLARE v_today DATE;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SET v_today = CURRENT_DATE;          -- read once so the whole run uses one date

    START TRANSACTION;

    DELETE FROM occupancy_snapshot WHERE snapshot_date = v_today;

    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT v_today,
           r.room_id,
           COUNT(a.allocation_id),
           r.capacity - COUNT(a.allocation_id)
      FROM rooms r
      LEFT JOIN allocations a
             ON a.room_id = r.room_id AND a.status = 'ACTIVE'
     GROUP BY r.room_id, r.capacity;

    COMMIT;
END$$

DELIMITER ;

-- =====================================================================
-- (e) VIEW - the ACTIVE test sits in the JOIN condition (not WHERE), so
-- rooms with no allocations still appear.
-- =====================================================================
CREATE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)               AS occupied_beds,
       r.capacity - COUNT(a.allocation_id)  AS free_beds
  FROM rooms r
  LEFT JOIN allocations a
         ON a.room_id = r.room_id AND a.status = 'ACTIVE'
 GROUP BY r.room_id, r.room_number, r.capacity;

-- =====================================================================
-- (f) INDEX
-- Query: WHERE room_id = ? AND status = 'ACTIVE'
-- Both are equality tests, so one lookup reaches exactly that room's ACTIVE
-- rows; ENDED history is never read. The same lookup is used by
-- fn_free_beds, the triggers and the views. It also replaces the
-- single-column FK index on room_id.
-- =====================================================================
CREATE INDEX idx_alloc_room_status ON allocations (room_id, status);

-- =====================================================================
-- (a) SEED ALLOCATIONS - through the procedure
-- =====================================================================
CALL pr_allocate_room(1, 1, CURDATE() - INTERVAL 30 DAY);   -- R101 (1/2)
CALL pr_allocate_room(2, 1, CURDATE() - INTERVAL 28 DAY);   -- R101 (2/2) full
CALL pr_allocate_room(3, 2, CURDATE() - INTERVAL 20 DAY);   -- R102 (1/3)
CALL pr_allocate_room(4, 2, CURDATE() - INTERVAL 15 DAY);   -- R102 (2/3) partly occupied
CALL pr_allocate_room(5, 3, CURDATE() - INTERVAL 10 DAY);   -- R103, ended next

-- Student 5 leaves: the row becomes history and frees the bed
UPDATE allocations
   SET status = 'ENDED', released_on = CURDATE()
 WHERE allocation_id = 5;
-- Student 6 has no allocation yet.

-- =====================================================================
-- TESTS / DEMONSTRATIONS
-- =====================================================================
SELECT allocation_id, student_id, room_id, allocated_on, released_on, status
  FROM allocations;

-- (b)  expected 0, 1, 2 (ended row ignored), 3
SELECT fn_free_beds(1) AS r101_full,
       fn_free_beds(2) AS r102_partly,
       fn_free_beds(3) AS r103_only_ended,
       fn_free_beds(4) AS r104_empty;
-- SELECT fn_free_beds(99);                              -- error: Unknown room

-- (c) invalid allocations (run one at a time; each errors, nothing changes)
-- CALL pr_allocate_room(99, 2, CURDATE());              -- unknown student
-- CALL pr_allocate_room(6, 99, CURDATE());              -- unknown room
-- CALL pr_allocate_room(6, 1, CURDATE());               -- room full
-- CALL pr_allocate_room(1, 2, CURDATE());               -- student 1 already ACTIVE
-- Valid: student 5 can now be re-housed, student 6 housed
-- CALL pr_allocate_room(6, 2, CURDATE());

-- (d) direct SQL is also protected (run one at a time; each errors)
-- INSERT INTO allocations (student_id, room_id, allocated_on, status)
--   VALUES (6, 1, CURDATE(), 'ACTIVE');                 -- capacity exceeded
-- INSERT INTO allocations (student_id, room_id, allocated_on, status)
--   VALUES (1, 4, CURDATE(), 'ACTIVE');                 -- second ACTIVE for student 1
-- UPDATE allocations SET status='ACTIVE', released_on=NULL
--   WHERE allocation_id = 5;                            -- legal: R103 has room, student 5 has no ACTIVE
-- INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
--   VALUES (6, 4, CURDATE(), CURDATE(), 'ACTIVE');      -- CHECK: ACTIVE needs released_on NULL
-- Updating a row in a FULL room does not clash with itself:
UPDATE allocations SET allocated_on = allocated_on WHERE allocation_id = 1;

-- (e)  expected: R101 2/0, R102 2/1, R103 0/2, R104 0/3
SELECT * FROM v_room_occupancy;

-- (f)
ANALYZE TABLE allocations;
EXPLAIN
SELECT allocation_id, student_id, allocated_on
  FROM allocations
 WHERE room_id = 2
   AND status = 'ACTIVE';

-- (g) rerun: still exactly one row per date and room
CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();
SELECT * FROM occupancy_snapshot ORDER BY snapshot_date, room_id;

-- Scheduled job: every day at 23:55
SET GLOBAL event_scheduler = ON;

CREATE EVENT ev_refresh_occupancy_daily
ON SCHEDULE EVERY 1 DAY
STARTS TIMESTAMP(CURRENT_DATE, '23:55:00')
DO CALL pr_refresh_occupancy();

SHOW EVENTS FROM hostel_db;
DROP DATABASE IF EXISTS hostel_db;
CREATE DATABASE hostel_db;
USE hostel_db;

-- =====================================================================
-- (a) TABLES
-- =====================================================================
CREATE TABLE students (
    student_id     INT AUTO_INCREMENT PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE rooms (
    room_id     INT AUTO_INCREMENT PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INT         NOT NULL,
    CONSTRAINT chk_room_capacity CHECK (capacity > 0)
) ENGINE=InnoDB;

CREATE TABLE allocations (
    allocation_id INT AUTO_INCREMENT PRIMARY KEY,
    student_id    INT  NOT NULL,
    room_id       INT  NOT NULL,
    allocated_on  DATE NOT NULL,
    released_on   DATE NULL,
    status        ENUM('ACTIVE','ENDED') NOT NULL DEFAULT 'ACTIVE',

    -- Backstop for "one ACTIVE allocation per student": holds the student_id
    -- only while ACTIVE (NULL otherwise), and UNIQUE allows many NULLs, so any
    -- number of ENDED rows are fine but a second ACTIVE row is impossible.
    active_student INT GENERATED ALWAYS AS
        (IF(status = 'ACTIVE', student_id, NULL)) STORED,

    CONSTRAINT fk_alloc_student FOREIGN KEY (student_id) REFERENCES students (student_id),
    CONSTRAINT fk_alloc_room    FOREIGN KEY (room_id)    REFERENCES rooms (room_id),
    CONSTRAINT chk_status_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL)),
    CONSTRAINT chk_release_after_alloc CHECK (released_on IS NULL OR released_on >= allocated_on),
    UNIQUE KEY uq_one_active_per_student (active_student)
) ENGINE=InnoDB;

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id       INT  NOT NULL,
    occupied_beds INT  NOT NULL,
    free_beds     INT  NOT NULL,
    PRIMARY KEY (snapshot_date, room_id),
    CONSTRAINT fk_snap_room FOREIGN KEY (room_id) REFERENCES rooms (room_id),
    CONSTRAINT chk_snap_occupied CHECK (occupied_beds >= 0),
    CONSTRAINT chk_snap_free     CHECK (free_beds >= 0)
) ENGINE=InnoDB;

INSERT INTO students (student_number, full_name) VALUES
    ('S2026001', 'Amina Khan'),
    ('S2026002', 'Brian Otieno'),
    ('S2026003', 'Chipo Mwale'),
    ('S2026004', 'Daniel Zulu'),
    ('S2026005', 'Esther Tembo'),
    ('S2026006', 'Farai Lungu');

INSERT INTO rooms (room_number, capacity) VALUES
    ('R101', 2),    -- will be full
    ('R102', 3),    -- will be partly occupied
    ('R103', 2),    -- empty (only ended history)
    ('R104', 3);    -- empty (never used)

DELIMITER $$

-- =====================================================================
-- (b) FUNCTION
-- =====================================================================
CREATE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT
READS SQL DATA
BEGIN
    DECLARE v_capacity INT;

    SET v_capacity = (SELECT capacity FROM rooms WHERE room_id = p_room_id);

    IF v_capacity IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown room';
    END IF;

    -- Only ACTIVE allocations occupy beds; ENDED rows are ignored
    RETURN v_capacity - (SELECT COUNT(*)
                           FROM allocations
                          WHERE room_id = p_room_id
                            AND status = 'ACTIVE');
END$$

-- =====================================================================
-- (c) PROCEDURE
-- =====================================================================
CREATE PROCEDURE pr_allocate_room(
    IN p_student_id   INT,
    IN p_room_id      INT,
    IN p_allocated_on DATE
)
BEGIN
    DECLARE v_capacity INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_student_id IS NULL OR p_room_id IS NULL OR p_allocated_on IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'All parameters are required';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown student';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM rooms WHERE room_id = p_room_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown room';
    END IF;

    START TRANSACTION;

    -- Lock the room row: allocations for one room are processed one at a time,
    -- so two sessions cannot both take the last bed
    SELECT capacity INTO v_capacity
      FROM rooms
     WHERE room_id = p_room_id
       FOR UPDATE;

    IF EXISTS (SELECT 1 FROM allocations
                WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Student already has an ACTIVE allocation';
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Room is full';
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');

    COMMIT;
END$$

-- =====================================================================
-- (d) TRIGGERS
-- MySQL has no "BEFORE INSERT OR UPDATE" trigger, so the same rules are
-- written as two triggers, one per event. They protect against direct SQL.
-- Only the UPDATE trigger excludes the row being changed.
-- =====================================================================
CREATE TRIGGER trg_alloc_before_insert
BEFORE INSERT ON allocations
FOR EACH ROW
BEGIN
    DECLARE v_capacity INT;
    DECLARE v_in_room  INT;
    DECLARE v_student  INT;

    IF NEW.status = 'ACTIVE' THEN
        SET v_capacity = (SELECT capacity FROM rooms WHERE room_id = NEW.room_id);

        SELECT COUNT(*) INTO v_student
          FROM allocations
         WHERE student_id = NEW.student_id AND status = 'ACTIVE';
        IF v_student > 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Student already has an ACTIVE allocation';
        END IF;

        SELECT COUNT(*) INTO v_in_room
          FROM allocations
         WHERE room_id = NEW.room_id AND status = 'ACTIVE';
        IF v_in_room >= v_capacity THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Room capacity exceeded';
        END IF;
    END IF;
END$$

CREATE TRIGGER trg_alloc_before_update
BEFORE UPDATE ON allocations
FOR EACH ROW
BEGIN
    DECLARE v_capacity INT;
    DECLARE v_in_room  INT;
    DECLARE v_student  INT;

    IF NEW.status = 'ACTIVE' THEN
        SET v_capacity = (SELECT capacity FROM rooms WHERE room_id = NEW.room_id);

        SELECT COUNT(*) INTO v_student
          FROM allocations
         WHERE student_id = NEW.student_id
           AND status = 'ACTIVE'
           AND allocation_id <> NEW.allocation_id;      -- exclude the row being updated
        IF v_student > 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Student already has an ACTIVE allocation';
        END IF;

        SELECT COUNT(*) INTO v_in_room
          FROM allocations
         WHERE room_id = NEW.room_id
           AND status = 'ACTIVE'
           AND allocation_id <> NEW.allocation_id;      -- exclude the row being updated
        IF v_in_room >= v_capacity THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Room capacity exceeded';
        END IF;
    END IF;
END$$

-- =====================================================================
-- (g) REFRESH PROCEDURE (idempotent: one row per date and room)
-- =====================================================================
CREATE PROCEDURE pr_refresh_occupancy()
BEGIN
    DECLARE v_today DATE;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SET v_today = CURRENT_DATE;          -- read once so the whole run uses one date

    START TRANSACTION;

    DELETE FROM occupancy_snapshot WHERE snapshot_date = v_today;

    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT v_today,
           r.room_id,
           COUNT(a.allocation_id),
           r.capacity - COUNT(a.allocation_id)
      FROM rooms r
      LEFT JOIN allocations a
             ON a.room_id = r.room_id AND a.status = 'ACTIVE'
     GROUP BY r.room_id, r.capacity;

    COMMIT;
END$$

DELIMITER ;

-- =====================================================================
-- (e) VIEW - the ACTIVE test sits in the JOIN condition (not WHERE), so
-- rooms with no allocations still appear.
-- =====================================================================
CREATE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)               AS occupied_beds,
       r.capacity - COUNT(a.allocation_id)  AS free_beds
  FROM rooms r
  LEFT JOIN allocations a
         ON a.room_id = r.room_id AND a.status = 'ACTIVE'
 GROUP BY r.room_id, r.room_number, r.capacity;

-- =====================================================================
-- (f) INDEX
-- Query: WHERE room_id = ? AND status = 'ACTIVE'
-- Both are equality tests, so one lookup reaches exactly that room's ACTIVE
-- rows; ENDED history is never read. The same lookup is used by
-- fn_free_beds, the triggers and the views. It also replaces the
-- single-column FK index on room_id.
-- =====================================================================
CREATE INDEX idx_alloc_room_status ON allocations (room_id, status);

-- =====================================================================
-- (a) SEED ALLOCATIONS - through the procedure
-- =====================================================================
CALL pr_allocate_room(1, 1, CURDATE() - INTERVAL 30 DAY);   -- R101 (1/2)
CALL pr_allocate_room(2, 1, CURDATE() - INTERVAL 28 DAY);   -- R101 (2/2) full
CALL pr_allocate_room(3, 2, CURDATE() - INTERVAL 20 DAY);   -- R102 (1/3)
CALL pr_allocate_room(4, 2, CURDATE() - INTERVAL 15 DAY);   -- R102 (2/3) partly occupied
CALL pr_allocate_room(5, 3, CURDATE() - INTERVAL 10 DAY);   -- R103, ended next

-- Student 5 leaves: the row becomes history and frees the bed
UPDATE allocations
   SET status = 'ENDED', released_on = CURDATE()
 WHERE allocation_id = 5;
-- Student 6 has no allocation yet.

-- =====================================================================
-- TESTS / DEMONSTRATIONS
-- =====================================================================
SELECT allocation_id, student_id, room_id, allocated_on, released_on, status
  FROM allocations;

-- (b)  expected 0, 1, 2 (ended row ignored), 3
SELECT fn_free_beds(1) AS r101_full,
       fn_free_beds(2) AS r102_partly,
       fn_free_beds(3) AS r103_only_ended,
       fn_free_beds(4) AS r104_empty;
-- SELECT fn_free_beds(99);                              -- error: Unknown room

-- (c) invalid allocations (run one at a time; each errors, nothing changes)
-- CALL pr_allocate_room(99, 2, CURDATE());              -- unknown student
-- CALL pr_allocate_room(6, 99, CURDATE());              -- unknown room
-- CALL pr_allocate_room(6, 1, CURDATE());               -- room full
-- CALL pr_allocate_room(1, 2, CURDATE());               -- student 1 already ACTIVE
-- Valid: student 5 can now be re-housed, student 6 housed
-- CALL pr_allocate_room(6, 2, CURDATE());

-- (d) direct SQL is also protected (run one at a time; each errors)
-- INSERT INTO allocations (student_id, room_id, allocated_on, status)
--   VALUES (6, 1, CURDATE(), 'ACTIVE');                 -- capacity exceeded
-- INSERT INTO allocations (student_id, room_id, allocated_on, status)
--   VALUES (1, 4, CURDATE(), 'ACTIVE');                 -- second ACTIVE for student 1
-- UPDATE allocations SET status='ACTIVE', released_on=NULL
--   WHERE allocation_id = 5;                            -- legal: R103 has room, student 5 has no ACTIVE
-- INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
--   VALUES (6, 4, CURDATE(), CURDATE(), 'ACTIVE');      -- CHECK: ACTIVE needs released_on NULL
-- Updating a row in a FULL room does not clash with itself:
UPDATE allocations SET allocated_on = allocated_on WHERE allocation_id = 1;

-- (e)  expected: R101 2/0, R102 2/1, R103 0/2, R104 0/3
SELECT * FROM v_room_occupancy;

-- (f)
ANALYZE TABLE allocations;
EXPLAIN
SELECT allocation_id, student_id, allocated_on
  FROM allocations
 WHERE room_id = 2
   AND status = 'ACTIVE';

-- (g) rerun: still exactly one row per date and room
CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();
SELECT * FROM occupancy_snapshot ORDER BY snapshot_date, room_id;

-- Scheduled job: every day at 23:55
SET GLOBAL event_scheduler = ON;

CREATE EVENT ev_refresh_occupancy_daily
ON SCHEDULE EVERY 1 DAY
STARTS TIMESTAMP(CURRENT_DATE, '23:55:00')
DO CALL pr_refresh_occupancy();

SHOW EVENTS FROM hostel_db;