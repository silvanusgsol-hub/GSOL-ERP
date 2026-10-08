-- =============================================================================
-- GSOL ERP demo seed 01 — reference & configuration data
-- ALL PEOPLE, FEES AND GRADES IN THE SEED FILES ARE SYNTHETIC DEMO DATA.
-- Fee amounts, accreditation text and curricula are illustrative placeholders to be
-- replaced with GSOL's real figures by the Registrar / Finance Officer.
-- =============================================================================

-- demo session settings: freeze "today", silence audit during bulk load (re-enabled in 99_finish.sql)
SELECT set_config('gsol.as_of_date', '2026-10-07', false);
SELECT set_config('gsol.audit_enabled', 'off', false);

-- deterministic pseudo-random helper (dropped in 99_finish.sql)
CREATE FUNCTION seed_rand(k text, n int) RETURNS int LANGUAGE sql IMMUTABLE AS
$$ SELECT ((hashtext(k)::bigint & 2147483647) % n)::int $$;

-- ------------------------------------------------------------ student statuses
INSERT INTO student_statuses (code, label, sort_order, is_active_state, is_terminal) VALUES
 ('applicant',         'Applicant',          1, false, false),
 ('applied',           'Applied',            2, false, false),
 ('admission_pending', 'Admission Pending',  3, false, false),
 ('admitted',          'Admitted',           4, false, false),
 ('enrolled',          'Enrolled',           5, false, false),
 ('active',            'Active',             6, true,  false),
 ('on_leave',          'On Leave',           7, false, false),
 ('deferred',          'Deferred',           8, false, false),
 ('suspended',         'Suspended',          9, false, false),
 ('withdrawn',         'Withdrawn',         10, false, true),
 ('completed',         'Completed',         11, false, false),
 ('graduated',         'Graduated',         12, false, false),
 ('alumni',            'Alumni',            13, false, false);

INSERT INTO student_status_transitions (from_code, to_code) VALUES
 ('applicant','applied'), ('applied','admission_pending'), ('admission_pending','admitted'),
 ('admission_pending','withdrawn'), ('admitted','enrolled'), ('admitted','withdrawn'),
 ('enrolled','active'), ('enrolled','withdrawn'),
 ('active','on_leave'), ('active','deferred'), ('active','suspended'), ('active','withdrawn'),
 ('active','completed'),
 ('on_leave','active'), ('on_leave','withdrawn'), ('deferred','active'), ('deferred','withdrawn'),
 ('suspended','active'), ('suspended','withdrawn'),
 ('completed','graduated'), ('graduated','alumni'),
 -- progression to a further programme (Diploma -> Bachelor -> MA)
 ('graduated','enrolled'), ('alumni','enrolled');

-- ------------------------------------------------------------------ grade scale
INSERT INTO grade_scales (name, is_default) VALUES ('GSOL 4.0 scale (demo)', true);
INSERT INTO grade_scale_bands (grade_scale_id, letter, min_pct, max_pct, grade_point, is_pass)
SELECT s.id, v.letter, v.lo, v.hi, v.gp, v.pass
FROM grade_scales s,
     (VALUES ('A', 85, 100, 4.00, true), ('B+', 75, 84, 3.50, true), ('B', 65, 74, 3.00, true),
             ('C+', 55, 64, 2.50, true), ('C', 50, 54, 2.00, true), ('F', 0, 49, 0.00, false)) AS v(letter, lo, hi, gp, pass);

-- ------------------------------------------------------ departments / calendar
INSERT INTO departments (code, name) VALUES
 ('BIB', 'Biblical Studies'), ('THC', 'Theology & Church History'), ('PMS', 'Pastoral & Mission Studies');

INSERT INTO academic_years (label, start_date, end_date, is_current) VALUES
 ('2023-24', '2023-07-01', '2024-06-30', false),
 ('2024-25', '2024-07-01', '2025-06-30', false),
 ('2025-26', '2025-07-01', '2026-06-30', false),
 ('2026-27', '2026-07-01', '2027-06-30', true);

-- seq 1..8 : Term 1 = Jul-Dec, Term 2 = Jan-Jun
INSERT INTO terms (academic_year_id, seq, name, start_date, end_date, registration_deadline)
SELECT ay.id,
       (EXTRACT(year FROM ay.start_date)::int - 2023) * 2 + n,
       'Term ' || n,
       CASE n WHEN 1 THEN ay.start_date ELSE (ay.start_date + interval '6 months')::date END,
       CASE n WHEN 1 THEN (ay.start_date + interval '6 months - 1 day')::date ELSE ay.end_date END,
       CASE n WHEN 1 THEN (ay.start_date + interval '14 days')::date ELSE (ay.start_date + interval '6 months 14 days')::date END
