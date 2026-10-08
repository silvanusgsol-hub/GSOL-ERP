-- =============================================================================
-- GSOL ERP demo seed 07 — examinations, Moodle/ODL engagement, research, ministry practicum,
-- library, communications, graduation, certificates, alumni.
-- =============================================================================

-- ------------------------------------------------------------------ examinations
INSERT INTO examinations (assessment_id, exam_kind, mode, scheduled_start, duration_minutes, question_paper_key, status)
SELECT a.id, 'regular',
       CASE WHEN seed_rand(a.id::text || 'mode', 100) < 25 THEN 'offline' ELSE 'online' END,
       (a.due_at::date + 0)::timestamptz + interval '10 hours 30 minutes' - interval '5 hours 30 minutes',
       CASE WHEN a.title LIKE 'Final%' THEN 180 ELSE 120 END,
       'vault/question-papers/' || a.id || '.pdf',
       CASE WHEN a.due_at::date <= fn_as_of() THEN 'published' ELSE 'scheduled' END
FROM assessments a WHERE a.assessment_type = 'examination';

INSERT INTO exam_registrations (examination_id, enrollment_id, exam_centre_id, attended)
SELECT x.id, e.id,
       CASE WHEN x.mode = 'online' THEN 1 ELSE 2 + seed_rand(e.student_id::text, 6) END,
       CASE WHEN EXISTS (SELECT 1 FROM assessment_scores s WHERE s.assessment_id = x.assessment_id AND s.enrollment_id = e.id) THEN true
            WHEN x.status = 'published' THEN false END
FROM examinations x
JOIN assessments a ON a.id = x.assessment_id
JOIN enrollments e ON e.offering_id = a.offering_id
WHERE e.status IN ('registered','completed','failed');

INSERT INTO exam_results (exam_registration_id, raw_marks, moderated_marks, moderated_by, revaluation_requested,
                          revaluation_marks, approved_by, published_at)
SELECT r.id, s.marks, LEAST(a.max_marks, s.marks + CASE WHEN seed_rand(r.id::text || 'mod', 100) < 12 THEN 2 ELSE 0 END),
       o.coordinator_id,
       rv.req, CASE WHEN rv.req THEN LEAST(a.max_marks, s.marks + 3) END,
       2, a.due_at + interval '10 days'
FROM exam_registrations r
JOIN examinations x ON x.id = r.examination_id
JOIN assessments a ON a.id = x.assessment_id
JOIN course_offerings o ON o.id = a.offering_id
JOIN assessment_scores s ON s.assessment_id = a.id AND s.enrollment_id = r.enrollment_id
CROSS JOIN LATERAL (SELECT seed_rand(r.id::text || 'rv', 100) < 3 AND s.marks / a.max_marks < 0.7 AS req) rv
WHERE r.attended;

INSERT INTO exam_invigilators (examination_id, exam_centre_id, faculty_id)
SELECT DISTINCT r.examination_id, r.exam_centre_id, 1 + (r.exam_centre_id * 3 + r.examination_id) % 12
FROM exam_registrations r WHERE r.exam_centre_id IS NOT NULL;

-- ------------------------------------------------------------------ Moodle mirror + engagement
INSERT INTO lms_users (student_id, moodle_user_id, last_login_at)
SELECT s.id, 5000 + s.id,
       fn_as_of()::timestamptz - interval '1 day' * CASE
           WHEN s.status_code <> 'active' THEN 60 + seed_rand(s.student_no, 200)
           WHEN p.eng < 20 THEN 24 + seed_rand(s.student_no || 'l', 15)
           WHEN p.eng < 45 THEN 11 + seed_rand(s.student_no || 'l', 8)
           ELSE seed_rand(s.student_no || 'l', 6) END
FROM students s JOIN zz_seed_plan p ON p.sp_id = (SELECT max(sp_id) FROM zz_seed_plan z WHERE z.student_id = s.id);

INSERT INTO lms_enrollments (enrollment_id, moodle_enrollment_id, moodle_course_id, last_access_at, progress_pct,
                             activities_completed, activities_total, quiz_avg_pct, assignment_avg_pct, forum_posts,
                             completed_at, lms_final_grade)
