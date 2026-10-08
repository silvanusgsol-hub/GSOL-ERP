-- =============================================================================
-- GSOL ERP demo seed 03 — programmes, curricula, courses, prerequisites, ODL content
-- Curricula are representative subsets for the demo. Real curricula load through the
-- same tables; total_credits below is derived from whatever is in the curriculum.
-- =============================================================================

INSERT INTO programmes (code, name, level, description, duration_months, total_credits, admission_requirements,
                        department_id, coordinator_id, requires_dissertation, accreditation_info, introduced_on, revised_on)
SELECT v.code, v.name, v.level, v.descr, v.months, 1, v.adm,
       (SELECT id FROM departments WHERE code = v.dept),
       (SELECT id FROM faculty WHERE faculty_no = v.coord),
       v.diss,
       'Accreditation details to be entered by the Registrar (demo placeholder).',
       DATE '2023-07-01', DATE '2026-07-01'
FROM (VALUES
 ('DIP-TH', 'Diploma in Theology',             'diploma',             'Foundational biblical and theological formation for lay and bi-vocational ministers.', 24,
   'Higher Secondary (or equivalent) and a church recommendation', 'BIB', 'FAC-0001', false),
 ('BTH',    'Bachelor of Theology',            'bachelor',            'Undergraduate theological degree integrating biblical studies, theology, history and ministry.', 36,
   'Higher Secondary (or equivalent); Diploma in Theology graduates may apply with credit recognition', 'THC', 'FAC-0002', false),
 ('MACS',   'Master of Arts in Christian Studies', 'master',          'Postgraduate research-oriented programme with a dissertation.', 24,
   'Bachelor''s degree; research proposal; church or ministry reference', 'THC', 'FAC-0004', true),
 ('MDIV',   'Master of Divinity',              'professional_master', 'Professional ministry degree with practicum and thesis.', 36,
   'Bachelor''s degree; ministry experience; church recommendation', 'PMS', 'FAC-0006', true)
) AS v(code, name, level, descr, months, adm, dept, coord, diss);

INSERT INTO curricula (programme_id, version, effective_from, status)
SELECT id, 'v1', DATE '2023-07-01', 'active' FROM programmes;

-- ------------------------------------------------------------------- courses
INSERT INTO courses (code, title, description, credits, learning_hours, level, category_id, department_id, assessment_scheme_id, lms_course_id)
SELECT v.code, v.title, v.descr, v.cr, (v.cr * 40)::int, v.lvl,
       (SELECT id FROM course_categories WHERE code = v.cat),
       (SELECT id FROM departments WHERE code = v.dept),
       (SELECT id FROM assessment_schemes WHERE code = v.scheme),
       'tpl-' || lower(v.code)
FROM (VALUES
 ('OT101','Introduction to the Old Testament','Survey of the Old Testament: history, literature and theology.',3,100,'BIB','BIB','STD'),
 ('NT101','Introduction to the New Testament','Survey of the New Testament world, Gospels, Acts, letters and Revelation.',3,100,'BIB','BIB','STD'),
 ('TH101','Christian Theology','Introduction to the major doctrines of the Christian faith.',3,100,'THE','THC','STD'),
 ('CH101','Church History','From the apostolic church to the modern global church, with attention to India.',3,100,'HIS','THC','STD'),
 ('HM201','Hermeneutics','Principles of biblical interpretation across genres and cultures.',3,200,'BIB','BIB','STD'),
 ('PT201','Pastoral Theology','Foundations of pastoral ministry, preaching, worship and care.',3,200,'MIN','PMS','STD'),
 ('OT201','Pentateuch','Genesis to Deuteronomy: narrative, law and covenant theology.',3,200,'BIB','BIB','STD'),
 ('CE201','Christian Ethics','Biblical and theological foundations for moral life and public witness.',3,200,'THE','THC','STD'),
 ('MS201','Missiology','Biblical theology and history of mission.',3,200,'MIN','PMS','STD'),
 ('CL201','Christian Leadership','Servant leadership, team building and church administration.',3,200,'MIN','PMS','STD'),
 ('OT202','Old Testament Narratives','Interpretation, theology and contemporary relevance of Old Testament narrative.',3,200,'BIB','BIB','STD'),
 ('MIN301','Ministry Practicum','Supervised ministry placement with reflection and evaluation.',3,300,'MIN','PMS','PRACT'),
 ('BG201','Biblical Greek','Elementary Koine Greek grammar and reading.',3,200,'LAN','BIB','STD'),
 ('BH201','Biblical Hebrew','Elementary Biblical Hebrew grammar and reading.',3,200,'LAN','BIB','STD'),
 ('OT301','Prophets','The prophetic movement and the books of the Hebrew prophets.',3,300,'BIB','BIB','STD'),
 ('EX301','Biblical Exegesis','Exegetical method applied to selected Old and New Testament passages.',3,300,'BIB','BIB','STD'),
 ('RM501','Research Methodology','Research design, sources, argument and academic writing in theology.',3,500,'RES','THC','STD'),
 ('TH501','Systematic Theology','Advanced study of Christian doctrine in dialogue with the Indian context.',3,500,'THE','THC','STD'),
 ('OT501','Old Testament Theology','Major themes and methods in Old Testament theology.',3,500,'BIB','BIB','STD'),
 ('NT501','New Testament Theology','Major themes and methods in New Testament theology.',3,500,'BIB','BIB','STD'),
 ('CH501','Church History in Asia','The history of Christianity in Asia with emphasis on South Asia.',3,500,'HIS','THC','STD'),
 ('MS501','Mission in the Indian Context','Contextual mission theology and practice in India.',3,500,'MIN','PMS','STD'),
 ('EX501','Advanced Biblical Exegesis','Advanced exegetical research using the original languages.',3,500,'BIB','BIB','STD'),
 ('PT501','Pastoral Counselling','Theory and practice of pastoral counselling.',3,500,'MIN','PMS','STD'),
 ('DIS599','Dissertation','Supervised research dissertation.',6,500,'RES','THC','DISS')
) AS v(code, title, descr, cr, lvl, cat, dept, scheme);