FROM academic_years ay CROSS JOIN (VALUES (1), (2)) AS x(n);

-- ------------------------------------------------------------------------ RBAC
INSERT INTO roles (code, name, description) VALUES
 ('super_admin',          'Super Administrator',  'Complete system control'),
 ('registrar',            'Registrar',            'Admissions, academic records, transcripts, graduation'),
 ('dean',                 'Dean',                 'Programme oversight and academic performance'),
 ('programme_coordinator','Programme Coordinator','Programme and student management'),
 ('faculty',              'Faculty',              'Courses, assessments, grading and students'),
 ('academic_advisor',     'Academic Advisor',     'Assigned students and progress'),
 ('admissions_officer',   'Admissions Officer',   'Application review and document verification'),
 ('finance_officer',      'Finance Officer',      'Fees, payments and financial reports'),
 ('librarian',            'Librarian',            'Library management'),
 ('student',              'Student',              'Own records, courses, assignments, grades and fees'),
 ('applicant',            'Applicant',            'Own admissions application');

INSERT INTO permissions (resource, action)
SELECT r, a
FROM unnest(ARRAY['users','roles','students','applications','programmes','courses','curriculum','enrollments',
                  'assessments','examinations','grades','faculty','advising','fees','payments','scholarships',
                  'library','research','internships','graduation','certificates','alumni','documents',
                  'communications','reports','lms','audit_logs']) AS r
CROSS JOIN unnest(ARRAY['view','create','edit','delete','approve','export','publish']) AS a;

-- (role, resources, actions, scope)
INSERT INTO role_permissions (role_id, permission_id, scope)
SELECT ro.id, pm.id, g.scope
FROM (VALUES
 ('super_admin',          'users,roles,students,applications,programmes,courses,curriculum,enrollments,assessments,examinations,grades,faculty,advising,fees,payments,scholarships,library,research,internships,graduation,certificates,alumni,documents,communications,reports,lms,audit_logs', 'view,create,edit,delete,approve,export,publish', 'all'),
 ('registrar',            'students,applications,enrollments,examinations,graduation,certificates,alumni,documents', 'view,create,edit,approve,export,publish', 'all'),
 ('registrar',            'programmes,courses,curriculum,grades,faculty,reports,communications', 'view,export', 'all'),
 ('registrar',            'grades', 'approve,publish', 'all'),
 ('dean',                 'programmes,courses,grades,graduation,research,faculty', 'view,approve', 'all'),
 ('dean',                 'students,enrollments,reports', 'view,export', 'all'),
 ('programme_coordinator','students,enrollments,research,internships,courses', 'view,edit,approve', 'programme'),
 ('programme_coordinator','grades,curriculum,reports', 'view,export', 'programme'),
 ('faculty',              'assessments,grades', 'view,create,edit', 'assigned'),
 ('faculty',              'courses,students,enrollments,examinations,lms,research,internships', 'view', 'assigned'),
 ('academic_advisor',     'students,enrollments,grades,lms,reports', 'view', 'assigned'),
 ('academic_advisor',     'advising,communications', 'view,create,edit', 'assigned'),
 ('admissions_officer',   'applications,documents', 'view,create,edit,approve', 'all'),
 ('admissions_officer',   'students', 'view', 'all'),
 ('finance_officer',      'fees,payments,scholarships', 'view,create,edit,approve,export', 'all'),
 ('finance_officer',      'reports,students', 'view,export', 'all'),
 ('librarian',            'library', 'view,create,edit,delete,export', 'all'),
 ('student',              'students,enrollments,assessments,grades,fees,payments,certificates,alumni', 'view', 'own'),
 ('student',              'enrollments,documents,research,internships,payments', 'create,edit', 'own'),
 ('student',              'library', 'view', 'all'),
 ('applicant',            'applications,documents,payments', 'view,create,edit', 'own')
) AS g(role_code, resources, actions, scope)
JOIN roles ro ON ro.code = g.role_code
JOIN permissions pm ON pm.resource = ANY(string_to_array(g.resources, ','))
                   AND pm.action   = ANY(string_to_array(g.actions, ','))
