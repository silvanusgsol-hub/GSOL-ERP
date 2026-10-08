-- =============================================================================
-- GSOL ERP demo seed 05 — course offerings, enrolments, assessments, scores, grades
-- Terms are processed in order (2023-24 T1 .. 2026-27 T1) so the registration guard
-- (prerequisites, capacity) genuinely applies; finished terms are finalised through
-- fn_finalize_enrollment, the current term (Term 7, in progress) keeps running percentages.
-- =============================================================================

-- Pin "today" for the demo so views (engagement risk, overdue fees, ...) are reproducible
DO $$ BEGIN EXECUTE format('ALTER DATABASE %I SET gsol.as_of_date = %L', current_database(), '2026-10-07'); END $$;
SELECT set_config('gsol.as_of_date', '2026-10-07', false);

-- Offerings: every course in every elapsed/current term (unused ones are pruned at the end)
INSERT INTO course_offerings (course_id, term_id, coordinator_id, capacity, lms_course_id, status)
SELECT c.id, t.id, 1 + (c.id * 5) % 12, 120, 'MDL-' || c.code || '-T' || t.seq,
       CASE WHEN t.seq < 7 THEN 'completed' ELSE 'open' END
FROM courses c CROSS JOIN terms t WHERE t.seq <= 7;

DO $$
DECLARE s int; asof date := fn_as_of();
BEGIN
FOR s IN 1..7 LOOP
    -- 1. Registration (guard trigger enforces prerequisites + capacity; we pre-filter so none are rejected)
    INSERT INTO enrollments (student_id, student_programme_id, offering_id, status, registered_at)
    SELECT p.student_id, p.sp_id, o.id, 'registered',
           (t.registration_deadline - 10 + seed_rand(p.student_no || 'rg' || s, 9))::timestamptz + interval '10 hours'
    FROM zz_seed_plan p
    JOIN student_programmes sp ON sp.id = p.sp_id
    JOIN curriculum_courses cc ON cc.curriculum_id = sp.curriculum_id AND cc.term_seq = s - p.start_seq + 1
    JOIN terms t ON t.seq = s
    JOIN course_offerings o ON o.course_id = cc.course_id AND o.term_id = t.id
    WHERE p.start_seq <= s AND s <= COALESCE(p.stop_after_seq, 99)
      AND fn_prereqs_met(p.student_id, cc.course_id)
      AND NOT EXISTS (SELECT 1 FROM enrollments e2 JOIN course_offerings o2 ON o2.id = e2.offering_id
                      WHERE e2.student_id = p.student_id AND o2.course_id = cc.course_id AND e2.status = 'completed')
      AND NOT EXISTS (SELECT 1 FROM credit_transfers ct
                      WHERE ct.student_programme_id = p.sp_id AND ct.equivalent_course_id = cc.course_id
                        AND ct.status IN ('approved','partial'));

    -- 2. Assessment structure per offering (configurable weights: 20/10/10/20/40)
    INSERT INTO assessments (offering_id, title, assessment_type, weight_pct, max_marks, opens_at, due_at, allow_resubmission, created_by)
    SELECT o.id,
           CASE v.n WHEN 1 THEN CASE WHEN c.code IN ('EX301','EX501') THEN 'Exegetical Paper'
                                     WHEN c.code = 'HM201' THEN 'Book Review'
                                     WHEN c.code = 'OT202' THEN 'Narrative Analysis Essay'
                                     WHEN c.code = 'RM501' THEN 'Research Proposal'
                                     ELSE 'Assignment 1' END
                    WHEN 2 THEN 'Unit Quiz' WHEN 3 THEN 'Discussion Forum'
                    WHEN 4 THEN 'Midterm Examination' ELSE 'Final Examination' END,
           CASE v.n WHEN 1 THEN CASE WHEN c.code IN ('EX301','EX501') THEN 'biblical_exegesis'
                                     WHEN c.code = 'HM201' THEN 'book_review'
                                     WHEN c.code = 'OT202' THEN 'essay'
                                     WHEN c.code = 'RM501' THEN 'research_paper'
                                     ELSE 'assignment' END
                    WHEN 2 THEN 'quiz' WHEN 3 THEN 'discussion_forum' ELSE 'examination' END,
           v.w, v.mx, (t.start_date + v.open_d)::timestamptz, (t.start_date + v.due_d)::timestamptz + interval '23 hours 59 minutes',
           (v.n = 1), o.coordinator_id
    FROM course_offerings o
    JOIN courses c ON c.id = o.course_id
    JOIN terms t ON t.id = o.term_id
    CROSS JOIN (VALUES (1, 20, 100, 0, 50), (2, 10, 20, 0, 70), (3, 10, 10, 0, 60),
                       (4, 20, 100, 75, 90), (5, 40, 100, 140, 165)) AS v(n, w, mx, open_d, due_d)
    WHERE t.seq = s AND c.code NOT IN ('DIS599', 'MIN301')
      AND EXISTS (SELECT 1 FROM enrollments e WHERE e.offering_id = o.id)
      AND NOT EXISTS (SELECT 1 FROM assessments a WHERE a.offering_id = o.id);

    INSERT INTO assessments (offering_id, title, assessment_type, weight_pct, max_marks, opens_at, due_at, allow_resubmission, created_by)
    SELECT o.id, v.title, v.typ, v.w, 100, (t.start_date + v.open_d)::timestamptz,
           (t.start_date + v.due_d)::timestamptz + interval '23 hours 59 minutes', false, o.coordinator_id
    FROM course_offerings o
    JOIN courses c ON c.id = o.course_id AND c.code = 'MIN301'
    JOIN terms t ON t.id = o.term_id
    CROSS JOIN (VALUES ('Ministry Project Report', 'ministry_project', 50, 0, 120),
                       ('Supervised Ministry Placement', 'internship', 50, 0, 150)) AS v(title, typ, w, open_d, due_d)
    WHERE t.seq = s AND EXISTS (SELECT 1 FROM enrollments e WHERE e.offering_id = o.id)
      AND NOT EXISTS (SELECT 1 FROM assessments a WHERE a.offering_id = o.id);

    INSERT INTO assessments (offering_id, title, assessment_type, weight_pct, max_marks, opens_at, due_at, allow_resubmission, created_by)
    SELECT o.id, 'Dissertation', 'dissertation', 100, 100, t.start_date::timestamptz,
           (t.start_date + 160)::timestamptz + interval '23 hours 59 minutes', true, o.coordinator_id
    FROM course_offerings o
    JOIN courses c ON c.id = o.course_id AND c.code = 'DIS599'
    JOIN terms t ON t.id = o.term_id
    WHERE t.seq = s AND EXISTS (SELECT 1 FROM enrollments e WHERE e.offering_id = o.id)
      AND NOT EXISTS (SELECT 1 FROM assessments a WHERE a.offering_id = o.id);

    -- 3. Scores. Ability = engagement trait + per-course + per-assessment noise.
    INSERT INTO assessment_scores (assessment_id, enrollment_id, marks, feedback, source, graded_by, graded_at)
    SELECT a.id, e.id, ROUND(m.pct / 100 * a.max_marks, 1),
           CASE WHEN a.assessment_type NOT IN ('quiz','discussion_forum','examination') THEN
                CASE WHEN m.pct >= 80 THEN 'Excellent engagement with the text and sources.'
                     WHEN m.pct >= 65 THEN 'Sound work; develop the theological argument further.'
                     ELSE 'Needs stronger use of primary sources and clearer structure.' END END,
           CASE WHEN a.assessment_type IN ('quiz','discussion_forum') THEN 'lms'
                WHEN a.assessment_type = 'examination' THEN 'exam' ELSE 'manual' END,
           o.coordinator_id, a.due_at + interval '8 days'
    FROM enrollments e
    JOIN course_offerings o ON o.id = e.offering_id
    JOIN terms t ON t.id = o.term_id AND t.seq = s
    JOIN courses c ON c.id = o.course_id
    JOIN assessments a ON a.offering_id = o.id
    JOIN zz_seed_plan p ON p.sp_id = e.student_programme_id
    CROSS JOIN LATERAL (SELECT LEAST(98, GREATEST(30,
            55 + 0.26 * p.eng + seed_rand(p.student_no || c.code, 17) - 8
               + seed_rand(p.student_no || c.code || a.title, 13) - 6))::numeric AS pct) m
    WHERE e.status = 'registered'
      AND (CASE
             -- withdrawn students stop part-way through their last term
             WHEN p.outcome = 'withdrawn' AND s = p.stop_after_seq THEN a.assessment_type IN ('assignment','quiz','essay','book_review','biblical_exegesis','research_paper')
             -- current term: only what is already due, and disengaged students miss some work
             WHEN s = 7 THEN a.due_at <= asof::timestamptz
                             AND NOT (p.eng < 30 AND a.assessment_type <> 'examination' AND seed_rand(p.student_no || a.title || 'ms', 100) < 45)
                             AND a.assessment_type <> 'dissertation'
             -- dissertation delayed for students who have not finished it
             WHEN a.assessment_type = 'dissertation' THEN p.diss_done
             ELSE true END);

    -- 4. Withdrawals, then finalise every finished enrolment whose assessments are all scored
    UPDATE enrollments e SET status = 'withdrawn'
    FROM course_offerings o, terms t, zz_seed_plan p
    WHERE o.id = e.offering_id AND t.id = o.term_id AND t.seq = s
      AND p.sp_id = e.student_programme_id AND p.outcome = 'withdrawn' AND p.stop_after_seq = s;

    IF s < 7 THEN
        PERFORM fn_finalize_enrollment(e.id)
        FROM enrollments e
        JOIN course_offerings o ON o.id = e.offering_id
        JOIN terms t ON t.id = o.term_id AND t.seq = s
        WHERE e.status = 'registered'
          AND (SELECT count(*) FROM assessments a WHERE a.offering_id = o.id)
            = (SELECT count(*) FROM assessment_scores sc JOIN assessments a ON a.id = sc.assessment_id
               WHERE a.offering_id = o.id AND sc.enrollment_id = e.id);
    END IF;