SELECT e.id, 70000 + e.id, 1000 + e.offering_id,
       CASE WHEN e.status = 'registered' THEN fn_as_of()::timestamptz - interval '1 day' * CASE
               WHEN p.eng < 20 THEN 24 + seed_rand(e.id::text, 15)
               WHEN p.eng < 45 THEN 11 + seed_rand(e.id::text, 8)
               ELSE seed_rand(e.id::text, 6) END
            ELSE t.end_date::timestamptz - interval '1 day' * seed_rand(e.id::text, 20) END,
       CASE WHEN e.status IN ('completed','failed') THEN 100
            WHEN e.status = 'withdrawn' THEN 15 + seed_rand(e.id::text, 25)
            ELSE LEAST(95, 18 + p.eng * 0.55 + seed_rand(e.id::text, 15)) END,
       0, 40,
       (SELECT ROUND(AVG(s.marks / a.max_marks * 100), 1) FROM assessment_scores s JOIN assessments a ON a.id = s.assessment_id
         WHERE s.enrollment_id = e.id AND a.assessment_type = 'quiz'),
       (SELECT ROUND(AVG(s.marks / a.max_marks * 100), 1) FROM assessment_scores s JOIN assessments a ON a.id = s.assessment_id
         WHERE s.enrollment_id = e.id AND a.assessment_type IN ('assignment','essay','book_review','biblical_exegesis','research_paper')),
       CASE WHEN p.eng < 20 THEN seed_rand(e.id::text, 3) ELSE 2 + p.eng / 12 + seed_rand(e.id::text, 4) END,
       CASE WHEN e.status IN ('completed','failed') THEN e.finalized_at END,
       e.final_pct
FROM enrollments e
JOIN course_offerings o ON o.id = e.offering_id JOIN terms t ON t.id = o.term_id
JOIN zz_seed_plan p ON p.sp_id = e.student_programme_id;
UPDATE lms_enrollments SET activities_completed = ROUND(activities_total * progress_pct / 100);

-- Raw activity events for the current term (last ~60 days)
INSERT INTO lms_activity (enrollment_id, activity_type, occurred_at, score_pct, detail)
SELECT le.enrollment_id,
       (ARRAY['login','course_access','lesson_complete','video_complete','quiz_attempt','assignment_submit','forum_post','login'])[1 + (g % 8)],
       le.last_access_at - interval '1 hour' * (g * (6 + seed_rand(le.enrollment_id || 'g' || g, 20))),
       CASE WHEN g % 8 = 4 THEN 45 + seed_rand(le.enrollment_id || 'q' || g, 50) END,
       jsonb_build_object('source', 'moodle', 'event_id', 900000 + le.enrollment_id * 10 + g)
FROM lms_enrollments le
JOIN enrollments e ON e.id = le.enrollment_id AND e.status = 'registered'
CROSS JOIN LATERAL generate_series(0, 2 + (le.progress_pct / 9)::int) AS g;

INSERT INTO lms_sync_log (started_at, finished_at, direction, entity, records, status, error)
SELECT ts, ts + interval '40 seconds', d.dir, d.ent, d.n, d.st, d.err
FROM generate_series(fn_as_of()::timestamptz - interval '6 days', fn_as_of()::timestamptz, interval '1 day') ts
CROSS JOIN (VALUES ('erp_to_lms','enrolments',24,'ok',NULL), ('lms_to_erp','grades',318,'ok',NULL), ('lms_to_erp','activity',1450,'ok',NULL)) AS d(dir, ent, n, st, err);
UPDATE lms_sync_log SET status = 'partial', error = 'Moodle web-service timeout on 3 course shells (retried)'
WHERE id = (SELECT max(id) FROM lms_sync_log WHERE entity = 'activity');

-- Forums and participation (last two terms)
INSERT INTO forums (offering_id, title, due_at, is_graded)
SELECT o.id, v.title, (t.start_date + v.d)::timestamptz, v.g
FROM course_offerings o JOIN terms t ON t.id = o.term_id
CROSS JOIN (VALUES ('Course Café — introductions & questions', 14, false), ('Unit Discussion Forum', 60, true)) AS v(title, d, g)
WHERE o.term_id IN (6, 7);
INSERT INTO forum_participation (forum_id, enrollment_id, posts, replies, last_post_at)
SELECT f.id, e.id, GREATEST(0, (p.eng / 30)::int + seed_rand(f.id || 'p' || e.id, 3) - 1),
       GREATEST(0, (p.eng / 25)::int + seed_rand(f.id || 'r' || e.id, 3) - 2), f.due_at - interval '2 days'
FROM forums f JOIN enrollments e ON e.offering_id = f.offering_id JOIN zz_seed_plan p ON p.sp_id = e.student_programme_id
WHERE e.status IN ('registered','completed') AND seed_rand(f.id || 'in' || e.id, 100) < 40 + p.eng / 2;