ON CONFLICT (role_id, permission_id) DO UPDATE
    SET scope = CASE WHEN EXCLUDED.scope = 'all' THEN 'all' ELSE role_permissions.scope END;

-- --------------------------------------------- categories, assessment schemes
INSERT INTO course_categories (code, name) VALUES
 ('BIB','Biblical Studies'), ('THE','Theology'), ('HIS','Church History'),
 ('MIN','Ministry & Mission'), ('LAN','Biblical Languages'), ('RES','Research');

INSERT INTO assessment_schemes (code, name) VALUES
 ('STD','Standard ODL course (assignment, quiz, forum, midterm, final)'),
 ('PRACT','Ministry practicum'),
 ('DISS','Dissertation');

INSERT INTO assessment_scheme_items (scheme_id, title, assessment_type, weight_pct, max_marks, due_day_offset)
SELECT s.id, v.title, v.typ, v.w, 100, v.off
FROM assessment_schemes s
JOIN (VALUES
 ('STD','Quiz','quiz',10,45), ('STD','Discussion Forum','discussion_forum',10,60),
 ('STD','Assignment','assignment',20,70), ('STD','Midterm Examination','examination',20,80),
 ('STD','Final Examination','examination',40,160),
 ('PRACT','Ministry Project','ministry_project',50,120), ('PRACT','Supervisor Evaluation','internship',30,150),
 ('PRACT','Reflection Paper','essay',20,160),
 ('DISS','Proposal','research_paper',20,60), ('DISS','Dissertation','dissertation',60,170),
 ('DISS','Viva','presentation',20,178)
) AS v(scode, title, typ, w, off) ON v.scode = s.code;

-- -------------------------------------------------------------------- fee types
INSERT INTO fee_types (code, name) VALUES
 ('APP','Application Fee'), ('ADM','Admission Fee'), ('TUI','Tuition'), ('CRS','Course Fee'),
 ('EXM','Examination Fee'), ('LIB','Library Fee'), ('GRD','Graduation Fee'),
 ('DIS','Dissertation Fee'), ('OTH','Other Charges');

INSERT INTO scholarships (code, name, eligibility_criteria, award_type, award_value, duration_terms, renewable) VALUES
 ('MERIT25',  'Academic Merit Scholarship',    'CGPA of 3.5 or above in the previous programme or entrance review', 'percentage', 25, 4, true),
 ('MINISTRY50','Ministry Partnership Bursary', 'Full-time ministry worker recommended by a church or mission body',   'percentage', 50, 6, true),
 ('NEED3K',   'Student Need Grant',            'Documented financial need reviewed by the Finance Officer',          'fixed',      3000, 2, false);

INSERT INTO exam_centres (code, name, city, state, country, is_online) VALUES
 ('ONLINE','Online proctored','—','—','—', true),
 ('BLR','Bengaluru Study Centre','Bengaluru','Karnataka','India', false),
 ('CHN','Chennai Study Centre','Chennai','Tamil Nadu','India', false),
 ('HYD','Hyderabad Study Centre','Hyderabad','Telangana','India', false),
 ('KOH','Kohima Study Centre','Kohima','Nagaland','India', false),
 ('AIZ','Aizawl Study Centre','Aizawl','Mizoram','India', false),
 ('KTM','Kottayam Study Centre','Kottayam','Kerala','India', false);

-- --------------------------------------------- communication templates & rules
INSERT INTO message_templates (code, name, channel, subject, body) VALUES
 ('admission_letter',     'Admission letter',        'email', 'Offer of admission — {{programme}}', 'Dear {{name}}, we are pleased to offer you admission to {{programme}} at the Global School of Open Learning. Please accept by {{deadline}}.'),
 ('fee_reminder',         'Fee reminder',            'email', 'Fee reminder — invoice {{invoice_no}}', 'Dear {{name}}, invoice {{invoice_no}} of {{amount}} is due on {{due_date}}.'),
 ('assignment_reminder',  'Assignment reminder',     'push',  'Assignment due soon', '{{assessment}} for {{course}} is due on {{due_date}}.'),
 ('exam_notice',          'Examination notice',      'email', 'Examination timetable — {{course}}', 'Your {{exam}} for {{course}} is scheduled on {{date}} at {{centre}}.'),
 ('course_registration',  'Course registration',     'email', 'Registration confirmed — {{course}}', 'You are registered for {{course}} in {{term}}.'),
 ('academic_warning',     'Academic warning',        'email', 'Academic support notice', 'Dear {{name}}, your academic advisor would like to meet to discuss your progress.'),
 ('graduation_invitation','Graduation invitation',   'email', 'You are invited to graduation', 'Dear {{name}}, congratulations on completing {{programme}}. Graduation is on {{date}}.'),
 ('certificate_notice',   'Certificate notification','email', 'Your certificate is ready', 'Certificate {{certificate_no}} has been issued. Verify at {{url}}.'),
 ('welcome_announcement', 'Welcome announcement',    'announcement', 'Welcome to the new term', 'Term {{term}} begins on {{date}}. Moodle courses are now open.');

