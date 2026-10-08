-- =============================================================================
-- GSOL ERP demo seed 02 — staff, faculty, role assignments (all synthetic)
-- Passwords are placeholders; the demo never contains a usable credential.
-- =============================================================================

INSERT INTO users (email, password_hash, full_name, two_factor_enabled) VALUES
 ('admin@gsol.example.org',      '$argon2id$v=19$m=65536,t=3,p=4$DEMO$not-a-real-hash', 'GSOL System Administrator', true),
 ('registrar@gsol.example.org',  '$argon2id$v=19$m=65536,t=3,p=4$DEMO$not-a-real-hash', 'Rachel Joseph',            true),
 ('finance@gsol.example.org',    '$argon2id$v=19$m=65536,t=3,p=4$DEMO$not-a-real-hash', 'Daniel Raj',               true),
 ('library@gsol.example.org',    '$argon2id$v=19$m=65536,t=3,p=4$DEMO$not-a-real-hash', 'Ruth Prakash',             false),
 ('admissions@gsol.example.org', '$argon2id$v=19$m=65536,t=3,p=4$DEMO$not-a-real-hash', 'Samuel Das',              false);

INSERT INTO user_roles (user_id, role_id)
SELECT u.id, r.id FROM (VALUES
 ('admin@gsol.example.org','super_admin'), ('registrar@gsol.example.org','registrar'),
 ('finance@gsol.example.org','finance_officer'), ('library@gsol.example.org','librarian'),
 ('admissions@gsol.example.org','admissions_officer')) AS v(e, rc)
JOIN users u ON u.email = v.e JOIN roles r ON r.code = v.rc;

-- 12 faculty (names are fictional)
CREATE TABLE zz_faculty_seed (n int, full_name text, dept text, designation text, specialization text,
                              qualifications text, interests text, ministry text, status text);
INSERT INTO zz_faculty_seed VALUES
 (1,  'Dr. Anita Mathew',        'BIB', 'Professor',            'Old Testament & Hebrew',        'Ph.D. (Old Testament)',      'Pentateuch; Hebrew narrative',               '20 years in pastoral ministry and theological education', 'full_time'),
 (2,  'Dr. Rajan Thomas',        'BIB', 'Associate Professor',  'New Testament & Greek',         'Ph.D. (New Testament)',      'Luke–Acts; Pauline letters',                 'Church planting and Bible teaching',                      'full_time'),
 (3,  'Rev. Dr. Daniel Kharkongor','THC','Professor',           'Systematic Theology',           'Ph.D. (Systematic Theology)','Pneumatology; contextual theology',          'Senior pastor, Assemblies of God',                        'full_time'),
 (4,  'Dr. Priya Abraham',       'THC', 'Associate Professor',  'Church History',                'Ph.D. (Church History)',     'Christianity in India and Asia',             'Women''s ministry and discipleship',                      'full_time'),
 (5,  'Dr. Joel Immanuel',       'PMS', 'Assistant Professor',  'Missiology',                    'D.Min. (Missions)',          'Cross-cultural mission; unreached peoples',  'Missionary service in Northeast India',                   'full_time'),
 (6,  'Dr. Lalruatfela Hmar',    'BIB', 'Assistant Professor',  'Prophetic Literature',          'Ph.D. (Old Testament)',      'Hebrew prophets; shepherd imagery',          'Youth and campus ministry',                               'full_time'),
 (7,  'Dr. Esther Koshy',        'PMS', 'Associate Professor',  'Pastoral Counselling',          'Ph.D. (Pastoral Psychology)','Pastoral care; trauma-informed ministry',    'Counselling and chaplaincy',                              'full_time'),
 (8,  'Dr. Vinod Kumar Paul',    'THC', 'Assistant Professor',  'Christian Ethics',              'Ph.D. (Christian Ethics)',   'Public theology; social ethics',             'Community development',                                   'part_time'),
 (9,  'Rev. Mercy Lalrinpuii',   'PMS', 'Lecturer',             'Christian Leadership',          'M.Div.; M.A. (Leadership)',  'Servant leadership; church administration',  'Pastor and regional youth director',                      'part_time'),
 (10, 'Dr. Jonathan Rao',        'BIB', 'Assistant Professor',  'Hermeneutics & Exegesis',       'Ph.D. (Biblical Studies)',   'Biblical interpretation; exegetical method', 'Preaching and Bible translation',                         'full_time'),
 (11, 'Dr. Ruth Sangma',         'THC', 'Lecturer',             'Research Methodology',          'Ph.D. (Theology)',           'Research design; theological writing',       'Theological education by extension',                      'adjunct'),
 (12, 'Dr. Ebenezer David',      'PMS', 'Professor',            'Practical Theology',            'Ph.D. (Practical Theology)', 'Ministry formation; practicum supervision',  'Chaplaincy and church revitalisation',                    'visiting');

INSERT INTO users (email, password_hash, full_name)
SELECT 'faculty' || lpad(n::text, 2, '0') || '@gsol.example.org',
       '$argon2id$v=19$m=65536,t=3,p=4$DEMO$not-a-real-hash', full_name
FROM zz_faculty_seed ORDER BY n;

INSERT INTO faculty (user_id, faculty_no, qualifications, specialization, department_id, designation, phone,
                     research_interests, ministry_experience, employment_status, joined_on)
SELECT u.id, 'FAC-' || lpad(s.n::text, 4, '0'), s.qualifications, s.specialization, d.id, s.designation,
       '+91 98450 ' || lpad((10000 + s.n * 137)::text, 5, '0'), s.interests, s.ministry, s.status,
       DATE '2015-07-01' + (s.n * 97)
FROM zz_faculty_seed s
JOIN users u ON u.email = 'faculty' || lpad(s.n::text, 2, '0') || '@gsol.example.org'
JOIN departments d ON d.code = s.dept
ORDER BY s.n;

INSERT INTO faculty_publications (faculty_id, citation, year)
SELECT f.id, '(Demo entry) Journal article on ' || lower(f.specialization), 2022 + (f.id % 4)
FROM faculty f WHERE f.id % 2 = 1;

-- every faculty member has the faculty role; some carry extra hats
INSERT INTO user_roles (user_id, role_id)
SELECT f.user_id, r.id FROM faculty f JOIN roles r ON r.code = 'faculty';
INSERT INTO user_roles (user_id, role_id)
SELECT f.user_id, r.id FROM faculty f JOIN roles r ON r.code = 'academic_advisor'
WHERE f.faculty_no IN ('FAC-0002','FAC-0004','FAC-0006','FAC-0007','FAC-0009','FAC-0010');
INSERT INTO user_roles (user_id, role_id)
SELECT f.user_id, r.id FROM faculty f JOIN roles r ON r.code = 'dean' WHERE f.faculty_no = 'FAC-0003';
INSERT INTO user_roles (user_id, role_id)
SELECT f.user_id, r.id FROM faculty f JOIN roles r ON r.code = 'programme_coordinator'
WHERE f.faculty_no IN ('FAC-0001','FAC-0002','FAC-0004','FAC-0006');

-- library membership for staff + faculty
INSERT INTO library_members (user_id, member_no, joined_on)
SELECT u.id, 'LM-' || lpad(row_number() OVER (ORDER BY u.id)::text, 5, '0'), DATE '2023-07-01'
FROM users u;