-- Live-session attendance (last two terms)
INSERT INTO attendance (enrollment_id, session_date, session_type, status)
SELECT e.id, d.dt, 'live_session',
       CASE WHEN seed_rand(e.id || d.dt::text, 100) < 20 + (100 - p.eng) / 3 THEN
                 CASE WHEN seed_rand(e.id || d.dt::text || 'x', 3) = 0 THEN 'excused' ELSE 'absent' END
            WHEN seed_rand(e.id || d.dt::text || 'l', 100) < 8 THEN 'late' ELSE 'present' END
FROM enrollments e JOIN course_offerings o ON o.id = e.offering_id
JOIN zz_seed_plan p ON p.sp_id = e.student_programme_id
CROSS JOIN (VALUES (DATE '2026-01-17'), (DATE '2026-03-14'), (DATE '2026-05-16'), (DATE '2026-07-18'), (DATE '2026-08-15'), (DATE '2026-09-12')) d(dt)
WHERE e.status IN ('registered','completed','failed')
  AND ((o.term_id = 6 AND d.dt < DATE '2026-07-01') OR (o.term_id = 7 AND d.dt > DATE '2026-07-01'));

-- ------------------------------------------------------------------ research / dissertation
INSERT INTO research_projects (student_programme_id, topic, status, supervisor_id, co_supervisor_id,
                               proposal_submitted_on, proposal_approved_on, ethics_approved_on,
                               final_submitted_on, viva_on, final_grade, final_pct)
SELECT sp.id,
       (ARRAY['Shepherd imagery in Zechariah 11 and its pastoral implications for Indian churches',
              'The theology of mission in the Book of Jonah and Northeast India contexts',
              'Covenant and land in the Pentateuch: a reading for tribal communities',
              'Pentecostal pneumatology and ecclesial renewal in South India',
              'Women in ministry: a canonical and contextual study',
              'Hospitality in Luke-Acts and diaspora church planting',
              'Prophetic critique of injustice in Amos and contemporary Dalit theology',
              'Discipleship formation in rural Assemblies of God congregations',
              'Suffering and hope in Job: pastoral counselling perspectives',
              'Biblical stewardship and community development among the Mizo churches',
              'Leadership succession in the Pentateuch: Moses and Joshua',
              'Hermeneutics of the Psalms in Indian Christian worship'])[1 + seed_rand(sp.id::text, 12)],
       CASE WHEN done.ok THEN 'completed'
            WHEN el.terms >= 5 THEN 'writing' WHEN el.terms >= 4 THEN 'research'
            WHEN el.terms >= 2 THEN 'approved' ELSE 'proposal' END,
       1 + seed_rand(sp.id::text || 'sv', 12),
       CASE WHEN seed_rand(sp.id::text || 'co', 100) < 60 THEN 1 + (seed_rand(sp.id::text || 'sv', 12) + 5) % 12 END,
       st.start_date + 60, CASE WHEN el.terms >= 2 THEN st.start_date + 100 END,
       CASE WHEN el.terms >= 3 OR done.ok THEN st.start_date + 130 END,
       CASE WHEN done.ok THEN done.d - 40 END, CASE WHEN done.ok THEN done.d - 10 END,
       done.letter, done.pct
FROM student_programmes sp
JOIN programmes pr ON pr.id = sp.programme_id AND pr.requires_dissertation
JOIN terms st ON st.id = sp.start_term_id
CROSS JOIN LATERAL (SELECT (7 - sp.start_term_id + 1)::int AS terms) el
LEFT JOIN LATERAL (SELECT true AS ok, e.grade_letter AS letter, e.final_pct AS pct, e.finalized_at::date AS d
                   FROM enrollments e JOIN course_offerings o ON o.id = e.offering_id JOIN courses c ON c.id = o.course_id
                   WHERE e.student_programme_id = sp.id AND c.code = 'DIS599' AND e.status = 'completed' LIMIT 1) done ON true
WHERE sp.status <> 'withdrawn';
INSERT INTO research_chapters (project_id, chapter_no, title, submitted_on, feedback, status)
SELECT r.id, ch.n, ch.t, r.proposal_approved_on + 25 * ch.n,
       CASE WHEN r.status IN ('completed') THEN 'Accepted after minor revisions.' ELSE 'Strengthen the exegetical argument and engagement with recent scholarship.' END,
       CASE WHEN r.status = 'completed' OR ch.n < 3 THEN 'accepted' ELSE 'feedback_given' END