INSERT INTO notification_rules (event_code, template_id, channel, offset_days, is_enabled)
SELECT v.ev, t.id, v.ch, v.off, true
FROM (VALUES
 ('admission_approval','admission_letter','email',0), ('course_registration','course_registration','email',0),
 ('payment_received','fee_reminder','email',0), ('fee_due','fee_reminder','email',-7),
 ('assignment_due','assignment_reminder','push',-3), ('assignment_overdue','assignment_reminder','push',1),
 ('exam_registration','exam_notice','email',-30), ('exam_timetable','exam_notice','email',-14),
 ('results_published','exam_notice','email',0), ('academic_warning','academic_warning','email',0),
 ('graduation_eligibility','graduation_invitation','email',0), ('certificate_issued','certificate_notice','email',0)
) AS v(ev, tmpl, ch, off)
JOIN message_templates t ON t.code = v.tmpl;

INSERT INTO engagement_config DEFAULT VALUES;

-- ---------------------------------------------------------------------- library
INSERT INTO publishers (name) VALUES ('Eerdmans'), ('InterVarsity Press'), ('Zondervan'), ('Baker Academic'),
 ('Westminster John Knox Press'), ('Fortress Press'), ('Moody Publishers');
INSERT INTO library_categories (code, name) VALUES
 ('OT','Old Testament'), ('NT','New Testament'), ('THE','Systematic Theology'), ('HIS','Church History'),
 ('MIS','Missiology'), ('PAS','Pastoral Theology'), ('LAN','Biblical Languages'), ('ETH','Ethics'), ('PER','Periodicals');
INSERT INTO authors (name) VALUES
 ('Walter Brueggemann'), ('Shirley C. Guthrie'), ('John Calvin'), ('Christopher J. H. Wright'),
 ('Gordon D. Fee'), ('Douglas Stuart'), ('Gleason L. Archer'), ('Dietrich Bonhoeffer'), ('Bruce L. Shelley'),
 ('C. S. Lewis'), ('Allen P. Ross'), ('William D. Mounce'), ('J. Oswald Sanders'), ('John R. W. Stott'),
 ('Samuel Hugh Moffett'), ('Richard Baxter'), ('Richard B. Hays'), ('Stephen Neill'), ('Allan Anderson');

