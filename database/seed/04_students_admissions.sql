-- =============================================================================
-- GSOL ERP demo seed 04 — applicants, admissions workflow, students, documents
-- 176 enrolled students across four programmes and four intakes (2023-2026),
-- 45 applicants in the pipeline for the January 2027 intake, 6 Diploma graduates
-- progressing into the Bachelor programme, and a handful of credit transfers.
-- All names/contacts are synthetic (example.org addresses).
-- =============================================================================

-- per-student-programme plan used by later seed steps (dropped in 99_finish.sql)
CREATE TABLE zz_seed_plan (
    sp_id          bigint PRIMARY KEY,
    student_id     bigint NOT NULL,
    student_no     text NOT NULL,
    programme_code text NOT NULL,
    start_seq      int NOT NULL,
    d_terms        int NOT NULL,
    outcome        text NOT NULL,        -- active | withdrawn | on_leave | deferred | suspended | completed_progressed
    stop_after_seq int,                  -- last global term the student enrols in (NULL = continues)
    eng            int NOT NULL,         -- 0..99 engagement trait (low = disengaged)
    pay            int NOT NULL,         -- 0..99 payment trait (high = poor payer)
    diss_done      boolean NOT NULL,
    is_first_stint boolean NOT NULL DEFAULT true
);

