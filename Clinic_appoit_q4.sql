
DROP DATABASE IF EXISTS clinic_db;
CREATE DATABASE clinic_db;
USE clinic_db;

-- =====================================================================
-- (a) TABLES
-- =====================================================================
CREATE TABLE patients (
    patient_id INT AUTO_INCREMENT PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE doctors (
    doctor_id INT AUTO_INCREMENT PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE appointments (
    appointment_id  INT AUTO_INCREMENT PRIMARY KEY,
    patient_id      INT  NOT NULL,
    doctor_id       INT  NOT NULL,
    appointment_day DATE NOT NULL,
    slot_time       TIME NOT NULL,
    status          ENUM('BOOKED','ATTENDED','CANCELLED') NOT NULL DEFAULT 'BOOKED',

    -- Backstop for the slot rule: non-NULL only for non-cancelled rows, so a
    -- UNIQUE index on it blocks double booking even if two sessions race.
    -- (UNIQUE allows many NULLs, so cancelled rows never block a slot.)
    slot_key VARCHAR(40) GENERATED ALWAYS AS (
        IF(status = 'CANCELLED', NULL,
           CONCAT(doctor_id, '|', appointment_day, '|', slot_time))
    ) STORED,

    CONSTRAINT fk_appt_patient FOREIGN KEY (patient_id) REFERENCES patients (patient_id),
    CONSTRAINT fk_appt_doctor  FOREIGN KEY (doctor_id)  REFERENCES doctors (doctor_id),
    CONSTRAINT chk_slot CHECK (slot_time IN
        (TIME '09:00:00', TIME '10:00:00', TIME '11:00:00', TIME '12:00:00')),
    UNIQUE KEY uq_active_slot (slot_key)
) ENGINE=InnoDB;

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INT NOT NULL DEFAULT 0,
    attended_count  INT NOT NULL DEFAULT 0,
    cancelled_count INT NOT NULL DEFAULT 0
) ENGINE=InnoDB;

INSERT INTO patients (full_name) VALUES
    ('Alice Banda'), ('Bruno Phiri'), ('Carla Mwale');

INSERT INTO doctors (full_name) VALUES
    ('Dr Mensah'), ('Dr Okafor'), ('Dr Singh');

DELIMITER $$

-- =====================================================================
-- (b) FUNCTION
-- =====================================================================
CREATE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT
READS SQL DATA
BEGIN
    IF p_day IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Day is required';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown doctor';
    END IF;

    -- COUNT(*) is 0 when the day has no bookings
    RETURN (SELECT COUNT(*)
              FROM appointments
             WHERE doctor_id = p_doctor_id
               AND appointment_day = p_day
               AND status <> 'CANCELLED');
END$$

-- =====================================================================
-- (d) TRIGGERS
-- MySQL has no "BEFORE INSERT OR UPDATE" trigger, so the same rule is
-- written as two triggers, one per event.
-- =====================================================================
CREATE TRIGGER trg_appt_before_insert
BEFORE INSERT ON appointments
FOR EACH ROW
BEGIN
    DECLARE v_clash INT;

    IF NEW.status <> 'CANCELLED' THEN
        SELECT COUNT(*) INTO v_clash
          FROM appointments
         WHERE doctor_id       = NEW.doctor_id
           AND appointment_day = NEW.appointment_day
           AND slot_time       = NEW.slot_time
           AND status         <> 'CANCELLED';

        IF v_clash > 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Doctor already has an appointment in this slot';
        END IF;
    END IF;
END$$

CREATE TRIGGER trg_appt_before_update
BEFORE UPDATE ON appointments
FOR EACH ROW
BEGIN
    DECLARE v_clash INT;

    IF NEW.status <> 'CANCELLED' THEN
        SELECT COUNT(*) INTO v_clash
          FROM appointments
         WHERE doctor_id       = NEW.doctor_id
           AND appointment_day = NEW.appointment_day
           AND slot_time       = NEW.slot_time
           AND status         <> 'CANCELLED'
           AND appointment_id <> NEW.appointment_id;   -- exclude the row being changed

        IF v_clash > 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Doctor already has an appointment in this slot';
        END IF;
    END IF;
END$$

-- =====================================================================
-- (c) PROCEDURE
-- =====================================================================
CREATE PROCEDURE pr_book_appointment(
    IN p_patient_id INT,
    IN p_doctor_id  INT,
    IN p_day        DATE,
    IN p_slot       TIME
)
BEGIN
    DECLARE v_doctor INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_patient_id IS NULL OR p_doctor_id IS NULL
       OR p_day IS NULL OR p_slot IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'All parameters are required';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown patient';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown doctor';
    END IF;

    IF p_day < CURRENT_DATE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Appointment date is in the past';
    END IF;

    IF p_slot NOT IN (TIME '09:00:00', TIME '10:00:00',
                      TIME '11:00:00', TIME '12:00:00') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unsupported slot (use 09:00, 10:00, 11:00 or 12:00)';
    END IF;

    START TRANSACTION;

    -- Serialise bookings for one doctor so two sessions cannot both pass
    -- the trigger's clash check at the same moment
    SELECT doctor_id INTO v_doctor
      FROM doctors
     WHERE doctor_id = p_doctor_id
       FOR UPDATE;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');   -- trigger checks the clash

    COMMIT;
END$$

-- =====================================================================
-- (g) REFRESH PROCEDURE (idempotent)
-- =====================================================================
CREATE PROCEDURE pr_refresh_clinic_summary(IN p_day DATE)
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_day IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Day is required';
    END IF;

    START TRANSACTION;

    DELETE FROM clinic_summary WHERE summary_date = p_day;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COALESCE(SUM(status = 'BOOKED'),    0),
           COALESCE(SUM(status = 'ATTENDED'),  0),
           COALESCE(SUM(status = 'CANCELLED'), 0)
      FROM appointments
     WHERE appointment_day = p_day;

    COMMIT;
END$$

DELIMITER ;

-- =====================================================================
-- (e) VIEW - patient and doctor names only; no other patient data
-- =====================================================================
CREATE VIEW v_today_appointments AS
SELECT a.appointment_id,
       a.slot_time,
       p.full_name AS patient_name,
       d.full_name AS doctor_name
  FROM appointments a
  JOIN patients p ON p.patient_id = a.patient_id
  JOIN doctors  d ON d.doctor_id  = a.doctor_id
 WHERE a.appointment_day = CURRENT_DATE
   AND a.status = 'BOOKED';

-- =====================================================================
-- (f) INDEX
-- Query: WHERE appointment_day = ? AND doctor_id = ?
-- Both are equality tests, so one index lookup finds exactly that doctor's
-- appointments for the day. Day comes first so the same index also serves
-- day-only queries (today's list, the daily summary) via its left prefix.
-- It is non-unique: one doctor has up to four appointments on a day.
-- =====================================================================
CREATE INDEX idx_appt_day_doctor ON appointments (appointment_day, doctor_id);

-- =====================================================================
-- (a) SEED APPOINTMENTS - six, loaded through the procedure
-- =====================================================================
CALL pr_book_appointment(1, 1, CURDATE(),                   TIME '09:00:00');  -- 1
CALL pr_book_appointment(2, 1, CURDATE(),                   TIME '10:00:00');  -- 2
CALL pr_book_appointment(3, 2, CURDATE(),                   TIME '09:00:00');  -- 3 (other doctor, same slot: OK)
CALL pr_book_appointment(1, 2, CURDATE() + INTERVAL 1 DAY,  TIME '11:00:00');  -- 4
CALL pr_book_appointment(2, 3, CURDATE(),                   TIME '12:00:00');  -- 5
CALL pr_book_appointment(3, 1, CURDATE() + INTERVAL 1 DAY,  TIME '09:00:00');  -- 6

-- Give the data a mix of statuses
UPDATE appointments SET status = 'ATTENDED'  WHERE appointment_id = 1;
UPDATE appointments SET status = 'CANCELLED' WHERE appointment_id = 2;

-- =====================================================================
-- TESTS / DEMONSTRATIONS
-- =====================================================================
SELECT appointment_id, patient_id, doctor_id, appointment_day, slot_time, status
  FROM appointments;

-- (b)  expected: 1 (appt 1 attended counts, appt 2 cancelled does not), 0, 0
SELECT fn_daily_load(1, CURDATE())                     AS dr1_today,
       fn_daily_load(1, CURDATE() + INTERVAL 5 DAY)    AS dr1_no_bookings,
       fn_daily_load(3, CURDATE() + INTERVAL 1 DAY)    AS dr3_tomorrow;
-- SELECT fn_daily_load(99, CURDATE());                -- error: Unknown doctor

-- (c) invalid bookings (run one at a time; each errors, nothing is inserted)
-- CALL pr_book_appointment(99, 1, CURDATE(), TIME '11:00:00');                -- unknown patient
-- CALL pr_book_appointment(1, 99, CURDATE(), TIME '11:00:00');                -- unknown doctor
-- CALL pr_book_appointment(1, 1, CURDATE() - INTERVAL 1 DAY, TIME '11:00:00');-- past date
-- CALL pr_book_appointment(1, 1, CURDATE(), TIME '09:30:00');                 -- unsupported slot
-- CALL pr_book_appointment(3, 1, CURDATE(), TIME '09:00:00');                 -- clash with appt 1

-- (d) a cancelled slot can be rebooked:
-- CALL pr_book_appointment(3, 1, CURDATE(), TIME '10:00:00');
-- An update that moves appt 6 onto an occupied slot is rejected:
-- UPDATE appointments SET appointment_day = CURDATE() WHERE appointment_id = 6;
-- An update that leaves the slot alone is not blocked by its own row:
UPDATE appointments SET slot_time = slot_time WHERE appointment_id = 3;

-- (e)
SELECT * FROM v_today_appointments ORDER BY slot_time;

-- (f)
ANALYZE TABLE appointments;
EXPLAIN
SELECT appointment_id, slot_time, status
  FROM appointments
 WHERE appointment_day = CURDATE()
   AND doctor_id = 1;

-- (g) rerun: the date's row is replaced, never duplicated
--     today: booked 2, attended 1, cancelled 1;  tomorrow: booked 2
CALL pr_refresh_clinic_summary(CURDATE());
CALL pr_refresh_clinic_summary(CURDATE());
CALL pr_refresh_clinic_summary(CURDATE() + INTERVAL 1 DAY);
SELECT * FROM clinic_summary ORDER BY summary_date;

-- Scheduled job: every day at 01:00 for the previous day
SET GLOBAL event_scheduler = ON;

CREATE EVENT ev_refresh_clinic_summary_daily
ON SCHEDULE EVERY 1 DAY
STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 DAY + INTERVAL 1 HOUR)
DO CALL pr_refresh_clinic_summary(CURRENT_DATE - INTERVAL 1 DAY);

SHOW EVENTS FROM clinic_db;