END LOOP;
END $$;

-- Prune offerings nobody took; schedule next term (Term 8) as planned
DELETE FROM course_offerings o WHERE NOT EXISTS (SELECT 1 FROM enrollments e WHERE e.offering_id = o.id);
INSERT INTO course_offerings (course_id, term_id, coordinator_id, capacity, lms_course_id, status)
SELECT c.id, 8, 1 + (c.id * 5) % 12, 120, 'MDL-' || c.code || '-T8', 'planned' FROM courses c;

-- Teaching teams
INSERT INTO course_faculty (offering_id, faculty_id, role)
SELECT o.id, o.coordinator_id, 'instructor' FROM course_offerings o WHERE o.status <> 'planned';
INSERT INTO course_faculty (offering_id, faculty_id, role)
SELECT o.id, 1 + (o.coordinator_id + o.term_id) % 12, CASE WHEN o.id % 3 = 0 THEN 'tutor' ELSE 'co_instructor' END
FROM course_offerings o WHERE o.status <> 'planned' AND 1 + (o.coordinator_id + o.term_id) % 12 <> o.coordinator_id;

-- Submissions for every graded written assessment (late ones more common among disengaged students)
INSERT INTO submissions (assessment_id, enrollment_id, attempt_no, submitted_at, storage_key, is_late, status)
SELECT sc.assessment_id, sc.enrollment_id, 1,
       CASE WHEN late.is_late THEN a.due_at + interval '1 day' * (1 + seed_rand(p.student_no || a.id, 4))
            ELSE a.due_at - interval '1 day' * seed_rand(p.student_no || a.id || 'e', 6) - interval '3 hours' END,
       'vault/submissions/' || sc.enrollment_id || '/' || sc.assessment_id || '.pdf',
       late.is_late, CASE WHEN o.status = 'completed' THEN 'returned' ELSE 'graded' END