-- --------------------------------------------------- curriculum placement
-- (programme, term_seq, course)
INSERT INTO curriculum_courses (curriculum_id, course_id, term_seq)
SELECT cu.id, c.id, v.t
FROM (VALUES
 ('DIP-TH',1,'OT101'),('DIP-TH',1,'NT101'),('DIP-TH',1,'TH101'),
 ('DIP-TH',2,'CH101'),('DIP-TH',2,'HM201'),('DIP-TH',2,'PT201'),
 ('DIP-TH',3,'OT201'),('DIP-TH',3,'CE201'),('DIP-TH',3,'MS201'),
 ('DIP-TH',4,'CL201'),('DIP-TH',4,'OT202'),('DIP-TH',4,'MIN301'),

 ('BTH',1,'OT101'),('BTH',1,'NT101'),('BTH',1,'TH101'),
 ('BTH',2,'CH101'),('BTH',2,'HM201'),('BTH',2,'BG201'),
 ('BTH',3,'OT201'),('BTH',3,'BH201'),('BTH',3,'PT201'),
 ('BTH',4,'OT202'),('BTH',4,'CE201'),('BTH',4,'MS201'),
 ('BTH',5,'OT301'),('BTH',5,'EX301'),('BTH',5,'CL201'),
 ('BTH',6,'MIN301'),('BTH',6,'RM501'),

 ('MACS',1,'RM501'),('MACS',1,'TH501'),('MACS',1,'HM201'),
 ('MACS',2,'OT501'),('MACS',2,'NT501'),('MACS',2,'CH501'),
 ('MACS',3,'EX501'),('MACS',3,'PT501'),('MACS',3,'MS501'),
 ('MACS',4,'DIS599'),

 ('MDIV',1,'TH501'),('MDIV',1,'OT501'),('MDIV',1,'NT501'),
 ('MDIV',2,'CH501'),('MDIV',2,'HM201'),('MDIV',2,'BH201'),
 ('MDIV',3,'BG201'),('MDIV',3,'EX501'),('MDIV',3,'MS501'),
 ('MDIV',4,'PT501'),('MDIV',4,'CE201'),('MDIV',4,'CL201'),
 ('MDIV',5,'RM501'),('MDIV',5,'OT301'),('MDIV',5,'MIN301'),
 ('MDIV',6,'DIS599')
) AS v(prog, t, course)
JOIN programmes p ON p.code = v.prog
JOIN curricula cu ON cu.programme_id = p.id
JOIN courses c ON c.code = v.course;

-- programme totals derive from the curriculum
UPDATE programmes p SET
    total_credits = s.cr,
    total_learning_hours = s.hrs