FROM research_projects r
CROSS JOIN (VALUES (1,'Introduction and Research Design'), (2,'Literature Review'), (3,'Exegetical Analysis'),
                   (4,'Theological and Contextual Reflection'), (5,'Conclusion and Recommendations')) AS ch(n, t)
WHERE r.status IN ('writing','completed') AND (r.status = 'completed' OR ch.n <= 3)
  AND r.proposal_approved_on IS NOT NULL;

-- ------------------------------------------------------------------ ministry practicum
INSERT INTO internships (student_programme_id, enrollment_id, organization, church, ministry_area, placement,
                         supervisor_name, supervisor_contact, start_date, end_date, status,
                         supervisor_evaluation, student_reflection, final_evaluation, grade)
SELECT e.student_programme_id, e.id,
       COALESCE(pe.ministry_organization, 'Local church ministry'), pe.church_name,
       (ARRAY['church_ministry','missions','youth_ministry','childrens_ministry','chaplaincy','counselling',
              'evangelism','community_development','christian_education','leadership'])[1 + seed_rand(e.id::text, 10)],
       'Supervised placement in home ministry context',
       (ARRAY['Rev. Thomas Mathew','Pastor Lalrinpuii','Rev. Samuel Koshy','Pastor Rebecca Sangma','Rev. Abel Marak'])[1 + seed_rand(e.id::text || 'sup', 5)],
       'supervisor' || e.id || '@example.org', t.start_date + 14, CASE WHEN e.status = 'completed' THEN t.end_date - 30 END,
       CASE WHEN e.status = 'completed' THEN 'completed' WHEN e.status = 'registered' THEN 'ongoing' ELSE 'withdrawn' END,
       CASE WHEN e.status = 'completed' THEN 'Dependable, teachable and growing in pastoral confidence.' END,
       CASE WHEN e.status = 'completed' THEN 'The placement showed me how theology becomes shepherding in daily church life.' END,
       CASE WHEN e.status = 'completed' THEN 'Meets all practicum outcomes.' END,
       e.grade_letter
FROM enrollments e JOIN course_offerings o ON o.id = e.offering_id JOIN courses c ON c.id = o.course_id AND c.code = 'MIN301'
JOIN terms t ON t.id = o.term_id
JOIN student_programmes sp ON sp.id = e.student_programme_id
JOIN students s ON s.id = e.student_id JOIN persons pe ON pe.id = s.person_id;
UPDATE internships SET organization = 'Local church ministry' WHERE organization IS NULL;

INSERT INTO internship_reports (internship_id, week_no, activities, hours, submitted_on)
SELECT i.id, w.n, (ARRAY['Sunday preaching preparation and delivery','Home visitation and prayer','Youth fellowship leadership',
                         'Sunday school teaching','Counselling observation with supervisor','Community outreach','Leadership meeting and planning',
                         'Evangelistic follow-up'])[1 + (w.n - 1) % 8],
       6 + seed_rand(i.id || 'h' || w.n, 8), i.start_date + 7 * w.n
FROM internships i CROSS JOIN generate_series(1, 8) w(n)
WHERE i.status IN ('completed', 'ongoing') AND i.start_date + 7 * w.n <= fn_as_of();

-- ------------------------------------------------------------------ library
INSERT INTO library_members (user_id, member_no, joined_on, status)
SELECT pe.user_id, 'LM-' || lpad((100 + s.id)::text, 5, '0'), s.admitted_on, 'active'
FROM students s JOIN persons pe ON pe.id = s.person_id
WHERE s.status_code IN ('active','graduated','alumni','completed') AND seed_rand(s.student_no || 'lib', 100) < 45
ON CONFLICT DO NOTHING;

INSERT INTO library_loans (resource_id, member_id, borrowed_on, due_on, returned_on)
SELECT r.id, m.id, b.d, b.d + 21,
       CASE WHEN b.d + 21 < fn_as_of() - 30 OR seed_rand(m.id || r.id::text || 'ret', 100) < 55 THEN b.d + 10 + seed_rand(m.id || r.id::text, 25) END
FROM library_members m
JOIN LATERAL (SELECT id FROM library_resources WHERE copies_total > 0 ORDER BY seed_rand(m.id || id::text, 1000) LIMIT 2) r ON true
CROSS JOIN LATERAL (SELECT fn_as_of() - 3 - seed_rand(m.id || r.id::text || 'b', 80) AS d) b
WHERE m.id > 17;
UPDATE library_loans SET returned_on = LEAST(returned_on, fn_as_of()) WHERE returned_on > fn_as_of();