CREATE FUNCTION seed_new_person(p_g int, p_prog text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    fnames text[] := ARRAY['Anita|F','Rajan|M','Daniel|M','Priya|F','Joel|M','Ruth|F','Samuel|M','Esther|F','Vinod|M','Mercy|F',
        'Jonathan|M','Sarah|F','David|M','Lalnunmawia|M','Zonunsangi|F','Khrielie|M','Neisetuo|F','Imtiwapang|M','Wanbiang|M','Daphisha|F',
        'Biswajit|M','Sunita|F','Arun|M','Kavitha|F','Prakash|M','Lydia|F','Isaac|M','Rebecca|F','Philip|M','Jessica|F',
        'Thomas|M','Deborah|F','Moses|M','Naomi|F','Abel|M','Hannah|F','Stephen|M','Grace|F','Peter|M','Miriam|F'];
    lnames text[] := ARRAY['Mathew','Thomas','Kharkongor','Abraham','Immanuel','Hmar','Koshy','Paul','Lalrinpuii','Rao',
        'Sangma','David','Varghese','Chandy','Sekhar','Reddy','Naidu','Lyngdoh','Marak','Sema',
        'Ao','Angami','Zeliang','Khiangte','Ralte','Singh','Das','Mondal','Soren','Pereira'];
    states text[] := ARRAY['Karnataka','Tamil Nadu','Kerala','Andhra Pradesh','Telangana','Nagaland','Mizoram','Meghalaya',
        'Manipur','Assam','Maharashtra','Odisha','Punjab','West Bengal','Jharkhand','Uttar Pradesh'];
    cities text[] := ARRAY['Bengaluru','Chennai','Kottayam','Vijayawada','Hyderabad','Kohima','Aizawl','Shillong',
        'Imphal','Guwahati','Pune','Bhubaneswar','Jalandhar','Kolkata','Ranchi','Lucknow'];
    intl_country text[] := ARRAY['Nepal','Sri Lanka','Myanmar','Bangladesh','Kenya','Nigeria'];
    intl_city    text[] := ARRAY['Kathmandu','Colombo','Yangon','Dhaka','Nairobi','Lagos'];
    intl_prefix  text[] := ARRAY['+977','+94','+95','+880','+254','+234'];
    denoms text[] := ARRAY['Assemblies of God','Assemblies of God','Assemblies of God','Baptist','Pentecostal (independent)',
        'Methodist','Church of South India','Independent evangelical'];
    cprefix text[] := ARRAY['Grace','Bethel','Zion','Emmanuel','Calvary','Living Word','New Life','Salem'];
    roles text[] := ARRAY['Pastor','Associate pastor','Youth leader','Sunday school teacher','Evangelist','Church planter',
        'Worship leader','Missionary','Chaplain','Lay leader'];
    k text := 'P' || p_g;
    nf int := array_length(fnames, 1); nl int := array_length(lnames, 1);
    fe text; f text; gnd text; l text; uid bigint; pid bigint;
    intl boolean; ix int; country text; state text; city text; phone text; age int; ordi text; den text;
    pastor_f text; pastor_l text; yrs numeric; prevq text; previn text; startyr int; role_ text;
BEGIN
    fe  := fnames[1 + (p_g * 7) % nf];
    f   := split_part(fe, '|', 1);  gnd := CASE split_part(fe, '|', 2) WHEN 'F' THEN 'female' ELSE 'male' END;
    l   := lnames[1 + (p_g * 11 + p_g / nf) % nl];
    intl := seed_rand(k || 'r', 100) >= 87;
    IF intl THEN
        ix := 1 + seed_rand(k || 'i', 6);
        country := intl_country[ix]; state := NULL; city := intl_city[ix];
        phone := intl_prefix[ix] || ' ' || lpad(seed_rand(k || 'p', 1000000000)::text, 9, '0');
    ELSE
        ix := CASE WHEN seed_rand(k || 'w', 100) < 55 THEN 1 + seed_rand(k || 's', 9) ELSE 1 + seed_rand(k || 's2', 16) END;
        country := 'India'; state := states[ix]; city := cities[ix];
        phone := '+91 9' || lpad(seed_rand(k || 'p', 100000)::text, 5, '0') || ' ' || lpad(seed_rand(k || 'q', 100000)::text, 5, '0');
    END IF;
    age := CASE p_prog WHEN 'DIP-TH' THEN 22 + seed_rand(k || 'a', 28) WHEN 'BTH' THEN 22 + seed_rand(k || 'a', 23)
                       WHEN 'MACS' THEN 26 + seed_rand(k || 'a', 24) ELSE 25 + seed_rand(k || 'a', 27) END;
    den := denoms[1 + seed_rand(k || 'd', array_length(denoms, 1))];
    ordi := CASE WHEN p_prog IN ('MACS','MDIV') AND seed_rand(k || 'o', 100) < 45 THEN 'ordained'
                 WHEN seed_rand(k || 'o', 100) < 30 THEN 'licensed' ELSE 'none' END;
    yrs := CASE p_prog WHEN 'DIP-TH' THEN 1 + seed_rand(k || 'y', 10) WHEN 'BTH' THEN 1 + seed_rand(k || 'y', 12)
                       ELSE 3 + seed_rand(k || 'y', 22) END;
    pastor_f := split_part(fnames[1 + (p_g * 13 + 5) % nf], '|', 1);
    pastor_l := lnames[1 + (p_g * 17 + 3) % nl];
    role_ := roles[1 + seed_rand(k || 'm', array_length(roles, 1))];
    prevq := CASE p_prog WHEN 'DIP-TH' THEN 'Higher Secondary Certificate'
                         WHEN 'BTH' THEN CASE WHEN seed_rand(k || 'q', 2) = 0 THEN 'Higher Secondary Certificate' ELSE 'Diploma in Theology' END
                         ELSE (ARRAY['B.A.','B.Sc.','B.Com.','B.Th.'])[1 + seed_rand(k || 'q', 4)] END;
    previn := CASE WHEN p_prog IN ('DIP-TH','BTH') THEN 'Demo Higher Secondary School, ' || city
              ELSE 'Demo College, ' || city END;
    startyr := 2022 + seed_rand(k || 'z', 4);

    INSERT INTO users (email, password_hash, full_name)
    VALUES (lower(f) || '.' || lower(l) || p_g || '@example.org', '$argon2id$v=19$m=65536,t=3,p=4$DEMO$not-a-real-hash', f || ' ' || l)
    RETURNING id INTO uid;
    INSERT INTO user_roles (user_id, role_id) SELECT uid, id FROM roles WHERE code = 'applicant';

    INSERT INTO persons (user_id, first_name, last_name, preferred_name, gender, date_of_birth, nationality, photo_key,
                         government_id_type, government_id_last4, address_line, city, state, country, postal_code,
                         email, mobile, whatsapp, emergency_contact_name, emergency_contact_phone, emergency_contact_relationship,
                         church_name, denomination, pastor_name, church_location, ministry_role, ministry_experience_years,
                         ordination_status, ministry_organization, ministry_address,
                         previous_institution, previous_qualification, previous_year_completed)
    VALUES (uid, f, l, CASE WHEN seed_rand(k || 'n', 5) = 0 THEN f || 'ie' END, gnd,
            DATE '2026-01-01' - (age * 365 + seed_rand(k || 'b', 365)), CASE WHEN intl THEN country ELSE 'Indian' END,
            'vault/photos/' || p_g || '.jpg', CASE WHEN intl THEN 'Passport' ELSE 'Aadhaar' END, lpad(seed_rand(k || 'g', 10000)::text, 4, '0'),
            (1 + seed_rand(k || 'h', 120)) || ', Demo Street', city, state, country,
            CASE WHEN intl THEN NULL ELSE lpad((500000 + seed_rand(k || 'c', 99999))::text, 6, '0') END,
            lower(f) || '.' || lower(l) || p_g || '@example.org', phone, phone,
            pastor_f || ' ' || l, phone, CASE WHEN seed_rand(k || 'e', 2) = 0 THEN 'spouse' ELSE 'parent' END,
            cprefix[1 + seed_rand(k || 'f', 8)] || CASE WHEN den = 'Assemblies of God' THEN ' Assembly of God' ELSE ' Church' END || ', ' || city,
            den, 'Pr. ' || pastor_f || ' ' || pastor_l, city, role_, yrs, ordi,
            CASE WHEN seed_rand(k || 'u', 3) = 0 THEN 'Demo Mission Society' END, CASE WHEN seed_rand(k || 'u', 3) = 0 THEN city END,
            previn, prevq, startyr)
    RETURNING id INTO pid;
    RETURN pid;
END $$;

-- ------------------------------------------------------------ enrolled students
DO $$
DECLARE
    c record; t record; pr record; g int := 0; i int; pid bigint; uid bigint; app bigint; sid bigint; spid bigint;
    adm_user bigint; reg_user bigint; adv bigint; no text; cat text; r int; outcome text; stop int; d int;
    advisors bigint[] := ARRAY(SELECT id FROM faculty WHERE faculty_no IN
        ('FAC-0002','FAC-0004','FAC-0006','FAC-0007','FAC-0009','FAC-0010') ORDER BY faculty_no);
    sub timestamptz; kk text; country text;
BEGIN
    SELECT id INTO adm_user FROM users WHERE email = 'admissions@gsol.example.org';
    SELECT id INTO reg_user FROM users WHERE email = 'registrar@gsol.example.org';

    FOR c IN SELECT * FROM (VALUES
        ('DIP-TH',1,14),('BTH',1,10),('MACS',1,6),('MDIV',1,8),
        ('DIP-TH',3,14),('BTH',3,10),('MACS',3,8),('MDIV',3,8),
        ('DIP-TH',5,16),('BTH',5,12),('MACS',5,8),('MDIV',5,10),
        ('DIP-TH',7,18),('BTH',7,12),('MACS',7,10),('MDIV',7,12)) AS v(prog, s, n)
        ORDER BY s, prog
    LOOP
        SELECT * INTO t  FROM terms WHERE seq = c.s;
        SELECT * INTO pr FROM programmes WHERE code = c.prog;
        d := CEIL(pr.duration_months / 6.0)::int;
        FOR i IN 1..c.n LOOP
            g := g + 1; kk := 'P' || g;
            pid := seed_new_person(g, c.prog);
            SELECT p.user_id, p.country INTO uid, country FROM persons p WHERE p.id = pid;
            cat := CASE WHEN country <> 'India' THEN 'international'
                        WHEN seed_rand(kk || 'cat', 100) < 8 THEN 'sponsored'
                        WHEN seed_rand(kk || 'cat', 100) < 14 THEN 'scholarship' ELSE 'regular' END;
            sub := (t.start_date - (35 + seed_rand(kk || 'sub', 60)))::timestamptz;

            INSERT INTO applications (application_no, person_id, programme_id, intake_term_id, admission_category, status,
                                      personal_statement, submitted_at)
            VALUES (fn_next_number('APP', EXTRACT(year FROM t.start_date)::int, 4), pid, pr.id, t.id, cat, 'draft',
                    'Demo personal statement describing calling and ministry goals.', sub)
            RETURNING id INTO app;
            UPDATE applications SET status = 'submitted' WHERE id = app;
            UPDATE applications SET status = 'under_review', reviewed_by = adm_user WHERE id = app;
            UPDATE applications SET status = 'academic_review' WHERE id = app;
            IF c.prog IN ('MACS','MDIV') THEN UPDATE applications SET status = 'interview' WHERE id = app; END IF;
            UPDATE applications SET status = 'admitted', decided_by = reg_user, decided_at = sub + interval '14 days',
                   decision_notes = 'Admitted (demo)', admission_letter_key = 'vault/letters/' || app || '.pdf' WHERE id = app;
            UPDATE applications SET status = 'accepted', accepted_at = sub + interval '18 days' WHERE id = app;

            adv := advisors[1 + (g % array_length(advisors, 1))];
            sid := fn_admit_student(app, adv);
            SELECT sp.id INTO spid FROM student_programmes sp WHERE sp.student_id = sid;
            SELECT s.student_no INTO no FROM students s WHERE s.id = sid;

            DELETE FROM user_roles WHERE user_id = uid AND role_id = (SELECT id FROM roles WHERE code = 'applicant');
            INSERT INTO user_roles (user_id, role_id) SELECT uid, id FROM roles WHERE code = 'student';

            -- outcome (who withdraws, pauses, continues)
            r := seed_rand(no || 'o', 100);
            outcome := 'active'; stop := NULL;
            IF r < 6 AND c.s < 7 THEN outcome := 'withdrawn'; stop := LEAST(c.s + seed_rand(no || 'w', 2), 6);
            ELSIF r BETWEEN 6 AND 7  AND (8 - c.s) <= d THEN outcome := 'on_leave';  stop := 6;
            ELSIF r BETWEEN 8 AND 9  AND (8 - c.s) <= d THEN outcome := 'deferred';  stop := 6;
            ELSIF r = 10             AND (8 - c.s) <= d AND c.s < 7 THEN outcome := 'suspended'; stop := 6;
            END IF;

            INSERT INTO zz_seed_plan (sp_id, student_id, student_no, programme_code, start_seq, d_terms, outcome, stop_after_seq,
                                      eng, pay, diss_done)
            VALUES (spid, sid, no, c.prog, c.s, d, outcome, stop, seed_rand(no || 'e', 100), seed_rand(no || 'pay', 100),
                    seed_rand(no || 'd', 100) < 78);
        END LOOP;
    END LOOP;
END $$;

-- lifecycle: enrolled -> active, then the legal exceptional transitions
UPDATE students SET status_code = 'active' WHERE status_code = 'enrolled';

SELECT set_config('gsol.status_reason', 'Student withdrew from programme (demo)', false);
UPDATE students s SET status_code = 'withdrawn' FROM zz_seed_plan p WHERE p.student_id = s.id AND p.outcome = 'withdrawn';
SELECT set_config('gsol.status_reason', 'Approved leave of absence (demo)', false);
UPDATE students s SET status_code = 'on_leave' FROM zz_seed_plan p WHERE p.student_id = s.id AND p.outcome = 'on_leave';
SELECT set_config('gsol.status_reason', 'Deferral approved (demo)', false);
UPDATE students s SET status_code = 'deferred' FROM zz_seed_plan p WHERE p.student_id = s.id AND p.outcome = 'deferred';
SELECT set_config('gsol.status_reason', 'Suspended pending review (demo)', false);
UPDATE students s SET status_code = 'suspended' FROM zz_seed_plan p WHERE p.student_id = s.id AND p.outcome = 'suspended';
SELECT set_config('gsol.status_reason', '', false);

UPDATE student_programmes sp SET status = p.outcome,
       completed_on = CASE WHEN p.outcome = 'withdrawn'
            THEN (SELECT end_date FROM terms WHERE seq = p.stop_after_seq) END
FROM zz_seed_plan p WHERE p.sp_id = sp.id AND p.outcome IN ('withdrawn','on_leave','deferred','suspended');

-- --------------------------------------------- progression: Diploma -> Bachelor
-- Six Diploma (2023 cohort) students continue into the Bachelor programme from Term 5.
-- Same persons / same student_no — a second student_programmes row and recognised credit.
CREATE TABLE zz_progressors AS
SELECT p.student_id, p.sp_id AS dip_sp, p.student_no, p.eng, p.pay,
       row_number() OVER (ORDER BY p.student_no) AS rn
FROM zz_seed_plan p
WHERE p.programme_code = 'DIP-TH' AND p.start_seq = 1 AND p.outcome = 'active'
  AND p.pay < 70
  AND (45 + 0.75 * (seed_rand(p.student_no || 'a', 31) + seed_rand(p.student_no || 'b', 31))) >= 62;
DELETE FROM zz_progressors WHERE rn > 6;

UPDATE student_programmes sp SET status = 'completed', completed_on = DATE '2025-06-30'
FROM zz_progressors z WHERE z.dip_sp = sp.id;
UPDATE zz_seed_plan p SET outcome = 'completed_progressed' FROM zz_progressors z WHERE z.dip_sp = p.sp_id;

INSERT INTO student_programmes (student_id, programme_id, curriculum_id, start_term_id, admission_category, status,
                                admitted_on, expected_graduation_on)
SELECT z.student_id, pr.id, cu.id, t.id, 'regular', 'active', t.start_date,
       (t.start_date + (pr.duration_months || ' months')::interval)::date
FROM zz_progressors z
JOIN programmes pr ON pr.code = 'BTH'
JOIN curricula cu ON cu.programme_id = pr.id AND cu.status = 'active'
JOIN terms t ON t.seq = 5;

INSERT INTO zz_seed_plan (sp_id, student_id, student_no, programme_code, start_seq, d_terms, outcome, stop_after_seq,
                          eng, pay, diss_done, is_first_stint)
SELECT sp.id, z.student_id, z.student_no, 'BTH', 5, 6, 'active', NULL, z.eng, z.pay, true, false
FROM zz_progressors z
JOIN student_programmes sp ON sp.student_id = z.student_id AND sp.status = 'active';

-- recognised GSOL Diploma credit for the Bachelor stint (reported separately from earned credit)
INSERT INTO credit_transfers (student_programme_id, student_id, previous_institution, previous_course_title, credits_claimed,
                              previous_grade, equivalent_course_id, status, credits_approved, decided_by, decided_at)
SELECT p.sp_id, p.student_id, 'GSOL — Diploma in Theology', c.title, c.credits, 'B+', c.id, 'approved', c.credits,
       (SELECT id FROM users WHERE email = 'registrar@gsol.example.org'), TIMESTAMPTZ '2025-06-20 10:00+05:30'
FROM zz_seed_plan p JOIN zz_progressors z ON z.student_id = p.student_id AND p.is_first_stint = false
JOIN courses c ON c.code IN ('OT101','TH101','CH101','HM201');

-- a few external transfer requests with mixed decisions
INSERT INTO credit_transfers (student_programme_id, student_id, previous_institution, previous_course_title, credits_claimed,
                              previous_grade, equivalent_course_id, status, credits_approved, decided_by, decided_at)
SELECT p.sp_id, p.student_id, 'Faith Bible Institute (demo)',
       CASE p.programme_code WHEN 'BTH' THEN 'Survey of the Old Testament' ELSE 'Old Testament Theology' END,
       3, 'B',
       (SELECT id FROM courses WHERE code = CASE p.programme_code WHEN 'BTH' THEN 'OT101' ELSE 'OT501' END),
       x.st, CASE x.st WHEN 'approved' THEN 3 WHEN 'partial' THEN 1.5 ELSE 0 END,
       CASE WHEN x.st IN ('approved','partial','rejected') THEN (SELECT id FROM users WHERE email = 'registrar@gsol.example.org') END,
       CASE WHEN x.st IN ('approved','partial','rejected') THEN TIMESTAMPTZ '2025-06-25 10:00+05:30' END
FROM (SELECT p.*, row_number() OVER (ORDER BY p.student_no) AS rn
      FROM zz_seed_plan p
      WHERE p.programme_code IN ('BTH','MDIV') AND p.start_seq IN (3,5,7) AND p.outcome = 'active' AND p.is_first_stint) p
JOIN (VALUES (1,'approved'),(2,'approved'),(3,'partial'),(4,'pending'),(5,'rejected'),(6,'approved')) AS x(rn, st) ON x.rn = p.rn;
UPDATE applications a SET admission_category = 'transfer'
FROM credit_transfers t JOIN students s ON s.id = t.student_id
WHERE a.id = s.application_id AND t.previous_institution LIKE 'Faith Bible%';

-- ------------------------------------------------------------------- documents
INSERT INTO documents (person_id, application_id, student_id, category, doc_type, storage_key, uploaded_by, uploaded_at,
                       verification_status, verified_by, verified_at)
SELECT s.person_id, s.application_id, s.id, d.cat, d.typ, 'vault/' || s.student_no || '/' || d.typ || '.pdf',
       p.user_id, a.submitted_at - interval '3 days', 'verified',
       (SELECT id FROM users WHERE email = 'admissions@gsol.example.org'), a.submitted_at + interval '6 days'
FROM students s
JOIN applications a ON a.id = s.application_id
JOIN persons p ON p.id = s.person_id
CROSS JOIN (VALUES ('identity','passport_photo'), ('identity','government_id'), ('academic','academic_certificate'),
                   ('ministry','church_recommendation'), ('admission','personal_statement')) AS d(cat, typ);

INSERT INTO documents (person_id, application_id, student_id, category, doc_type, storage_key, uploaded_by, uploaded_at,
                       verification_status, verified_by, verified_at)
SELECT s.person_id, s.application_id, s.id, 'ministry', 'ministry_experience_letter', 'vault/' || s.student_no || '/ministry_experience.pdf',
       p.user_id, a.submitted_at - interval '2 days', 'verified',
       (SELECT id FROM users WHERE email = 'admissions@gsol.example.org'), a.submitted_at + interval '7 days'
FROM students s JOIN applications a ON a.id = s.application_id JOIN persons p ON p.id = s.person_id
WHERE seed_rand(s.student_no || 'mx', 100) < 60;

INSERT INTO documents (person_id, application_id, student_id, category, doc_type, storage_key, uploaded_by, uploaded_at,
                       verification_status, verified_by, verified_at)
SELECT s.person_id, s.application_id, s.id, 'academic', 'transcript', 'vault/' || s.student_no || '/transcript_prior.pdf',
       p.user_id, a.submitted_at - interval '2 days', 'verified',
       (SELECT id FROM users WHERE email = 'admissions@gsol.example.org'), a.submitted_at + interval '7 days'
FROM students s JOIN applications a ON a.id = s.application_id JOIN persons p ON p.id = s.person_id
JOIN student_programmes sp ON sp.student_id = s.id JOIN programmes pr ON pr.id = sp.programme_id
WHERE pr.level IN ('bachelor','master','professional_master');

-- --------------------------------------------- applicant pipeline (Jan 2027 intake)
DO $$
DECLARE
    i int; g int; pid bigint; app bigint; prog_code text; pr record; t record; target text; sub timestamptz;
    adm_user bigint; reg_user bigint; path text[] := ARRAY['submitted','under_review','academic_review','interview'];
    s text; k text;
BEGIN
    SELECT id INTO adm_user FROM users WHERE email = 'admissions@gsol.example.org';
    SELECT id INTO reg_user FROM users WHERE email = 'registrar@gsol.example.org';
    SELECT * INTO t FROM terms WHERE seq = 8;
    FOR i IN 1..45 LOOP
        g := 176 + i; k := 'P' || g;
        prog_code := CASE WHEN seed_rand(k || 'pg', 100) < 35 THEN 'DIP-TH' WHEN seed_rand(k || 'pg', 100) < 60 THEN 'BTH'
                          WHEN seed_rand(k || 'pg', 100) < 78 THEN 'MACS' ELSE 'MDIV' END;
        SELECT * INTO pr FROM programmes WHERE code = prog_code;
        target := CASE WHEN i <= 6 THEN 'draft' WHEN i <= 16 THEN 'submitted' WHEN i <= 24 THEN 'under_review'
                       WHEN i <= 30 THEN 'academic_review' WHEN i <= 34 THEN 'interview' WHEN i <= 39 THEN 'admitted'
                       WHEN i <= 41 THEN 'waitlisted' WHEN i <= 43 THEN 'rejected' ELSE 'accepted' END;
        sub := CASE WHEN target = 'draft' THEN NULL ELSE (DATE '2026-08-20' + (i % 40))::timestamptz END;
        pid := seed_new_person(g, prog_code);
        INSERT INTO applications (application_no, person_id, programme_id, intake_term_id, admission_category, status,
                                  personal_statement, submitted_at)
        VALUES (fn_next_number('APP', 2026, 4), pid, pr.id, t.id,
                CASE WHEN seed_rand(k || 'cat', 100) < 10 THEN 'scholarship' ELSE 'regular' END, 'draft',
                'Demo personal statement.', sub)
        RETURNING id INTO app;
        IF target <> 'draft' THEN
            FOREACH s IN ARRAY path LOOP
                UPDATE applications SET status = s, reviewed_by = CASE WHEN s = 'under_review' THEN adm_user ELSE reviewed_by END WHERE id = app;
                EXIT WHEN s = target;
            END LOOP;
            IF target IN ('admitted','waitlisted','rejected','accepted') THEN
                UPDATE applications SET status = CASE target WHEN 'accepted' THEN 'admitted' ELSE target END,
                       decided_by = reg_user, decided_at = sub + interval '20 days', decision_notes = 'Decision recorded (demo)' WHERE id = app;
                IF target = 'accepted' THEN
                    UPDATE applications SET status = 'accepted', accepted_at = sub + interval '28 days' WHERE id = app;
                END IF;
            END IF;
        END IF;
        INSERT INTO documents (person_id, application_id, category, doc_type, storage_key, uploaded_by, uploaded_at, verification_status, verified_by, verified_at)
        SELECT pid, app, d.cat, d.typ, 'vault/applicants/' || app || '/' || d.typ || '.pdf', (SELECT user_id FROM persons WHERE id = pid),
               COALESCE(sub, TIMESTAMPTZ '2026-09-25 10:00+05:30') - interval '1 day',
               CASE WHEN target IN ('draft','submitted') THEN 'pending' ELSE 'verified' END,
               CASE WHEN target IN ('draft','submitted') THEN NULL ELSE adm_user END,
               CASE WHEN target IN ('draft','submitted') THEN NULL ELSE sub + interval '5 days' END
        FROM (VALUES ('identity','passport_photo'), ('identity','government_id'), ('academic','academic_certificate'),
                     ('ministry','church_recommendation')) AS d(cat, typ)
        WHERE target <> 'draft' OR d.typ = 'passport_photo';
    END LOOP;
END $$;

-- Realistic timestamps on the application workflow history (trigger stamps now() at load time)
UPDATE application_status_history h SET changed_at = CASE h.to_status
    WHEN 'draft'           THEN COALESCE(a.submitted_at, TIMESTAMPTZ '2026-09-20 10:00+05:30') - interval '4 days'
    WHEN 'submitted'       THEN a.submitted_at
    WHEN 'under_review'    THEN a.submitted_at + interval '3 days'
    WHEN 'academic_review' THEN a.submitted_at + interval '8 days'
    WHEN 'interview'       THEN a.submitted_at + interval '11 days'
    WHEN 'admitted'        THEN a.decided_at WHEN 'waitlisted' THEN a.decided_at WHEN 'rejected' THEN a.decided_at
    WHEN 'accepted'        THEN a.accepted_at
    WHEN 'enrolled'        THEN (SELECT t.start_date FROM terms t WHERE t.id = a.intake_term_id)::timestamptz - interval '5 days'
    ELSE h.changed_at END
FROM applications a WHERE a.id = h.application_id;

-- placeholder history reasons for admin-driven transitions inserted at load time
UPDATE student_status_history h SET changed_at = s.admitted_on::timestamptz + interval '2 days'
FROM students s WHERE s.id = h.student_id AND h.to_code = 'active' AND h.from_code = 'enrolled';