FROM assessment_scores sc
JOIN assessments a ON a.id = sc.assessment_id
JOIN course_offerings o ON o.id = a.offering_id
JOIN enrollments e ON e.id = sc.enrollment_id
JOIN zz_seed_plan p ON p.sp_id = e.student_programme_id
CROSS JOIN LATERAL (SELECT seed_rand(p.student_no || a.id || 'lt', 100) < (6 + (100 - p.eng) / 6) AS is_late) late
WHERE a.assessment_type IN ('assignment','essay','research_paper','book_review','biblical_exegesis','ministry_project','dissertation');

-- Ungraded work awaiting faculty: submissions on current-term assignments that fall due soon
INSERT INTO assessments (offering_id, title, assessment_type, weight_pct, max_marks, opens_at, due_at, allow_resubmission, created_by)
SELECT o.id, 'Assignment 2', 'assignment', 5, 100, '2026-09-20'::timestamptz, '2026-10-12 23:59+05:30', false, o.coordinator_id
FROM course_offerings o JOIN courses c ON c.id = o.course_id
WHERE o.term_id = 7 AND o.status = 'open' AND c.code NOT IN ('DIS599','MIN301');
UPDATE assessments a SET weight_pct = 15
WHERE a.due_at::date = DATE '2026-08-20' AND a.weight_pct = 20
  AND EXISTS (SELECT 1 FROM assessments b WHERE b.offering_id = a.offering_id AND b.title = 'Assignment 2');