-- ------------------------------------------------------------------ communications & notifications
INSERT INTO communications (template_id, channel, audience_type, audience_ref, subject, body, sent_by, sent_at)
VALUES (9, 'announcement', 'all_students', NULL, 'Welcome to Term 1, 2026-27', 'Grace and peace. Term 1 (2026-27) is now open on the learning platform. Live sessions begin 18 July.', 2, '2026-07-01 09:00+05:30'),
       (2, 'email', 'programme', 4, 'Fee reminder — Master of Divinity', 'Your Term 1 fee instalment is due. Please contact the Finance Office for an instalment plan if needed.', 3, '2026-08-10 10:00+05:30'),
       (4, 'email', 'course', 1, 'Midterm examination notice', 'The midterm examination opens 1 October. Please confirm your exam centre.', 2, '2026-09-20 10:00+05:30'),
       (3, 'push', 'all_students', NULL, 'Assignment 2 due 12 October', 'Assignment 2 is due on 12 October. Submit via Moodle.', 2, '2026-10-05 08:00+05:30');
INSERT INTO communication_recipients (communication_id, user_id, status)
SELECT c.id, pe.user_id, CASE WHEN seed_rand(c.id || pe.user_id::text, 100) < 70 THEN 'read' ELSE 'delivered' END
FROM communications c, students s JOIN persons pe ON pe.id = s.person_id
WHERE s.status_code = 'active' AND (c.audience_type = 'all_students' OR (c.audience_type = 'programme' AND EXISTS
      (SELECT 1 FROM student_programmes sp WHERE sp.student_id = s.id AND sp.programme_id = c.audience_ref AND sp.status = 'active')));

INSERT INTO notifications (user_id, event_code, title, body, created_at, read_at)
SELECT pe.user_id, 'assignment_due', 'Assignment 2 due 12 October', 'Submit through the course page before 23:59 IST.', '2026-10-05 08:00+05:30',
       CASE WHEN seed_rand(pe.user_id::text, 100) < 50 THEN '2026-10-05 20:00+05:30'::timestamptz END
FROM students s JOIN persons pe ON pe.id = s.person_id WHERE s.status_code = 'active';
INSERT INTO notifications (user_id, event_code, title, body, created_at)
SELECT pe.user_id, 'fee_due', 'Fee balance overdue', 'An invoice is past its due date. Contact the Finance Office.', '2026-10-01 09:00+05:30'
FROM students s JOIN persons pe ON pe.id = s.person_id JOIN v_student_finance f ON f.student_id = s.id WHERE f.overdue_amount > 0 AND s.status_code = 'active';

-- ------------------------------------------------------------------ graduation, certificates, alumni
-- Curriculum finished before the current term -> graduation application; conferred when every check passes.
CREATE TEMP TABLE zz_grad AS
SELECT p.sp_id, p.student_id, p.programme_code,
       (p.start_seq + p.d_terms - 1) AS end_seq,
       fn_graduation_eligibility(p.sp_id) AS elig
FROM zz_seed_plan p
JOIN student_programmes sp ON sp.id = p.sp_id
WHERE sp.status IN ('active','completed') AND (p.stop_after_seq IS NULL OR p.outcome = 'completed_progressed')
  AND (p.start_seq + p.d_terms - 1) <= 7;

INSERT INTO graduation_applications (student_programme_id, applied_on, eligibility_snapshot, final_cgpa, status,
                                     approved_by, approved_on, graduation_date)
SELECT g.sp_id,
       CASE g.end_seq WHEN 4 THEN DATE '2025-06-20' WHEN 6 THEN DATE '2026-06-22' ELSE DATE '2026-09-25' END,
       g.elig, (g.elig->>'cgpa')::numeric,
       CASE WHEN (g.elig->>'eligible')::boolean AND g.end_seq <= 6 THEN 'conferred'
            WHEN (g.elig->>'eligible')::boolean THEN 'pending_approval'
            ELSE 'eligibility_check' END,
       CASE WHEN (g.elig->>'eligible')::boolean AND g.end_seq <= 6 THEN 2 END,
       CASE WHEN (g.elig->>'eligible')::boolean AND g.end_seq <= 6 THEN CASE g.end_seq WHEN 4 THEN DATE '2025-07-10' ELSE DATE '2026-07-10' END END,
       CASE WHEN (g.elig->>'eligible')::boolean AND g.end_seq <= 6 THEN CASE g.end_seq WHEN 4 THEN DATE '2025-07-26' ELSE DATE '2026-07-25' END END