FROM (SELECT cu.programme_id, SUM(c.credits) AS cr, SUM(c.learning_hours) AS hrs
      FROM curricula cu JOIN curriculum_courses cc ON cc.curriculum_id = cu.id JOIN courses c ON c.id = cc.course_id
      GROUP BY cu.programme_id) s
WHERE s.programme_id = p.id;

-- ----------------------------------------------------------- prerequisites
-- AND across group_no, OR inside a group
INSERT INTO course_prerequisites (course_id, prerequisite_course_id, group_no)
SELECT c.id, p.id, v.g
FROM (VALUES
 ('OT201','OT101',1), ('OT201','OT501',1),
 ('OT202','OT101',1), ('OT202','OT501',1),
 ('OT301','OT201',1), ('OT301','OT501',1),
 ('EX301','HM201',1), ('EX501','HM201',1),
 ('PT201','TH101',1), ('PT201','TH501',1),
 ('PT501','TH501',1), ('DIS599','RM501',1)
) AS v(course, prereq, g)
JOIN courses c ON c.code = v.course JOIN courses p ON p.code = v.prereq;

-- -------------------------------------------------- ODL content (demo shells)
INSERT INTO course_units (course_id, unit_no, title, learning_hours)
SELECT c.id, v.n, v.title, 10
FROM (VALUES
 ('OT202',1,'Reading Old Testament Narrative'), ('OT202',2,'Narrative Art and Theology'),
 ('OT202',3,'Narrative in the Indian Context'),
 ('OT101',1,'The Old Testament World'), ('OT101',2,'Law, Prophets and Writings'), ('OT101',3,'Covenant and Kingdom'),
 ('TH101',1,'Revelation and Scripture'), ('TH101',2,'God, Creation and Humanity'), ('TH101',3,'Christ, Spirit and Church')
) AS v(code, n, title) JOIN courses c ON c.code = v.code;

INSERT INTO lessons (unit_id, lesson_no, title, learning_objectives, introduction, main_content, biblical_theological_content,
                     indian_context, spotlight, something_to_ponder, ministry_application, summary,
                     review_questions, discussion_questions, further_reading)
SELECT u.id, 1, 'What Is Narrative? (demo lesson)',
 'By the end of this lesson you should be able to describe how biblical narrative communicates theology through story.',
 'Stories shape communities. This lesson introduces the narrative form of the Old Testament.',
 'Demo placeholder for the main lesson text. Production lessons are authored in the GSOL ODL template and stored here.',
 'Demo placeholder: theological significance of narrative in the biblical canon.',
 'Demo placeholder: oral storytelling traditions in India as a bridge to biblical narrative.',
 'Demo placeholder: a short spotlight on a significant narrative or interpreter.',
 'Demo placeholder: how do stories form identity in your congregation?',
 'Demo placeholder: using narrative preaching in a local church.',
 'Demo placeholder summary.',
 '["What distinguishes narrative from law and poetry?","Why does the narrator rarely state the moral?"]'::jsonb,
 '["Which story shaped your faith most, and why?"]'::jsonb,
 '["See the course reading list in the library module."]'::jsonb
FROM course_units u JOIN courses c ON c.id = u.course_id
WHERE c.code = 'OT202' AND u.unit_no = 1;

INSERT INTO lessons (unit_id, lesson_no, title, learning_objectives, summary)
SELECT u.id, n, 'Lesson ' || n || ' (demo)', 'Demo learning objectives.', 'Demo summary.'
FROM course_units u CROSS JOIN generate_series(1, 2) AS n
WHERE NOT (u.course_id = (SELECT id FROM courses WHERE code='OT202') AND u.unit_no = 1 AND n = 1);

INSERT INTO lesson_resources (lesson_id, kind, title, storage_key)
SELECT l.id, 'video', 'Lecture video — ' || l.title, 'media/lessons/' || l.id || '/lecture.mp4' FROM lessons l WHERE l.lesson_no = 1;
INSERT INTO lesson_resources (lesson_id, kind, title, storage_key)
SELECT l.id, 'download', 'Lesson handout — ' || l.title, 'media/lessons/' || l.id || '/handout.pdf' FROM lessons l;
INSERT INTO learning_activities (lesson_id, activity_type, title, est_minutes, is_graded)
SELECT l.id, a.t, a.title, a.m, a.g FROM lessons l
CROSS JOIN (VALUES ('reading','Read the lesson',40,false), ('video','Watch the lecture',20,false),
                   ('reflection','Something to Ponder',15,false), ('forum','Discussion question',20,true)) AS a(t, title, m, g);