INSERT INTO submissions (assessment_id, enrollment_id, attempt_no, submitted_at, storage_key, is_late, status)
SELECT a.id, e.id, 1, ('2026-10-0' || (1 + seed_rand(e.id::text, 6)) || ' 18:30+05:30')::timestamptz, 'vault/submissions/' || e.id || '/' || a.id || '.pdf', false, 'submitted'
FROM assessments a JOIN enrollments e ON e.offering_id = a.offering_id
JOIN zz_seed_plan p ON p.sp_id = e.student_programme_id
WHERE a.title = 'Assignment 2' AND e.status = 'registered' AND seed_rand(p.student_no || a.id || 's2', 100) < (30 + p.eng / 2);

-- Academic advising notes for students needing attention
INSERT INTO advising_notes (student_id, advisor_id, advised_on, concern, recommendation, follow_up_on, action_taken)
SELECT s.id, s.advisor_id, DATE '2026-09-10' + seed_rand(s.student_no, 8),
       CASE WHEN p.eng < 25 THEN 'Low LMS activity and missed assignments this term'
            WHEN p.pay >= 80 THEN 'Fee payments behind schedule'
            ELSE 'Balancing ministry load with coursework' END,
       CASE WHEN p.eng < 25 THEN 'Agree a weekly study plan; check in by phone'
            WHEN p.pay >= 80 THEN 'Refer to Finance Officer for an instalment plan'
            ELSE 'Reduce to a lighter course load next term' END,
       DATE '2026-10-20', 'Discussed by phone; student committed to follow-up'
FROM students s JOIN zz_seed_plan p ON p.sp_id = (SELECT max(sp_id) FROM zz_seed_plan z WHERE z.student_id = s.id)
WHERE s.status_code = 'active' AND s.advisor_id IS NOT NULL AND (p.eng < 25 OR p.pay >= 80 OR seed_rand(s.student_no || 'adv', 100) < 8);