FROM zz_grad g
WHERE (g.elig->>'eligible')::boolean OR g.end_seq <= 7;
-- conferral trigger has marked programmes graduated, students completed/graduated and created alumni rows
SELECT fn_promote_graduates_to_alumni(30);

UPDATE alumni a SET further_studies = CASE WHEN seed_rand(a.id::text, 100) < 20 THEN 'Enrolled in further theological study' END,
                    directory_visible = seed_rand(a.id::text || 'v', 100) < 85;

-- Certificates for conferred graduates (+ transcripts)
INSERT INTO certificates (certificate_no, cert_type, student_id, student_programme_id, issued_on, verification_code,
                          verification_url, signatories, status)
SELECT 'GSOL-' || to_char(ga.graduation_date, 'YYYY') || '-C' || lpad(row_number() OVER (ORDER BY ga.graduation_date, sp.id)::text, 4, '0'),
       CASE pr.code WHEN 'DIP-TH' THEN 'diploma' WHEN 'BTH' THEN 'bachelor' WHEN 'MACS' THEN 'master_arts' ELSE 'master_divinity' END,
       sp.student_id, sp.id, ga.graduation_date,
       substr(md5('gsol-cert-' || sp.id), 1, 16), 'https://erp.gsol.example.org/verify/' || substr(md5('gsol-cert-' || sp.id), 1, 16),
       '[{"name":"Dean of Academic Affairs","title":"Dean"},{"name":"Registrar","title":"Registrar"}]'::jsonb, 'valid'
FROM graduation_applications ga JOIN student_programmes sp ON sp.id = ga.student_programme_id
JOIN programmes pr ON pr.id = sp.programme_id WHERE ga.status = 'conferred';

INSERT INTO certificates (certificate_no, cert_type, student_id, student_programme_id, issued_on, verification_code,
                          verification_url, signatories, status)
SELECT 'GSOL-' || to_char(ga.graduation_date, 'YYYY') || '-T' || lpad(row_number() OVER (ORDER BY ga.graduation_date, sp.id)::text, 4, '0'),
       'transcript', sp.student_id, sp.id, ga.graduation_date,
       substr(md5('gsol-tr-' || sp.id), 1, 16), 'https://erp.gsol.example.org/verify/' || substr(md5('gsol-tr-' || sp.id), 1, 16),
       '[{"name":"Registrar","title":"Registrar"}]'::jsonb, 'valid'
FROM graduation_applications ga JOIN student_programmes sp ON sp.id = ga.student_programme_id WHERE ga.status = 'conferred';

-- Course-completion and internship certificates
INSERT INTO certificates (certificate_no, cert_type, student_id, student_programme_id, enrollment_id, issued_on, verification_code,
                          verification_url, signatories, status)
SELECT 'GSOL-CC-' || lpad(e.id::text, 5, '0'), 'course_completion', e.student_id, e.student_programme_id, e.id,
       e.finalized_at::date + 20, substr(md5('gsol-cc-' || e.id), 1, 16),
       'https://erp.gsol.example.org/verify/' || substr(md5('gsol-cc-' || e.id), 1, 16),
       '[{"name":"Registrar","title":"Registrar"}]'::jsonb, 'valid'
FROM enrollments e WHERE e.status = 'completed' AND e.grade_letter IN ('A','B+') AND seed_rand(e.id::text || 'cc', 100) < 6;
INSERT INTO certificates (certificate_no, cert_type, student_id, student_programme_id, enrollment_id, issued_on, verification_code,
                          verification_url, signatories, status)
SELECT 'GSOL-IN-' || lpad(i.id::text, 5, '0'), 'internship', sp.student_id, sp.id, i.enrollment_id, i.end_date + 15,
       substr(md5('gsol-in-' || i.id), 1, 16), 'https://erp.gsol.example.org/verify/' || substr(md5('gsol-in-' || i.id), 1, 16),
       '[{"name":"Programme Coordinator","title":"Coordinator"}]'::jsonb, 'valid'
FROM internships i JOIN student_programmes sp ON sp.id = i.student_programme_id WHERE i.status = 'completed';

-- ------------------------------------------------------------------ housekeeping: drop seed scaffolding
DROP FUNCTION IF EXISTS seed_new_person(int, text);
-- (zz_seed_plan is kept until 99_finish so repeat loads of this file stay deterministic)