INSERT INTO library_resources (resource_type, title, publisher_id, category_id, publication_year, copies_total, digital_url) VALUES
 ('book',  'Theology of the Old Testament: Testimony, Dispute, Advocacy', (SELECT id FROM publishers WHERE name='Fortress Press'), (SELECT id FROM library_categories WHERE code='OT'), 1997, 2, NULL),
 ('book',  'Christian Doctrine', (SELECT id FROM publishers WHERE name='Westminster John Knox Press'), (SELECT id FROM library_categories WHERE code='THE'), 1994, 3, NULL),
 ('book',  'Institutes of the Christian Religion', NULL, (SELECT id FROM library_categories WHERE code='THE'), 1559, 2, NULL),
 ('book',  'The Mission of God', (SELECT id FROM publishers WHERE name='InterVarsity Press'), (SELECT id FROM library_categories WHERE code='MIS'), 2006, 3, NULL),
 ('book',  'How to Read the Bible for All Its Worth', (SELECT id FROM publishers WHERE name='Zondervan'), (SELECT id FROM library_categories WHERE code='NT'), 1981, 4, NULL),
 ('book',  'A Survey of Old Testament Introduction', (SELECT id FROM publishers WHERE name='Moody Publishers'), (SELECT id FROM library_categories WHERE code='OT'), 1964, 2, NULL),
 ('book',  'The Cost of Discipleship', NULL, (SELECT id FROM library_categories WHERE code='ETH'), 1937, 2, NULL),
 ('book',  'Church History in Plain Language', NULL, (SELECT id FROM library_categories WHERE code='HIS'), 1982, 3, NULL),
 ('book',  'Mere Christianity', NULL, (SELECT id FROM library_categories WHERE code='THE'), 1952, 2, NULL),
 ('book',  'Introducing Biblical Hebrew and Grammar', NULL, (SELECT id FROM library_categories WHERE code='LAN'), NULL, 1, NULL),
 ('book',  'Basics of Biblical Greek Grammar', (SELECT id FROM publishers WHERE name='Zondervan'), (SELECT id FROM library_categories WHERE code='LAN'), 1993, 3, NULL),
 ('book',  'Spiritual Leadership', (SELECT id FROM publishers WHERE name='Moody Publishers'), (SELECT id FROM library_categories WHERE code='PAS'), 1967, 3, NULL),
 ('book',  'Christian Mission in the Modern World', (SELECT id FROM publishers WHERE name='InterVarsity Press'), (SELECT id FROM library_categories WHERE code='MIS'), 1975, 2, NULL),
 ('book',  'A History of Christianity in Asia', NULL, (SELECT id FROM library_categories WHERE code='HIS'), 1992, 2, NULL),
 ('book',  'The Reformed Pastor', NULL, (SELECT id FROM library_categories WHERE code='PAS'), 1656, 2, NULL),
 ('book',  'The Moral Vision of the New Testament', NULL, (SELECT id FROM library_categories WHERE code='ETH'), 1996, 2, NULL),
 ('book',  'A History of Christianity in India: The Beginnings to AD 1707', NULL, (SELECT id FROM library_categories WHERE code='HIS'), 1984, 2, NULL),
 ('book',  'An Introduction to Pentecostalism', NULL, (SELECT id FROM library_categories WHERE code='THE'), 2004, 3, NULL),
 ('ebook', 'Theology of the Old Testament: Testimony, Dispute, Advocacy (e-edition)', NULL, (SELECT id FROM library_categories WHERE code='OT'), NULL, 0, 'https://library.gsol.example.org/e/otheology'),
 ('journal','Asian Journal of Pentecostal Studies', NULL, (SELECT id FROM library_categories WHERE code='PER'), NULL, 0, 'https://library.gsol.example.org/j/ajps'),
 ('journal','Journal of Asian Mission', NULL, (SELECT id FROM library_categories WHERE code='PER'), NULL, 0, 'https://library.gsol.example.org/j/jam'),
 ('digital','GSOL Open Courseware — Old Testament Narratives readings', NULL, (SELECT id FROM library_categories WHERE code='OT'), 2026, 0, 'https://library.gsol.example.org/d/otn');

INSERT INTO library_resource_authors (resource_id, author_id)
SELECT r.id, a.id FROM (VALUES
 ('Theology of the Old Testament: Testimony, Dispute, Advocacy','Walter Brueggemann'),
 ('Theology of the Old Testament: Testimony, Dispute, Advocacy (e-edition)','Walter Brueggemann'),
 ('Christian Doctrine','Shirley C. Guthrie'), ('Institutes of the Christian Religion','John Calvin'),
 ('The Mission of God','Christopher J. H. Wright'),
 ('How to Read the Bible for All Its Worth','Gordon D. Fee'), ('How to Read the Bible for All Its Worth','Douglas Stuart'),
 ('A Survey of Old Testament Introduction','Gleason L. Archer'), ('The Cost of Discipleship','Dietrich Bonhoeffer'),
 ('Church History in Plain Language','Bruce L. Shelley'), ('Mere Christianity','C. S. Lewis'),
 ('Introducing Biblical Hebrew and Grammar','Allen P. Ross'),
 ('Basics of Biblical Greek Grammar','William D. Mounce'), ('Spiritual Leadership','J. Oswald Sanders'),
 ('Christian Mission in the Modern World','John R. W. Stott'),
 ('A History of Christianity in Asia','Samuel Hugh Moffett'), ('The Reformed Pastor','Richard Baxter'),
 ('The Moral Vision of the New Testament','Richard B. Hays'),
 ('A History of Christianity in India: The Beginnings to AD 1707','Stephen Neill'),
 ('An Introduction to Pentecostalism','Allan Anderson')
) AS v(t, a_name)
JOIN library_resources r ON r.title = v.t JOIN authors a ON a.name = v.a_name;
