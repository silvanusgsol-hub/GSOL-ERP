-- =============================================================================
-- GSOL ERP — Global School of Open Learning
-- PostgreSQL 14+ schema (also runs unchanged in PGlite for local verification)
--
-- Design principle: ONE student record follows the whole lifecycle
--   application -> admission -> student -> programme -> curriculum -> registration
--   -> LMS activity -> assessment -> grade -> progress -> fees -> graduation
--   -> certificate -> alumni
-- Programmes, courses, grading, fees and workflows are DATA, not schema, so new
-- programmes can be added without any DDL change.
--
-- Sections
--   0  helpers (as-of date, number sequences, triggers)
--   1  security & RBAC
--   2  institution reference data (departments, years, terms, statuses, grade scale)
--   3  programmes, curricula, courses, prerequisites, assessment schemes
--   4  ODL content (units, lessons, forums)
--   5  people (faculty, persons, applications, students, advising)
--   6  academics (offerings, enrollments, assessments, exams, attendance)
--   7  LMS integration & engagement
--   8  finance & scholarships
--   9  library
--  10  research & ministry practicum
--  11  communication, documents
--  12  certificates, graduation, alumni, credit transfer
--  13  audit
--  14  business-rule functions & triggers
--  15  views (progress, finance, engagement, dashboards)
--  16  indexes
-- =============================================================================

-- ---------------------------------------------------------------- 0. helpers
-- "Today" for all risk/overdue logic. Production: current_date. Demo/tests can pin it:
--   SELECT set_config('gsol.as_of_date', '2026-10-07', false);
CREATE FUNCTION fn_as_of() RETURNS date LANGUAGE sql STABLE AS
$$ SELECT COALESCE(NULLIF(current_setting('gsol.as_of_date', true), '')::date, current_date) $$;

CREATE TABLE id_counters (
    prefix   text NOT NULL,
    year     int  NOT NULL,
    last_seq int  NOT NULL DEFAULT 0,
    PRIMARY KEY (prefix, year)
);

-- fn_next_number('GSOL', 2026, 4) -> 'GSOL-2026-0001'
CREATE FUNCTION fn_next_number(p_prefix text, p_year int, p_width int DEFAULT 4) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE s int;
BEGIN
    INSERT INTO id_counters (prefix, year, last_seq) VALUES (p_prefix, p_year, 1)
    ON CONFLICT (prefix, year) DO UPDATE SET last_seq = id_counters.last_seq + 1
    RETURNING last_seq INTO s;
    RETURN p_prefix || '-' || p_year || '-' || lpad(s::text, p_width, '0');
END $$;

CREATE FUNCTION fn_set_updated_at() RETURNS trigger LANGUAGE plpgsql AS
$$ BEGIN NEW.updated_at := now(); RETURN NEW; END $$;

-- ---------------------------------------------------------------- 1. security
CREATE TABLE users (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email               text NOT NULL CHECK (email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
    password_hash       text NOT NULL,                 -- argon2id/bcrypt hash only, never plaintext
    full_name           text NOT NULL,
    is_active           boolean NOT NULL DEFAULT true,
    two_factor_enabled  boolean NOT NULL DEFAULT false,
    totp_secret_enc     text,                          -- encrypted at application layer
    failed_login_count  int NOT NULL DEFAULT 0,
    locked_until        timestamptz,
    last_login_at       timestamptz,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ux_users_email ON users (lower(email));

CREATE TABLE roles (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        text NOT NULL UNIQUE,
    name        text NOT NULL,
    description text
);

CREATE TABLE permissions (
    id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    resource text NOT NULL,
    action   text NOT NULL CHECK (action IN ('view','create','edit','delete','approve','export','publish')),
    UNIQUE (resource, action)
);

-- scope narrows a permission: own record only, assigned courses/students, a programme, or everything
CREATE TABLE role_permissions (
    role_id       bigint NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    permission_id bigint NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
    scope         text NOT NULL DEFAULT 'all' CHECK (scope IN ('own','assigned','programme','all')),
    PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE user_roles (
    user_id        bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role_id        bigint NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    programme_id   bigint,                              -- optional scoping (e.g. coordinator of one programme); FK added below
    granted_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, role_id)
);

-- ---------------------------------------------------- 2. institution reference
CREATE TABLE departments (
    id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code text NOT NULL UNIQUE,
    name text NOT NULL,
    is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE academic_years (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    label      text NOT NULL UNIQUE,                   -- '2026-27'
    start_date date NOT NULL,
    end_date   date NOT NULL,
    is_current boolean NOT NULL DEFAULT false,
    CHECK (end_date > start_date)
);
CREATE UNIQUE INDEX ux_one_current_year ON academic_years (is_current) WHERE is_current;

CREATE TABLE terms (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    academic_year_id bigint NOT NULL REFERENCES academic_years(id),
    seq              int NOT NULL,                      -- global chronological order, 1..n
    name             text NOT NULL,                     -- 'Term 1'
    start_date       date NOT NULL,
    end_date         date NOT NULL,
    registration_deadline date,
    UNIQUE (academic_year_id, name),
    UNIQUE (seq),
    CHECK (end_date > start_date)
);

-- configurable student statuses + the allowed workflow between them
CREATE TABLE student_statuses (
    code        text PRIMARY KEY,
    label       text NOT NULL,
    sort_order  int NOT NULL,
    is_active_state boolean NOT NULL DEFAULT false,     -- counts as "currently studying"
    is_terminal boolean NOT NULL DEFAULT false
);
CREATE TABLE student_status_transitions (
    from_code text NOT NULL REFERENCES student_statuses(code),
    to_code   text NOT NULL REFERENCES student_statuses(code),
    PRIMARY KEY (from_code, to_code)
);

CREATE TABLE grade_scales (
    id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL UNIQUE,
    is_default boolean NOT NULL DEFAULT false
);
CREATE TABLE grade_scale_bands (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    grade_scale_id bigint NOT NULL REFERENCES grade_scales(id) ON DELETE CASCADE,
    letter      text NOT NULL,
    min_pct     numeric(5,2) NOT NULL,
    max_pct     numeric(5,2) NOT NULL,
    grade_point numeric(3,2) NOT NULL,
    is_pass     boolean NOT NULL,
    UNIQUE (grade_scale_id, letter),
    CHECK (max_pct >= min_pct AND min_pct >= 0 AND max_pct <= 100)
);

-- ------------------------------------------ 3. programmes, curricula, courses
CREATE TABLE programmes (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code                 text NOT NULL UNIQUE,
    name                 text NOT NULL,
    level                text NOT NULL CHECK (level IN ('diploma','bachelor','master','professional_master')),
    description          text,
    duration_months      int  NOT NULL CHECK (duration_months > 0),
    total_credits        numeric(6,1) NOT NULL CHECK (total_credits > 0),
    total_learning_hours int,
    admission_requirements text,
    department_id        bigint REFERENCES departments(id),
    coordinator_id       bigint,                        -- faculty.id; FK added below
    mode_of_study        text NOT NULL DEFAULT 'Open & Distance Learning',
    delivery_method      text NOT NULL DEFAULT 'Online with Moodle',
    requires_dissertation boolean NOT NULL DEFAULT false,
    min_cgpa_to_graduate numeric(3,2) NOT NULL DEFAULT 2.00,
    grade_scale_id       bigint REFERENCES grade_scales(id),
    is_active            boolean NOT NULL DEFAULT true,
    accreditation_info   text,
    handbook_url         text,
    introduced_on        date,
    revised_on           date,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE user_roles ADD FOREIGN KEY (programme_id) REFERENCES programmes(id);

CREATE TABLE curricula (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    programme_id   bigint NOT NULL REFERENCES programmes(id),
    version        text NOT NULL,                       -- 'v1', '2027-rev'
    effective_from date NOT NULL,
    effective_to   date,
    status         text NOT NULL DEFAULT 'active' CHECK (status IN ('draft','active','retired')),
    UNIQUE (programme_id, version)
);

CREATE TABLE course_categories (
    id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code text NOT NULL UNIQUE,
    name text NOT NULL
);

-- named bundles of weighted assessment types (the "assessment engine" config)
CREATE TABLE assessment_schemes (
    id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code text NOT NULL UNIQUE,
    name text NOT NULL
);
CREATE TABLE assessment_scheme_items (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    scheme_id   bigint NOT NULL REFERENCES assessment_schemes(id) ON DELETE CASCADE,
    title       text NOT NULL,
    assessment_type text NOT NULL CHECK (assessment_type IN
        ('assignment','essay','research_paper','quiz','discussion_forum','presentation','book_review',
         'biblical_exegesis','ministry_project','internship','examination','dissertation','thesis')),
    weight_pct  numeric(5,2) NOT NULL CHECK (weight_pct > 0 AND weight_pct <= 100),
    max_marks   numeric(6,2) NOT NULL DEFAULT 100 CHECK (max_marks > 0),
    due_day_offset int NOT NULL DEFAULT 0,              -- days after term start
    UNIQUE (scheme_id, title)
);

CREATE TABLE courses (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code           text NOT NULL CHECK (code ~ '^[A-Z]{2,4}[0-9]{3}$'),
    title          text NOT NULL,
    description    text,
    credits        numeric(4,1) NOT NULL CHECK (credits > 0),
    learning_hours int NOT NULL CHECK (learning_hours > 0),
    level          int  NOT NULL CHECK (level IN (100,200,300,400,500)),
    category_id    bigint REFERENCES course_categories(id),
    department_id  bigint REFERENCES departments(id),
    assessment_scheme_id bigint REFERENCES assessment_schemes(id),
    lms_course_id  text,                                -- Moodle course id (template course)
    status         text NOT NULL DEFAULT 'active' CHECK (status IN ('draft','active','retired')),
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ux_courses_code ON courses (code);

-- A course is reused across programmes; its place in each programme lives here.
CREATE TABLE curriculum_courses (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    curriculum_id bigint NOT NULL REFERENCES curricula(id) ON DELETE CASCADE,
    course_id     bigint NOT NULL REFERENCES courses(id),
    term_seq      int NOT NULL CHECK (term_seq > 0),    -- Nth term of the programme
    is_required   boolean NOT NULL DEFAULT true,
    UNIQUE (curriculum_id, course_id)
);

-- Prerequisites: AND across group_no, OR within a group_no
-- e.g. Pentateuch needs (OT101 OR OT501).
CREATE TABLE course_prerequisites (
    id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    course_id              bigint NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
    prerequisite_course_id bigint NOT NULL REFERENCES courses(id),
    group_no               int NOT NULL DEFAULT 1,
    min_grade_point        numeric(3,2) NOT NULL DEFAULT 2.00,
    UNIQUE (course_id, prerequisite_course_id),
    CHECK (course_id <> prerequisite_course_id)
);

-- ------------------------------------------------------------ 4. ODL content
-- Course -> Units -> Lessons -> Activities (template content, independent of term)
CREATE TABLE course_units (
    id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    course_id bigint NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
    unit_no  int NOT NULL,
    title    text NOT NULL,
    learning_hours int,
    UNIQUE (course_id, unit_no)
);

CREATE TABLE lessons (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    unit_id   bigint NOT NULL REFERENCES course_units(id) ON DELETE CASCADE,
    lesson_no int NOT NULL,
    title     text NOT NULL,
    learning_objectives text,
    introduction        text,
    main_content        text,
    biblical_theological_content text,
    indian_context      text,
    spotlight           text,
    something_to_ponder text,
    ministry_application text,
    summary             text,
    review_questions     jsonb NOT NULL DEFAULT '[]',
    discussion_questions jsonb NOT NULL DEFAULT '[]',
    further_reading      jsonb NOT NULL DEFAULT '[]',
    UNIQUE (unit_id, lesson_no)
);

CREATE TABLE lesson_resources (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lesson_id bigint NOT NULL REFERENCES lessons(id) ON DELETE CASCADE,
    kind      text NOT NULL CHECK (kind IN ('multimedia','download','video','audio','reading')),
    title     text NOT NULL,
    storage_key text NOT NULL
);

CREATE TABLE learning_activities (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lesson_id bigint NOT NULL REFERENCES lessons(id) ON DELETE CASCADE,
    activity_type text NOT NULL CHECK (activity_type IN ('reading','video','reflection','quiz','forum','assignment','practice')),
    title     text NOT NULL,
    est_minutes int,
    is_graded boolean NOT NULL DEFAULT false
);

-- ------------------------------------------------------------------ 5. people
CREATE TABLE faculty (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id       bigint NOT NULL UNIQUE REFERENCES users(id),
    faculty_no    text NOT NULL UNIQUE,                 -- FAC-0001
    photo_key     text,
    qualifications text,
    specialization text,
    department_id bigint REFERENCES departments(id),
    designation   text,
    phone         text,
    research_interests text,
    ministry_experience text,
    employment_status text NOT NULL DEFAULT 'full_time'
        CHECK (employment_status IN ('full_time','part_time','adjunct','visiting','retired')),
    joined_on     date,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE programmes ADD FOREIGN KEY (coordinator_id) REFERENCES faculty(id);

CREATE TABLE faculty_publications (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    faculty_id  bigint NOT NULL REFERENCES faculty(id) ON DELETE CASCADE,
    citation    text NOT NULL,
    year        int
);

-- One identity record per human who applies / studies. Never duplicated across programmes.
CREATE TABLE persons (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id       bigint UNIQUE REFERENCES users(id),
    first_name    text NOT NULL,
    middle_name   text,
    last_name     text NOT NULL,
    preferred_name text,
    gender        text CHECK (gender IN ('female','male','other','undisclosed')),
    date_of_birth date,
    nationality   text,
    photo_key     text,
    government_id_type text,
    government_id_last4 text,                           -- full number stored encrypted in the document vault
    address_line  text, city text, state text, country text, postal_code text,
    email         text NOT NULL CHECK (email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
    mobile        text CHECK (mobile ~ '^\+?[0-9][0-9 ()-]{6,18}$'),
    whatsapp      text,
    emergency_contact_name text,
    emergency_contact_phone text,
    emergency_contact_relationship text,
    -- ecclesiastical / ministry
    church_name text, denomination text, pastor_name text, church_location text,
    ministry_role text, ministry_experience_years numeric(4,1),
    ordination_status text CHECK (ordination_status IN ('none','licensed','ordained','other')),
    ministry_organization text, ministry_address text,
    -- prior education
    previous_institution text, previous_qualification text, previous_year_completed int,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ux_persons_email ON persons (lower(email));

-- admissions workflow: draft -> submitted -> under_review -> academic_review -> interview
--                      -> admitted/rejected/waitlisted -> accepted -> enrolled
CREATE TABLE applications (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_no text NOT NULL UNIQUE CHECK (application_no ~ '^APP-[0-9]{4}-[0-9]{4}$'),
    person_id      bigint NOT NULL REFERENCES persons(id),
    programme_id   bigint NOT NULL REFERENCES programmes(id),
    intake_term_id bigint NOT NULL REFERENCES terms(id),
    admission_category text NOT NULL DEFAULT 'regular'
        CHECK (admission_category IN ('regular','sponsored','transfer','scholarship','international')),
    status         text NOT NULL DEFAULT 'draft' CHECK (status IN
        ('draft','submitted','under_review','academic_review','interview','admitted','waitlisted',
         'rejected','accepted','enrolled','withdrawn')),
    personal_statement text,
    research_proposal_key text,
    submitted_at   timestamptz,
    reviewed_by    bigint REFERENCES users(id),
    decided_by     bigint REFERENCES users(id),
    decided_at     timestamptz,
    decision_notes text,
    admission_letter_key text,
    accepted_at    timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE application_status_history (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_id bigint NOT NULL REFERENCES applications(id) ON DELETE CASCADE,
    from_status    text,
    to_status      text NOT NULL,
    changed_by     bigint REFERENCES users(id),
    changed_at     timestamptz NOT NULL DEFAULT now(),
    note           text
);

CREATE TABLE students (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_no     text NOT NULL UNIQUE CHECK (student_no ~ '^GSOL-[0-9]{4}-[0-9]{4}$'),
    person_id      bigint NOT NULL UNIQUE REFERENCES persons(id),
    application_id bigint UNIQUE REFERENCES applications(id),
    status_code    text NOT NULL REFERENCES student_statuses(code),
    advisor_id     bigint REFERENCES faculty(id),
    admitted_on    date,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE student_status_history (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id  bigint NOT NULL REFERENCES students(id) ON DELETE CASCADE,
    from_code   text,
    to_code     text NOT NULL,
    changed_by  bigint,
    changed_at  timestamptz NOT NULL DEFAULT now(),
    reason      text
);

-- A student may move Diploma -> Bachelor -> MA; each stint is a student_programmes row.
CREATE TABLE student_programmes (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id     bigint NOT NULL REFERENCES students(id),
    programme_id   bigint NOT NULL REFERENCES programmes(id),
    curriculum_id  bigint NOT NULL REFERENCES curricula(id),
    start_term_id  bigint NOT NULL REFERENCES terms(id),
    admission_category text NOT NULL DEFAULT 'regular',
    status         text NOT NULL DEFAULT 'active' CHECK (status IN
        ('active','on_leave','deferred','suspended','withdrawn','completed','graduated','transferred')),
    admitted_on    date NOT NULL,
    expected_graduation_on date,
    completed_on   date,
    UNIQUE (student_id, programme_id, start_term_id)
);
-- at most one open programme per student at a time
CREATE UNIQUE INDEX ux_one_open_programme ON student_programmes (student_id)
    WHERE status IN ('active','on_leave','deferred','suspended');

CREATE TABLE advising_notes (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id  bigint NOT NULL REFERENCES students(id) ON DELETE CASCADE,
    advisor_id  bigint NOT NULL REFERENCES faculty(id),
    advised_on  date NOT NULL,
    concern     text,
    recommendation text,
    follow_up_on date,
    action_taken text
);

-- ----------------------------------------------------------- 6. academics
-- A course delivered in a specific term (the unit of enrolment & of Moodle course shells).
CREATE TABLE course_offerings (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    course_id     bigint NOT NULL REFERENCES courses(id),
    term_id       bigint NOT NULL REFERENCES terms(id),
    coordinator_id bigint REFERENCES faculty(id),
    capacity      int CHECK (capacity > 0),
    lms_course_id text,
    status        text NOT NULL DEFAULT 'open' CHECK (status IN ('planned','open','closed','completed','cancelled')),
    UNIQUE (course_id, term_id)
);

CREATE TABLE course_faculty (
    offering_id bigint NOT NULL REFERENCES course_offerings(id) ON DELETE CASCADE,
    faculty_id  bigint NOT NULL REFERENCES faculty(id),
    role        text NOT NULL DEFAULT 'instructor' CHECK (role IN ('instructor','co_instructor','tutor','moderator')),
    PRIMARY KEY (offering_id, faculty_id)
);

CREATE TABLE enrollments (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id    bigint NOT NULL REFERENCES students(id),
    student_programme_id bigint NOT NULL REFERENCES student_programmes(id),
    offering_id   bigint NOT NULL REFERENCES course_offerings(id),
    status        text NOT NULL DEFAULT 'registered' CHECK (status IN
        ('pending_approval','registered','completed','failed','dropped','withdrawn')),
    attempt_no    int NOT NULL DEFAULT 1 CHECK (attempt_no >= 1),
    registered_at timestamptz NOT NULL DEFAULT now(),
    approved_by   bigint REFERENCES users(id),
    current_pct   numeric(5,2),                         -- running weighted % (trigger-maintained)
    final_pct     numeric(5,2),
    grade_letter  text,
    grade_point   numeric(3,2),
    credits_earned numeric(4,1) NOT NULL DEFAULT 0,
    finalized_at  timestamptz,
    UNIQUE (student_id, offering_id)                    -- no duplicate enrolment
);

CREATE TABLE credit_transfers (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_programme_id bigint NOT NULL REFERENCES student_programmes(id),
    student_id    bigint NOT NULL REFERENCES students(id),
    previous_institution text NOT NULL,
    previous_course_title text NOT NULL,
    credits_claimed numeric(4,1) NOT NULL CHECK (credits_claimed > 0),
    previous_grade text,
    transcript_document_id bigint,                      -- FK to documents added below
    equivalent_course_id bigint REFERENCES courses(id),
    status        text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','partial','rejected')),
    credits_approved numeric(4,1) NOT NULL DEFAULT 0 CHECK (credits_approved >= 0),
    decided_by    bigint REFERENCES users(id),
    decided_at    timestamptz,
    CHECK (credits_approved <= credits_claimed)
);

CREATE TABLE assessments (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    offering_id bigint NOT NULL REFERENCES course_offerings(id) ON DELETE CASCADE,
    title       text NOT NULL,
    assessment_type text NOT NULL CHECK (assessment_type IN
        ('assignment','essay','research_paper','quiz','discussion_forum','presentation','book_review',
         'biblical_exegesis','ministry_project','internship','examination','dissertation','thesis')),
    weight_pct  numeric(5,2) NOT NULL CHECK (weight_pct > 0 AND weight_pct <= 100),
    max_marks   numeric(6,2) NOT NULL DEFAULT 100 CHECK (max_marks > 0),
    instructions_key text,
    rubric      jsonb,
    opens_at    timestamptz,
    due_at      timestamptz,
    allow_resubmission boolean NOT NULL DEFAULT false,
    created_by  bigint REFERENCES faculty(id),
    UNIQUE (offering_id, title)
);

CREATE TABLE submissions (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    assessment_id bigint NOT NULL REFERENCES assessments(id) ON DELETE CASCADE,
    enrollment_id bigint NOT NULL REFERENCES enrollments(id) ON DELETE CASCADE,
    attempt_no    int NOT NULL DEFAULT 1,
    submitted_at  timestamptz NOT NULL,
    storage_key   text,
    is_late       boolean NOT NULL DEFAULT false,
    status        text NOT NULL DEFAULT 'submitted' CHECK (status IN ('submitted','graded','returned','resubmit_requested')),
    UNIQUE (assessment_id, enrollment_id, attempt_no)
);

-- the gradebook: one score per student per assessment
CREATE TABLE assessment_scores (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    assessment_id bigint NOT NULL REFERENCES assessments(id) ON DELETE CASCADE,
    enrollment_id bigint NOT NULL REFERENCES enrollments(id) ON DELETE CASCADE,
    marks         numeric(6,2) NOT NULL CHECK (marks >= 0),
    feedback      text,
    source        text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','lms','exam')),
    graded_by     bigint REFERENCES faculty(id),
    graded_at     timestamptz,
    UNIQUE (assessment_id, enrollment_id)
);

CREATE TABLE exam_centres (
    id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code    text NOT NULL UNIQUE,
    name    text NOT NULL,
    city    text, state text, country text,
    is_online boolean NOT NULL DEFAULT false
);

CREATE TABLE examinations (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    assessment_id bigint NOT NULL UNIQUE REFERENCES assessments(id) ON DELETE CASCADE,
    exam_kind     text NOT NULL DEFAULT 'regular' CHECK (exam_kind IN ('regular','supplementary','revaluation')),
    mode          text NOT NULL DEFAULT 'online' CHECK (mode IN ('online','offline')),
    scheduled_start timestamptz NOT NULL,
    duration_minutes int NOT NULL CHECK (duration_minutes > 0),
    question_paper_key text,
    status        text NOT NULL DEFAULT 'scheduled' CHECK (status IN
        ('scheduled','in_progress','marking','moderation','approved','published'))
);

CREATE TABLE exam_invigilators (
    examination_id bigint NOT NULL REFERENCES examinations(id) ON DELETE CASCADE,
    exam_centre_id bigint NOT NULL REFERENCES exam_centres(id),
    faculty_id     bigint NOT NULL REFERENCES faculty(id),
    PRIMARY KEY (examination_id, exam_centre_id, faculty_id)
);

CREATE TABLE exam_registrations (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    examination_id bigint NOT NULL REFERENCES examinations(id) ON DELETE CASCADE,
    enrollment_id  bigint NOT NULL REFERENCES enrollments(id) ON DELETE CASCADE,
    exam_centre_id bigint REFERENCES exam_centres(id),
    attended       boolean,
    UNIQUE (examination_id, enrollment_id)
);

-- permanent examination record, incl. moderation & revaluation
CREATE TABLE exam_results (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    exam_registration_id bigint NOT NULL UNIQUE REFERENCES exam_registrations(id) ON DELETE CASCADE,
    raw_marks            numeric(6,2) NOT NULL CHECK (raw_marks >= 0),
    moderated_marks      numeric(6,2) CHECK (moderated_marks >= 0),
    moderated_by         bigint REFERENCES faculty(id),
    revaluation_requested boolean NOT NULL DEFAULT false,
    revaluation_marks    numeric(6,2),
    approved_by          bigint REFERENCES users(id),
    published_at         timestamptz
);

-- live-session / contact-programme / orientation attendance (ODL schools still hold some)
CREATE TABLE attendance (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    enrollment_id bigint NOT NULL REFERENCES enrollments(id) ON DELETE CASCADE,
    session_date  date NOT NULL,
    session_type  text NOT NULL DEFAULT 'live_session' CHECK (session_type IN ('live_session','contact_class','orientation','tutorial')),
    status        text NOT NULL CHECK (status IN ('present','absent','excused','late')),
    UNIQUE (enrollment_id, session_date, session_type)
);

CREATE TABLE forums (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    offering_id  bigint NOT NULL REFERENCES course_offerings(id) ON DELETE CASCADE,
    unit_id      bigint REFERENCES course_units(id),
    title        text NOT NULL,
    due_at       timestamptz,
    is_graded    boolean NOT NULL DEFAULT false
);
CREATE TABLE forum_participation (
    forum_id      bigint NOT NULL REFERENCES forums(id) ON DELETE CASCADE,
    enrollment_id bigint NOT NULL REFERENCES enrollments(id) ON DELETE CASCADE,
    posts         int NOT NULL DEFAULT 0,
    replies       int NOT NULL DEFAULT 0,
    last_post_at  timestamptz,
    PRIMARY KEY (forum_id, enrollment_id)
);

-- -------------------------------------------------- 7. LMS integration (Moodle)
-- The ERP is the system of record; Moodle is the delivery platform. These tables are
-- written by a sync job that polls Moodle web services (core_enrol_*, gradereport_*, etc.).
CREATE TABLE lms_users (
    student_id     bigint PRIMARY KEY REFERENCES students(id) ON DELETE CASCADE,
    moodle_user_id bigint NOT NULL UNIQUE,
    last_login_at  timestamptz,
    synced_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE lms_enrollments (
    enrollment_id        bigint PRIMARY KEY REFERENCES enrollments(id) ON DELETE CASCADE,
    moodle_enrollment_id bigint NOT NULL,
    moodle_course_id     bigint NOT NULL,
    last_access_at       timestamptz,
    progress_pct         numeric(5,2) NOT NULL DEFAULT 0 CHECK (progress_pct BETWEEN 0 AND 100),
    activities_completed int NOT NULL DEFAULT 0,
    activities_total     int NOT NULL DEFAULT 0,
    quiz_avg_pct         numeric(5,2),
    assignment_avg_pct   numeric(5,2),
    forum_posts          int NOT NULL DEFAULT 0,
    completed_at         timestamptz,
    lms_final_grade      numeric(5,2),
    synced_at            timestamptz NOT NULL DEFAULT now(),
    UNIQUE (moodle_enrollment_id)
);

CREATE TABLE lms_activity (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    enrollment_id bigint NOT NULL REFERENCES enrollments(id) ON DELETE CASCADE,
    activity_type text NOT NULL CHECK (activity_type IN
        ('login','course_access','lesson_complete','video_complete','quiz_attempt','assignment_submit','forum_post','exam_attempt')),
    occurred_at   timestamptz NOT NULL,
    score_pct     numeric(5,2),
    detail        jsonb
);

CREATE TABLE lms_sync_log (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at  timestamptz NOT NULL,
    finished_at timestamptz,
    direction   text NOT NULL CHECK (direction IN ('erp_to_lms','lms_to_erp')),
    entity      text NOT NULL,
    records     int NOT NULL DEFAULT 0,
    status      text NOT NULL CHECK (status IN ('ok','partial','failed')),
    error       text
);

-- single-row config for the Engagement Risk Indicator (administrators can tune it)
CREATE TABLE engagement_config (
    id                  int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    yellow_inactive_days int NOT NULL DEFAULT 10,
    red_inactive_days    int NOT NULL DEFAULT 21,
    yellow_missed        int NOT NULL DEFAULT 1,
    red_missed           int NOT NULL DEFAULT 3,
    red_failed           int NOT NULL DEFAULT 2,
    low_progress_pct     numeric(5,2) NOT NULL DEFAULT 25
);

-- ---------------------------------------------------- 8. finance & scholarships
CREATE TABLE fee_types (
    id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code text NOT NULL UNIQUE,
    name text NOT NULL
);

CREATE TABLE fee_structures (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    programme_id bigint NOT NULL REFERENCES programmes(id),
    fee_type_id  bigint NOT NULL REFERENCES fee_types(id),
    amount       numeric(12,2) NOT NULL CHECK (amount >= 0),
    currency     char(3) NOT NULL DEFAULT 'INR',
    billing_basis text NOT NULL DEFAULT 'per_term' CHECK (billing_basis IN ('one_time','per_term','per_course')),
    effective_from date NOT NULL,
    UNIQUE (programme_id, fee_type_id, effective_from)
);

CREATE TABLE scholarships (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code           text NOT NULL UNIQUE,
    name           text NOT NULL,
    eligibility_criteria text,
    award_type     text NOT NULL CHECK (award_type IN ('percentage','fixed')),
    award_value    numeric(10,2) NOT NULL CHECK (award_value > 0),
    duration_terms int,
    renewable      boolean NOT NULL DEFAULT false,
    is_active      boolean NOT NULL DEFAULT true
);

CREATE TABLE scholarship_applications (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    scholarship_id bigint NOT NULL REFERENCES scholarships(id),
    student_id     bigint NOT NULL REFERENCES students(id),
    applied_on     date NOT NULL,
    statement      text,
    status         text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','cancelled')),
    decided_by     bigint REFERENCES users(id),
    decided_on     date,
    UNIQUE (scholarship_id, student_id)
);

CREATE TABLE scholarship_awards (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_id bigint NOT NULL UNIQUE REFERENCES scholarship_applications(id),
    student_id     bigint NOT NULL REFERENCES students(id),
    scholarship_id bigint NOT NULL REFERENCES scholarships(id),
    percentage     numeric(5,2) CHECK (percentage BETWEEN 0 AND 100),
    fixed_amount   numeric(12,2) CHECK (fixed_amount >= 0),
    start_term_id  bigint NOT NULL REFERENCES terms(id),
    end_term_id    bigint REFERENCES terms(id),
    status         text NOT NULL DEFAULT 'active' CHECK (status IN ('active','renewed','completed','cancelled')),
    cancelled_reason text
);

CREATE TABLE fee_invoices (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_no    text NOT NULL UNIQUE,
    student_id    bigint NOT NULL REFERENCES students(id),
    student_programme_id bigint REFERENCES student_programmes(id),
    term_id       bigint REFERENCES terms(id),
    issued_on     date NOT NULL,
    due_on        date NOT NULL,
    gross_amount  numeric(12,2) NOT NULL CHECK (gross_amount >= 0),
    scholarship_amount numeric(12,2) NOT NULL DEFAULT 0 CHECK (scholarship_amount >= 0),
    discount_amount    numeric(12,2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    net_amount    numeric(12,2) GENERATED ALWAYS AS (gross_amount - scholarship_amount - discount_amount) STORED,
    status        text NOT NULL DEFAULT 'issued' CHECK (status IN ('draft','issued','cancelled')),
    CHECK (scholarship_amount + discount_amount <= gross_amount),
    CHECK (due_on >= issued_on)
);

CREATE TABLE invoice_lines (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_id  bigint NOT NULL REFERENCES fee_invoices(id) ON DELETE CASCADE,
    fee_type_id bigint NOT NULL REFERENCES fee_types(id),
    description text NOT NULL,
    amount      numeric(12,2) NOT NULL CHECK (amount >= 0)
);

CREATE TABLE payments (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    receipt_no    text NOT NULL UNIQUE,
    student_id    bigint REFERENCES students(id),
    application_id bigint REFERENCES applications(id),      -- application-fee payments pre-date a student record
    invoice_id    bigint REFERENCES fee_invoices(id),
    amount        numeric(12,2) NOT NULL CHECK (amount > 0),
    method        text NOT NULL CHECK (method IN ('bank_transfer','upi','online_gateway','cash','cheque','other')),
    reference     text,
    paid_on       date NOT NULL,
    recorded_by   bigint REFERENCES users(id),
    status        text NOT NULL DEFAULT 'confirmed' CHECK (status IN ('pending','confirmed','failed','refunded')),
    CHECK (student_id IS NOT NULL OR application_id IS NOT NULL)
);

-- --------------------------------------------------------------- 9. library
CREATE TABLE publishers (
    id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL UNIQUE
);
CREATE TABLE authors (
    id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL UNIQUE
);
CREATE TABLE library_categories (
    id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code text NOT NULL UNIQUE,
    name text NOT NULL
);
CREATE TABLE library_resources (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    resource_type text NOT NULL CHECK (resource_type IN ('book','ebook','journal','article','digital')),
    title        text NOT NULL,
    isbn         text CHECK (isbn IS NULL OR isbn ~ '^[0-9X-]{10,17}$'),
    publisher_id bigint REFERENCES publishers(id),
    category_id  bigint REFERENCES library_categories(id),
    publication_year int,
    copies_total int NOT NULL DEFAULT 1 CHECK (copies_total >= 0),   -- 0 allowed for pure digital
    digital_url  text,
    external_catalog_id text                                    -- hook for future external library systems
);
CREATE UNIQUE INDEX ux_library_isbn ON library_resources (isbn) WHERE isbn IS NOT NULL;
CREATE TABLE library_resource_authors (
    resource_id bigint NOT NULL REFERENCES library_resources(id) ON DELETE CASCADE,
    author_id   bigint NOT NULL REFERENCES authors(id),
    PRIMARY KEY (resource_id, author_id)
);
CREATE TABLE library_members (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id     bigint NOT NULL UNIQUE REFERENCES users(id),
    member_no   text NOT NULL UNIQUE,
    joined_on   date NOT NULL,
    status      text NOT NULL DEFAULT 'active' CHECK (status IN ('active','suspended','expired'))
);
CREATE TABLE library_loans (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    resource_id bigint NOT NULL REFERENCES library_resources(id),
    member_id   bigint NOT NULL REFERENCES library_members(id),
    borrowed_on date NOT NULL,
    due_on      date NOT NULL,
    returned_on date,
    CHECK (due_on >= borrowed_on)
);

-- ------------------------------------------- 10. research & ministry practicum
CREATE TABLE research_projects (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_programme_id bigint NOT NULL UNIQUE REFERENCES student_programmes(id),  -- one dissertation per programme stint
    topic                text NOT NULL,
    status               text NOT NULL DEFAULT 'proposal' CHECK (status IN
        ('proposal','approved','research','writing','submitted','under_review','corrections','accepted','completed')),
    supervisor_id        bigint REFERENCES faculty(id),
    co_supervisor_id     bigint REFERENCES faculty(id),
    proposal_submitted_on date,
    proposal_approved_on  date,
    ethics_approved_on    date,
    final_submitted_on    date,
    viva_on               date,
    final_grade           text,
    final_pct             numeric(5,2),
    CHECK (co_supervisor_id IS NULL OR co_supervisor_id <> supervisor_id)
);
CREATE TABLE research_chapters (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    project_id   bigint NOT NULL REFERENCES research_projects(id) ON DELETE CASCADE,
    chapter_no   int NOT NULL,
    title        text,
    submitted_on date,
    feedback     text,
    status       text NOT NULL DEFAULT 'submitted' CHECK (status IN ('submitted','feedback_given','revision_requested','accepted')),
    UNIQUE (project_id, chapter_no)
);

CREATE TABLE internships (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_programme_id bigint NOT NULL REFERENCES student_programmes(id),
    enrollment_id        bigint REFERENCES enrollments(id),
    organization         text NOT NULL,
    church               text,
    ministry_area        text NOT NULL CHECK (ministry_area IN
        ('church_ministry','missions','youth_ministry','childrens_ministry','chaplaincy','counselling',
         'evangelism','community_development','christian_education','leadership')),
    placement            text,
    supervisor_name      text NOT NULL,
    supervisor_contact   text,
    start_date           date NOT NULL,
    end_date             date,
    status               text NOT NULL DEFAULT 'ongoing' CHECK (status IN ('planned','ongoing','completed','withdrawn')),
    supervisor_evaluation text,
    student_reflection   text,
    final_evaluation     text,
    grade                text,
    CHECK (end_date IS NULL OR end_date >= start_date)
);
CREATE TABLE internship_reports (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    internship_id bigint NOT NULL REFERENCES internships(id) ON DELETE CASCADE,
    week_no       int NOT NULL,
    activities    text NOT NULL,
    hours         numeric(4,1),
    submitted_on  date,
    UNIQUE (internship_id, week_no)
);

-- ---------------------------------------------- 11. communication & documents
CREATE TABLE message_templates (
    id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code    text NOT NULL UNIQUE,
    name    text NOT NULL,
    channel text NOT NULL CHECK (channel IN ('email','sms','whatsapp','push','announcement')),
    subject text,
    body    text NOT NULL
);

CREATE TABLE communications (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    template_id   bigint REFERENCES message_templates(id),
    channel       text NOT NULL CHECK (channel IN ('email','sms','whatsapp','push','announcement')),
    audience_type text NOT NULL CHECK (audience_type IN
        ('student','programme','batch','course','faculty','department','all_students')),
    audience_ref  bigint,                             -- id in the table named by audience_type
    subject       text,
    body          text NOT NULL,
    sent_by       bigint REFERENCES users(id),
    scheduled_at  timestamptz,
    sent_at       timestamptz
);
CREATE TABLE communication_recipients (
    communication_id bigint NOT NULL REFERENCES communications(id) ON DELETE CASCADE,
    user_id          bigint NOT NULL REFERENCES users(id),
    status           text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','sent','delivered','failed','read')),
    PRIMARY KEY (communication_id, user_id)
);

-- event-driven notifications; timing is administrator-configurable
CREATE TABLE notification_rules (
    event_code   text PRIMARY KEY,                    -- 'fee_due','assignment_due',...
    template_id  bigint REFERENCES message_templates(id),
    channel      text NOT NULL DEFAULT 'email',
    offset_days  int NOT NULL DEFAULT 0,              -- negative = before the event
    is_enabled   boolean NOT NULL DEFAULT true
);
CREATE TABLE notifications (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id    bigint NOT NULL REFERENCES users(id),
    event_code text NOT NULL REFERENCES notification_rules(event_code),
    title      text NOT NULL,
    body       text,
    created_at timestamptz NOT NULL DEFAULT now(),
    read_at    timestamptz
);

CREATE TABLE documents (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    person_id     bigint REFERENCES persons(id),
    application_id bigint REFERENCES applications(id),
    student_id    bigint REFERENCES students(id),
    category      text NOT NULL CHECK (category IN
        ('identity','academic','admission','financial','ministry','examination','dissertation','graduation')),
    doc_type      text NOT NULL,                      -- 'passport_photo','church_recommendation',...
    storage_key   text NOT NULL,                      -- object-storage key (private bucket)
    version       int NOT NULL DEFAULT 1,
    uploaded_by   bigint REFERENCES users(id),
    uploaded_at   timestamptz NOT NULL DEFAULT now(),
    verification_status text NOT NULL DEFAULT 'pending' CHECK (verification_status IN ('pending','verified','rejected')),
    verified_by   bigint REFERENCES users(id),
    verified_at   timestamptz,
    CHECK (person_id IS NOT NULL OR application_id IS NOT NULL OR student_id IS NOT NULL),
    CHECK ((verification_status = 'pending') OR (verified_by IS NOT NULL AND verified_at IS NOT NULL))
);
ALTER TABLE credit_transfers ADD FOREIGN KEY (transcript_document_id) REFERENCES documents(id);

-- ------------------------------ 12. certificates, graduation, alumni
CREATE TABLE graduation_applications (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_programme_id bigint NOT NULL UNIQUE REFERENCES student_programmes(id),
    applied_on           date NOT NULL,
    eligibility_snapshot jsonb,                       -- result of fn_graduation_eligibility at time of review
    final_cgpa           numeric(4,2),
    status               text NOT NULL DEFAULT 'applied' CHECK (status IN
        ('applied','eligibility_check','pending_approval','approved','conferred','rejected')),
    approved_by          bigint REFERENCES users(id),
    approved_on          date,
    graduation_date      date
);

CREATE TABLE certificates (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    certificate_no   text NOT NULL UNIQUE,
    cert_type        text NOT NULL CHECK (cert_type IN
        ('diploma','bachelor','master_arts','master_divinity','course_completion','internship','transcript')),
    student_id       bigint NOT NULL REFERENCES students(id),
    student_programme_id bigint REFERENCES student_programmes(id),
    enrollment_id    bigint REFERENCES enrollments(id),
    issued_on        date NOT NULL,
    verification_code text NOT NULL UNIQUE,           -- opaque token embedded in QR / verification URL
    verification_url text NOT NULL,
    signatories      jsonb NOT NULL DEFAULT '[]',
    status           text NOT NULL DEFAULT 'valid' CHECK (status IN ('valid','revoked','superseded')),
    revoked_reason   text
);

CREATE TABLE alumni (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id      bigint NOT NULL REFERENCES students(id),
    student_programme_id bigint NOT NULL UNIQUE REFERENCES student_programmes(id),
    programme_id    bigint NOT NULL REFERENCES programmes(id),
    graduation_year int NOT NULL,
    current_ministry text,
    church          text,
    organization    text,
    ministry_position text,
    country         text,
    contact_email   text,
    further_studies text,
    directory_visible boolean NOT NULL DEFAULT true
);

-- ------------------------------------------------------------------ 13. audit
CREATE TABLE audit_logs (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occurred_at  timestamptz NOT NULL DEFAULT now(),
    user_id      bigint,
    action       text NOT NULL CHECK (action IN ('INSERT','UPDATE','DELETE')),
    table_name   text NOT NULL,
    record_id    text,
    ip_address   inet,
    old_values   jsonb,
    new_values   jsonb
);

-- Application sets, per request:  SET LOCAL gsol.user_id = '42';  SET LOCAL gsol.client_ip = '203.0.113.7';
CREATE FUNCTION fn_audit() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    uid bigint; ip inet; rid text;
BEGIN
    IF current_setting('gsol.audit_enabled', true) = 'off' THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    uid := NULLIF(current_setting('gsol.user_id', true), '')::bigint;
    ip  := NULLIF(current_setting('gsol.client_ip', true), '')::inet;
    IF TG_OP = 'DELETE' THEN rid := to_jsonb(OLD)->>'id'; ELSE rid := to_jsonb(NEW)->>'id'; END IF;
    INSERT INTO audit_logs (user_id, action, table_name, record_id, ip_address, old_values, new_values)
    VALUES (uid, TG_OP, TG_TABLE_NAME, rid,  ip,
            CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END,
            CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END);
    RETURN COALESCE(NEW, OLD);
END $$;

-- audit rows are append-only for everyone (production: also REVOKE UPDATE, DELETE from the app role)
CREATE FUNCTION fn_audit_immutable() RETURNS trigger LANGUAGE plpgsql AS
$$ BEGIN RAISE EXCEPTION 'audit_logs is append-only'; END $$;
CREATE TRIGGER trg_audit_immutable BEFORE UPDATE OR DELETE ON audit_logs
    FOR EACH ROW EXECUTE FUNCTION fn_audit_immutable();
CREATE TRIGGER trg_audit_no_truncate BEFORE TRUNCATE ON audit_logs
    FOR EACH STATEMENT EXECUTE FUNCTION fn_audit_immutable();

-- ----------------------------------------- 14. business-rule functions & triggers

-- Grade lookup from the programme's scale (falls back to the default scale)
CREATE FUNCTION fn_grade_for(p_pct numeric, p_scale bigint)
RETURNS TABLE (letter text, grade_point numeric, is_pass boolean) LANGUAGE sql STABLE AS $$
    SELECT b.letter, b.grade_point, b.is_pass
    FROM grade_scale_bands b
    WHERE b.grade_scale_id = COALESCE(p_scale, (SELECT id FROM grade_scales WHERE is_default LIMIT 1))
      AND p_pct >= b.min_pct AND p_pct <= b.max_pct + 0.99
    ORDER BY b.min_pct DESC
    LIMIT 1
$$;

-- Running weighted percentage over the assessments scored so far, scaled to weights attempted
CREATE FUNCTION fn_weighted_pct(p_enrollment bigint, p_only_scored boolean DEFAULT false) RETURNS numeric
LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN COALESCE(SUM(a.weight_pct), 0) = 0 THEN NULL
                ELSE ROUND(SUM(a.weight_pct * COALESCE(s.marks, 0) / a.max_marks)
                           / CASE WHEN p_only_scored THEN SUM(CASE WHEN s.id IS NOT NULL THEN a.weight_pct END)
                                  ELSE SUM(a.weight_pct) END * 100, 2) END
    FROM enrollments e
    JOIN assessments a ON a.offering_id = e.offering_id
    LEFT JOIN assessment_scores s ON s.assessment_id = a.id AND s.enrollment_id = e.id
    WHERE e.id = p_enrollment
$$;

-- Final result: percentage -> letter -> grade point -> pass/fail -> credits
CREATE FUNCTION fn_finalize_enrollment(p_enrollment bigint) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    pct numeric; scale_id bigint; g record; cr numeric;
BEGIN
    pct := fn_weighted_pct(p_enrollment, false);
    IF pct IS NULL THEN RAISE EXCEPTION 'Enrollment % has no assessments', p_enrollment; END IF;
    SELECT p.grade_scale_id, c.credits INTO scale_id, cr
    FROM enrollments e
    JOIN student_programmes sp ON sp.id = e.student_programme_id
    JOIN programmes p ON p.id = sp.programme_id
    JOIN course_offerings o ON o.id = e.offering_id
    JOIN courses c ON c.id = o.course_id
    WHERE e.id = p_enrollment;
    SELECT * INTO g FROM fn_grade_for(pct, scale_id);
    UPDATE enrollments SET
        final_pct = pct, current_pct = pct,
        grade_letter = g.letter, grade_point = g.grade_point,
        status = CASE WHEN g.is_pass THEN 'completed' ELSE 'failed' END,
        credits_earned = CASE WHEN g.is_pass THEN cr ELSE 0 END,
        finalized_at = now()
    WHERE id = p_enrollment;
END $$;

-- keep enrollments.current_pct fresh whenever a score changes
CREATE FUNCTION fn_refresh_current_pct() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE eid bigint := COALESCE(NEW.enrollment_id, OLD.enrollment_id);
BEGIN
    UPDATE enrollments SET current_pct = fn_weighted_pct(eid, true) WHERE id = eid AND finalized_at IS NULL;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_scores_refresh AFTER INSERT OR UPDATE OR DELETE ON assessment_scores
    FOR EACH ROW EXECUTE FUNCTION fn_refresh_current_pct();

-- Does the student satisfy every prerequisite group of this course? (transfer credit counts)
CREATE FUNCTION fn_prereqs_met(p_student bigint, p_course bigint) RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT NOT EXISTS (
        SELECT 1
        FROM (SELECT DISTINCT group_no FROM course_prerequisites WHERE course_id = p_course) g
        WHERE NOT EXISTS (
            SELECT 1
            FROM course_prerequisites p
            WHERE p.course_id = p_course AND p.group_no = g.group_no
              AND (
                EXISTS (SELECT 1 FROM enrollments e
                        JOIN course_offerings o ON o.id = e.offering_id
                        WHERE e.student_id = p_student AND o.course_id = p.prerequisite_course_id
                          AND e.status = 'completed' AND COALESCE(e.grade_point, 0) >= p.min_grade_point)
                OR EXISTS (SELECT 1 FROM credit_transfers t
                           WHERE t.student_id = p_student AND t.equivalent_course_id = p.prerequisite_course_id
                             AND t.status IN ('approved','partial'))
              )
        )
    )
$$;

-- Registration guard: prerequisites, curriculum membership, capacity, programme state
CREATE FUNCTION fn_enrollment_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE cid bigint; cap int; used int; code text;
BEGIN
    SELECT o.course_id, o.capacity, c.code INTO cid, cap, code
    FROM course_offerings o JOIN courses c ON c.id = o.course_id WHERE o.id = NEW.offering_id;

    IF NEW.status IN ('pending_approval','registered') THEN
        IF NOT fn_prereqs_met(NEW.student_id, cid) THEN
            RAISE EXCEPTION 'Prerequisites not completed for course % (student %)', code, NEW.student_id
                USING ERRCODE = 'check_violation';
        END IF;
        IF cap IS NOT NULL THEN
            SELECT count(*) INTO used FROM enrollments
            WHERE offering_id = NEW.offering_id AND status IN ('registered','pending_approval','completed','failed');
            IF used >= cap THEN
                RAISE EXCEPTION 'Offering % is full (capacity %)', code, cap USING ERRCODE = 'check_violation';
            END IF;
        END IF;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM student_programmes sp
                   WHERE sp.id = NEW.student_programme_id AND sp.student_id = NEW.student_id) THEN
        RAISE EXCEPTION 'student_programme % does not belong to student %', NEW.student_programme_id, NEW.student_id
            USING ERRCODE = 'check_violation';
    END IF;

    -- attempt number = previous attempts at the same course + 1
    NEW.attempt_no := 1 + (SELECT count(*) FROM enrollments e
                           JOIN course_offerings o ON o.id = e.offering_id
                           WHERE e.student_id = NEW.student_id AND o.course_id = cid);
    RETURN NEW;
END $$;
CREATE TRIGGER trg_enrollment_guard BEFORE INSERT ON enrollments
    FOR EACH ROW EXECUTE FUNCTION fn_enrollment_guard();

-- Student status workflow: only configured transitions are legal; every change is logged
CREATE FUNCTION fn_student_status_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO student_status_history (student_id, from_code, to_code, reason)
        VALUES (NEW.id, NULL, NEW.status_code, 'created');
    ELSIF NEW.status_code IS DISTINCT FROM OLD.status_code THEN
        IF NOT EXISTS (SELECT 1 FROM student_status_transitions
                       WHERE from_code = OLD.status_code AND to_code = NEW.status_code) THEN
            RAISE EXCEPTION 'Illegal student status transition % -> %', OLD.status_code, NEW.status_code
                USING ERRCODE = 'check_violation';
        END IF;
        INSERT INTO student_status_history (student_id, from_code, to_code, changed_by, reason)
        VALUES (NEW.id, OLD.status_code, NEW.status_code,
                NULLIF(current_setting('gsol.user_id', true), '')::bigint,
                NULLIF(current_setting('gsol.status_reason', true), ''));
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_student_status_ins AFTER INSERT ON students
    FOR EACH ROW EXECUTE FUNCTION fn_student_status_guard();
CREATE TRIGGER trg_student_status_upd BEFORE UPDATE OF status_code ON students
    FOR EACH ROW EXECUTE FUNCTION fn_student_status_guard();

-- Application status history written automatically
CREATE FUNCTION fn_application_history() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' OR NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO application_status_history (application_id, from_status, to_status, changed_by)
        VALUES (NEW.id, CASE WHEN TG_OP = 'UPDATE' THEN OLD.status END, NEW.status,
                NULLIF(current_setting('gsol.user_id', true), '')::bigint);
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_application_history AFTER INSERT OR UPDATE OF status ON applications
    FOR EACH ROW EXECUTE FUNCTION fn_application_history();

-- Admission accepted -> create the student record (ID generated here)
CREATE FUNCTION fn_admit_student(p_application bigint, p_advisor bigint DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE a record; sid bigint; cur bigint; t record; no text;
BEGIN
    SELECT * INTO a FROM applications WHERE id = p_application;
    IF a.status NOT IN ('admitted','accepted') THEN
        RAISE EXCEPTION 'Application % is %, not admitted/accepted', a.application_no, a.status;
    END IF;
    SELECT * INTO t FROM terms WHERE id = a.intake_term_id;
    SELECT id INTO cur FROM curricula
    WHERE programme_id = a.programme_id AND status = 'active' ORDER BY effective_from DESC LIMIT 1;
    no := fn_next_number('GSOL', EXTRACT(year FROM t.start_date)::int, 4);

    INSERT INTO students (student_no, person_id, application_id, status_code, advisor_id, admitted_on)
    VALUES (no, a.person_id, a.id, 'enrolled', p_advisor, t.start_date) RETURNING id INTO sid;

    INSERT INTO student_programmes (student_id, programme_id, curriculum_id, start_term_id,
                                    admission_category, admitted_on, expected_graduation_on)
    SELECT sid, a.programme_id, cur, a.intake_term_id, a.admission_category, t.start_date,
           (t.start_date + (p.duration_months || ' months')::interval)::date
    FROM programmes p WHERE p.id = a.programme_id;

    UPDATE applications SET status = 'enrolled' WHERE id = a.id;
    RETURN sid;
END $$;

-- Graduation eligibility = credits + required courses + CGPA + fees + dissertation. Returns a checklist.
CREATE FUNCTION fn_graduation_eligibility(p_sp bigint) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    sp record; prog record; earned numeric; transferred numeric; cgpa numeric;
    missing int; owed numeric; diss boolean; ok boolean;
BEGIN
    SELECT * INTO sp FROM student_programmes WHERE id = p_sp;
    SELECT * INTO prog FROM programmes WHERE id = sp.programme_id;

    SELECT COALESCE(SUM(credits_earned), 0) INTO earned FROM enrollments
    WHERE student_programme_id = p_sp AND status = 'completed';
    SELECT COALESCE(SUM(credits_approved), 0) INTO transferred FROM credit_transfers
    WHERE student_programme_id = p_sp AND status IN ('approved','partial');

    SELECT ROUND(SUM(x.grade_point * x.credits) / NULLIF(SUM(x.credits), 0), 2) INTO cgpa
    FROM (SELECT DISTINCT ON (o.course_id) e.grade_point, c.credits
          FROM enrollments e JOIN course_offerings o ON o.id = e.offering_id JOIN courses c ON c.id = o.course_id
          WHERE e.student_programme_id = p_sp AND e.status IN ('completed','failed')
          ORDER BY o.course_id, e.attempt_no DESC) x;

    SELECT count(*) INTO missing
    FROM curriculum_courses cc
    WHERE cc.curriculum_id = sp.curriculum_id AND cc.is_required
      AND NOT EXISTS (SELECT 1 FROM enrollments e JOIN course_offerings o ON o.id = e.offering_id
                      WHERE e.student_programme_id = p_sp AND o.course_id = cc.course_id AND e.status = 'completed')
      AND NOT EXISTS (SELECT 1 FROM credit_transfers t
                      WHERE t.student_programme_id = p_sp AND t.equivalent_course_id = cc.course_id
                        AND t.status IN ('approved','partial'));

    SELECT COALESCE(SUM(i.net_amount), 0) - COALESCE((SELECT SUM(p.amount) FROM payments p
              WHERE p.student_id = sp.student_id AND p.status = 'confirmed'), 0)
      INTO owed FROM fee_invoices i WHERE i.student_id = sp.student_id AND i.status = 'issued';

    diss := (NOT prog.requires_dissertation) OR EXISTS (
        SELECT 1 FROM research_projects r WHERE r.student_programme_id = p_sp AND r.status IN ('accepted','completed'));

    ok := (earned + transferred >= prog.total_credits) AND missing = 0
          AND COALESCE(cgpa, 0) >= prog.min_cgpa_to_graduate AND owed <= 0 AND diss;

    RETURN jsonb_build_object(
        'credits_required', prog.total_credits, 'credits_earned', earned, 'credits_transferred', transferred,
        'required_courses_missing', missing, 'cgpa', cgpa, 'min_cgpa', prog.min_cgpa_to_graduate,
        'outstanding_fees', GREATEST(owed, 0), 'dissertation_ok', diss, 'eligible', ok);
END $$;

-- Conferral -> student & programme marked graduated, alumni record created automatically
CREATE FUNCTION fn_on_graduation_conferred() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE sp record; per record;
BEGIN
    IF NEW.status = 'conferred' AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'conferred') THEN
        SELECT * INTO sp FROM student_programmes WHERE id = NEW.student_programme_id;
        UPDATE student_programmes SET status = 'graduated',
               completed_on = COALESCE(NEW.graduation_date, fn_as_of())
        WHERE id = sp.id;
        -- walk the workflow active -> completed -> graduated, but only when this was the student's
        -- last open programme (a Diploma graduate continuing into the Bachelor stays "active")
        IF NOT EXISTS (SELECT 1 FROM student_programmes x
                       WHERE x.student_id = sp.student_id AND x.id <> sp.id
                         AND x.status IN ('active','on_leave','deferred','suspended')) THEN
            UPDATE students SET status_code = 'completed' WHERE id = sp.student_id AND status_code = 'active';
            UPDATE students SET status_code = 'graduated' WHERE id = sp.student_id AND status_code = 'completed';
        END IF;
        SELECT p.email, p.country, p.church_name, p.ministry_organization, p.ministry_role INTO per
        FROM students s JOIN persons p ON p.id = s.person_id WHERE s.id = sp.student_id;
        INSERT INTO alumni (student_id, student_programme_id, programme_id, graduation_year,
                            current_ministry, church, organization, ministry_position, country, contact_email)
        VALUES (sp.student_id, sp.id, sp.programme_id,
                EXTRACT(year FROM COALESCE(NEW.graduation_date, fn_as_of()))::int,
                per.ministry_role, per.church_name, per.ministry_organization, per.ministry_role,
                per.country, per.email)
        ON CONFLICT (student_programme_id) DO NOTHING;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_graduation_conferred AFTER INSERT OR UPDATE OF status ON graduation_applications
    FOR EACH ROW EXECUTE FUNCTION fn_on_graduation_conferred();

-- scheduled job hook: graduated -> alumni after a grace period
CREATE FUNCTION fn_promote_graduates_to_alumni(p_grace_days int DEFAULT 30) RETURNS int LANGUAGE plpgsql AS $$
DECLARE n int;
BEGIN
    UPDATE students s SET status_code = 'alumni'
    WHERE s.status_code = 'graduated'
      AND EXISTS (SELECT 1 FROM student_programmes sp
                  WHERE sp.student_id = s.id AND sp.status = 'graduated'
                    AND sp.completed_on <= fn_as_of() - p_grace_days);
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;

-- RBAC check used by the API layer (scope is returned so the API can add row filters)
CREATE FUNCTION fn_permission_scope(p_user bigint, p_resource text, p_action text) RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT CASE MAX(CASE rp.scope WHEN 'all' THEN 4 WHEN 'programme' THEN 3 WHEN 'assigned' THEN 2 WHEN 'own' THEN 1 END)
                WHEN 4 THEN 'all' WHEN 3 THEN 'programme' WHEN 2 THEN 'assigned' WHEN 1 THEN 'own' END
    FROM user_roles ur
    JOIN role_permissions rp ON rp.role_id = ur.role_id
    JOIN permissions pm ON pm.id = rp.permission_id
    WHERE ur.user_id = p_user AND pm.resource = p_resource AND pm.action = p_action
$$;

-- Global search over students, courses, faculty, applications, receipts, certificates, dissertations
CREATE FUNCTION fn_global_search(p_q text, p_limit int DEFAULT 25)
RETURNS TABLE (entity text, entity_id bigint, label text, detail text) LANGUAGE sql STABLE AS $$
    WITH q AS (SELECT '%' || lower(trim(p_q)) || '%' AS pat)
    SELECT * FROM (
        SELECT 'student', s.id, s.student_no || ' — ' || pr.first_name || ' ' || pr.last_name, pr.email
        FROM students s JOIN persons pr ON pr.id = s.person_id, q
        WHERE lower(s.student_no || ' ' || pr.first_name || ' ' || pr.last_name || ' ' || pr.email) LIKE q.pat
        UNION ALL
        SELECT 'course', c.id, c.code || ' — ' || c.title, 'credits ' || c.credits FROM courses c, q
        WHERE lower(c.code || ' ' || c.title) LIKE q.pat
        UNION ALL
        SELECT 'programme', p.id, p.code || ' — ' || p.name, p.level FROM programmes p, q
        WHERE lower(p.code || ' ' || p.name) LIKE q.pat
        UNION ALL
        SELECT 'faculty', f.id, f.faculty_no || ' — ' || u.full_name, f.specialization FROM faculty f JOIN users u ON u.id = f.user_id, q
        WHERE lower(f.faculty_no || ' ' || u.full_name || ' ' || COALESCE(f.specialization, '')) LIKE q.pat
        UNION ALL
        SELECT 'application', a.id, a.application_no, a.status FROM applications a, q WHERE lower(a.application_no) LIKE q.pat
        UNION ALL
        SELECT 'payment', p.id, p.receipt_no, p.amount::text FROM payments p, q WHERE lower(p.receipt_no) LIKE q.pat
        UNION ALL
        SELECT 'certificate', c.id, c.certificate_no, c.cert_type FROM certificates c, q WHERE lower(c.certificate_no) LIKE q.pat
        UNION ALL
        SELECT 'dissertation', r.id, r.topic, r.status FROM research_projects r, q WHERE lower(r.topic) LIKE q.pat
    ) x(entity, entity_id, label, detail)
    LIMIT p_limit
$$;

-- ------------------------------------------------------------------ 15. views

-- Per programme stint: credits, CGPA (latest attempt per course), completion %, outstanding courses
CREATE VIEW v_student_progress AS
WITH latest AS (
    SELECT DISTINCT ON (e.student_programme_id, o.course_id)
           e.student_programme_id, o.course_id, e.status, e.grade_point, e.credits_earned, c.credits
    FROM enrollments e
    JOIN course_offerings o ON o.id = e.offering_id
    JOIN courses c ON c.id = o.course_id
    ORDER BY e.student_programme_id, o.course_id, e.attempt_no DESC
), agg AS (
    SELECT student_programme_id,
           COUNT(*) FILTER (WHERE status = 'completed')               AS courses_completed,
           COUNT(*) FILTER (WHERE status IN ('registered','pending_approval')) AS courses_in_progress,
           COUNT(*) FILTER (WHERE status = 'failed')                  AS courses_failed,
           SUM(credits_earned)                                        AS credits_earned,
           ROUND(SUM(grade_point * credits) FILTER (WHERE status IN ('completed','failed'))
                 / NULLIF(SUM(credits) FILTER (WHERE status IN ('completed','failed')), 0), 2) AS cgpa
    FROM latest GROUP BY student_programme_id
), retakes AS (
    SELECT e.student_programme_id, COUNT(*) AS repeated_courses
    FROM enrollments e WHERE e.attempt_no > 1 GROUP BY e.student_programme_id
), xfer AS (
    SELECT student_programme_id, SUM(credits_approved) AS credits_transferred
    FROM credit_transfers WHERE status IN ('approved','partial') GROUP BY student_programme_id
)
SELECT sp.id AS student_programme_id, s.id AS student_id, s.student_no,
       pr.first_name || ' ' || pr.last_name AS student_name,
       p.id AS programme_id, p.code AS programme_code, p.name AS programme_name,
       sp.status AS programme_status, s.status_code AS student_status,
       p.total_credits AS credits_required,
       COALESCE(a.credits_earned, 0) AS credits_earned,
       COALESCE(x.credits_transferred, 0) AS credits_transferred,
       GREATEST(p.total_credits - COALESCE(a.credits_earned, 0) - COALESCE(x.credits_transferred, 0), 0) AS credits_remaining,
       ROUND(LEAST((COALESCE(a.credits_earned, 0) + COALESCE(x.credits_transferred, 0)) / p.total_credits * 100, 100), 1) AS completion_pct,
       COALESCE(a.courses_completed, 0) AS courses_completed,
       COALESCE(a.courses_in_progress, 0) AS courses_in_progress,
       COALESCE(a.courses_failed, 0) AS courses_failed,
       COALESCE(r.repeated_courses, 0) AS repeated_courses,
       a.cgpa
FROM student_programmes sp
JOIN students s ON s.id = sp.student_id
JOIN persons pr ON pr.id = s.person_id
JOIN programmes p ON p.id = sp.programme_id
LEFT JOIN agg a ON a.student_programme_id = sp.id
LEFT JOIN retakes r ON r.student_programme_id = sp.id
LEFT JOIN xfer x ON x.student_programme_id = sp.id;

-- Semester GPA
CREATE VIEW v_semester_gpa AS
SELECT e.student_id, t.id AS term_id, t.seq AS term_seq, ay.label || ' ' || t.name AS term_label,
       ROUND(SUM(e.grade_point * c.credits) / NULLIF(SUM(c.credits), 0), 2) AS semester_gpa,
       SUM(c.credits) AS credits_attempted
FROM enrollments e
JOIN course_offerings o ON o.id = e.offering_id
JOIN courses c ON c.id = o.course_id
JOIN terms t ON t.id = o.term_id
JOIN academic_years ay ON ay.id = t.academic_year_id
WHERE e.status IN ('completed','failed')
GROUP BY e.student_id, t.id, t.seq, ay.label, t.name;

-- Student finance dashboard: total fee, scholarship, discount, paid, outstanding, overdue
CREATE VIEW v_student_finance AS
WITH inv AS (
    SELECT student_id, SUM(gross_amount) AS gross, SUM(scholarship_amount) AS scholarship,
           SUM(discount_amount) AS discount, SUM(net_amount) AS net,
           SUM(CASE WHEN due_on < fn_as_of() THEN net_amount ELSE 0 END) AS net_due_to_date
    FROM fee_invoices WHERE status = 'issued' GROUP BY student_id
), pay AS (
    SELECT student_id, SUM(amount) AS paid FROM payments
    WHERE status = 'confirmed' AND student_id IS NOT NULL GROUP BY student_id
)
SELECT s.id AS student_id, s.student_no,
       COALESCE(i.gross, 0) AS total_fee, COALESCE(i.scholarship, 0) AS scholarship,
       COALESCE(i.discount, 0) AS discount, COALESCE(i.net, 0) AS net_payable,
       COALESCE(p.paid, 0) AS amount_paid,
       COALESCE(i.net, 0) - COALESCE(p.paid, 0) AS outstanding_balance,
       GREATEST(COALESCE(i.net_due_to_date, 0) - COALESCE(p.paid, 0), 0) AS overdue_amount
FROM students s LEFT JOIN inv i ON i.student_id = s.id LEFT JOIN pay p ON p.student_id = s.id;

-- Engagement Risk Indicator (current term enrolments). Green / Yellow / Red, tunable via engagement_config.
CREATE VIEW v_engagement_risk AS
WITH cur AS (
    SELECT id FROM terms WHERE fn_as_of() BETWEEN start_date AND end_date LIMIT 1
), base AS (
    SELECT e.id AS enrollment_id, e.student_id, o.course_id, le.progress_pct,
           (fn_as_of() - COALESCE(le.last_access_at::date, e.registered_at::date)) AS days_inactive,
           (SELECT count(*) FROM assessments a
            WHERE a.offering_id = e.offering_id AND a.due_at::date < fn_as_of() AND a.assessment_type <> 'examination'
              AND NOT EXISTS (SELECT 1 FROM assessment_scores s WHERE s.assessment_id = a.id AND s.enrollment_id = e.id)
              AND NOT EXISTS (SELECT 1 FROM submissions su WHERE su.assessment_id = a.id AND su.enrollment_id = e.id)
           ) AS missed_assessments,
           (SELECT count(*) FROM assessment_scores s JOIN assessments a ON a.id = s.assessment_id
            WHERE s.enrollment_id = e.id AND s.marks / a.max_marks < 0.5) AS failed_assessments
    FROM enrollments e
    JOIN course_offerings o ON o.id = e.offering_id
    LEFT JOIN lms_enrollments le ON le.enrollment_id = e.id
    WHERE e.status = 'registered' AND o.term_id = (SELECT id FROM cur)
)
SELECT b.*, CASE
         WHEN b.days_inactive >= c.red_inactive_days OR b.missed_assessments >= c.red_missed OR b.failed_assessments >= c.red_failed THEN 'red'
         WHEN b.days_inactive >= c.yellow_inactive_days OR b.missed_assessments >= c.yellow_missed
              OR COALESCE(b.progress_pct, 0) < c.low_progress_pct THEN 'yellow'
         ELSE 'green' END AS risk_level
FROM base b CROSS JOIN engagement_config c;

-- Student-level decision-support flag (never an automatic academic decision)
CREATE VIEW v_student_risk AS
SELECT s.id AS student_id, s.student_no, pr.first_name || ' ' || pr.last_name AS student_name,
       sp.programme_id,
       COALESCE(w.worst, 'green') AS engagement,
       vp.cgpa, vp.courses_failed, f.overdue_amount,
       (CASE COALESCE(w.worst, 'green') WHEN 'red' THEN 2 WHEN 'yellow' THEN 1 ELSE 0 END
        + CASE WHEN vp.cgpa IS NOT NULL AND vp.cgpa < 2.5 THEN 1 ELSE 0 END
        + CASE WHEN vp.courses_failed >= 2 THEN 1 ELSE 0 END
        + CASE WHEN f.overdue_amount > 0 THEN 1 ELSE 0 END) AS risk_points,
       CASE WHEN (CASE COALESCE(w.worst, 'green') WHEN 'red' THEN 2 WHEN 'yellow' THEN 1 ELSE 0 END
                  + CASE WHEN vp.cgpa IS NOT NULL AND vp.cgpa < 2.5 THEN 1 ELSE 0 END
                  + CASE WHEN vp.courses_failed >= 2 THEN 1 ELSE 0 END
                  + CASE WHEN f.overdue_amount > 0 THEN 1 ELSE 0 END) >= 3 THEN 'red'
            WHEN (CASE COALESCE(w.worst, 'green') WHEN 'red' THEN 2 WHEN 'yellow' THEN 1 ELSE 0 END
                  + CASE WHEN vp.cgpa IS NOT NULL AND vp.cgpa < 2.5 THEN 1 ELSE 0 END
                  + CASE WHEN vp.courses_failed >= 2 THEN 1 ELSE 0 END
                  + CASE WHEN f.overdue_amount > 0 THEN 1 ELSE 0 END) >= 1 THEN 'yellow'
            ELSE 'green' END AS retention_risk
FROM students s
JOIN persons pr ON pr.id = s.person_id
JOIN student_programmes sp ON sp.student_id = s.id AND sp.status = 'active'
JOIN v_student_progress vp ON vp.student_programme_id = sp.id
JOIN v_student_finance f ON f.student_id = s.id
LEFT JOIN (SELECT student_id,
                  CASE WHEN bool_or(risk_level = 'red') THEN 'red' WHEN bool_or(risk_level = 'yellow') THEN 'yellow' ELSE 'green' END AS worst
           FROM v_engagement_risk GROUP BY student_id) w ON w.student_id = s.id;

-- Programme dashboard (Section 30)
CREATE VIEW v_programme_dashboard AS
SELECT p.id AS programme_id, p.code, p.name, p.level,
       COUNT(DISTINCT sp.student_id) AS total_students,
       COUNT(DISTINCT sp.student_id) FILTER (WHERE sp.status = 'active') AS active_students,
       COUNT(DISTINCT sp.student_id) FILTER (WHERE sp.start_term_id = (SELECT id FROM terms WHERE fn_as_of() BETWEEN start_date AND end_date)) AS new_students,
       COUNT(DISTINCT sp.student_id) FILTER (WHERE sp.status = 'graduated') AS graduates,
       ROUND(AVG(vp.cgpa), 2) AS average_cgpa,
       (SELECT count(*) FROM v_student_risk r WHERE r.programme_id = p.id AND r.retention_risk = 'red') AS at_risk_students,
       (SELECT count(*) FROM curriculum_courses cc JOIN curricula cu ON cu.id = cc.curriculum_id
         WHERE cu.programme_id = p.id AND cu.status = 'active') AS courses
FROM programmes p
LEFT JOIN student_programmes sp ON sp.programme_id = p.id
LEFT JOIN v_student_progress vp ON vp.student_programme_id = sp.id
GROUP BY p.id, p.code, p.name, p.level;

-- ---------------------------------------------------------------- 16. indexes
CREATE INDEX ix_students_status      ON students (status_code);
CREATE INDEX ix_students_advisor     ON students (advisor_id);
CREATE INDEX ix_persons_name         ON persons (lower(last_name), lower(first_name));
CREATE INDEX ix_sp_programme         ON student_programmes (programme_id, status);
CREATE INDEX ix_sp_start_term        ON student_programmes (start_term_id);
CREATE INDEX ix_applications_status  ON applications (status, programme_id);
CREATE INDEX ix_enroll_offering      ON enrollments (offering_id, status);
CREATE INDEX ix_enroll_sp            ON enrollments (student_programme_id);
CREATE INDEX ix_offering_term        ON course_offerings (term_id);
CREATE INDEX ix_assess_offering      ON assessments (offering_id);
CREATE INDEX ix_scores_enrollment    ON assessment_scores (enrollment_id);
CREATE INDEX ix_submissions_enroll   ON submissions (enrollment_id);
CREATE INDEX ix_lms_activity_enroll  ON lms_activity (enrollment_id, occurred_at DESC);
CREATE INDEX ix_invoices_student     ON fee_invoices (student_id, due_on);
CREATE INDEX ix_payments_student     ON payments (student_id, paid_on);
CREATE INDEX ix_payments_invoice     ON payments (invoice_id);
CREATE INDEX ix_documents_owner      ON documents (student_id, category);
CREATE INDEX ix_certificates_student ON certificates (student_id);
CREATE INDEX ix_alumni_year          ON alumni (graduation_year, programme_id);
CREATE INDEX ix_audit_table_record   ON audit_logs (table_name, record_id, occurred_at DESC);
CREATE INDEX ix_audit_user           ON audit_logs (user_id, occurred_at DESC);
CREATE INDEX ix_loans_open           ON library_loans (member_id) WHERE returned_on IS NULL;
CREATE INDEX ix_curriculum_courses   ON curriculum_courses (course_id);
CREATE INDEX ix_prereq_course        ON course_prerequisites (course_id, group_no);

-- ------------------------------------------- attach generic triggers to tables
DO $$
DECLARE r record;
BEGIN
    -- updated_at maintenance on every table that has the column
    FOR r IN SELECT table_name FROM information_schema.columns
             WHERE table_schema = 'public' AND column_name = 'updated_at'
               AND table_name IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP
        EXECUTE format('CREATE TRIGGER trg_%s_updated BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at()',
                       r.table_name, r.table_name);
    END LOOP;
    -- audit trail on the sensitive / authoritative tables
    FOR r IN SELECT unnest(ARRAY[
        'users','user_roles','role_permissions','programmes','courses','persons','applications','students',
        'student_programmes','enrollments','assessment_scores','exam_results','fee_invoices','payments',
        'scholarship_awards','credit_transfers','certificates','graduation_applications','research_projects',
        'documents']) AS t LOOP
        EXECUTE format('CREATE TRIGGER trg_%s_audit AFTER INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION fn_audit()',
                       r.t, r.t);
    END LOOP;
END $$;

-- --------------------------------------------------- table descriptions (data dictionary)
COMMENT ON TABLE users IS 'Login identities for every actor (staff, faculty, students, applicants). Password hashes only.';
COMMENT ON TABLE roles IS 'RBAC roles: super_admin, registrar, dean, programme_coordinator, faculty, academic_advisor, finance_officer, librarian, student, applicant.';
COMMENT ON TABLE permissions IS 'resource x action catalogue (view/create/edit/delete/approve/export/publish).';
COMMENT ON TABLE role_permissions IS 'Grants a permission to a role with a row scope (own/assigned/programme/all).';
COMMENT ON TABLE programmes IS 'Academic programmes (Diploma, Bachelor, Master). New programmes are rows, not schema changes.';
COMMENT ON TABLE curricula IS 'Versioned curriculum of a programme; students are pinned to the version they entered on.';
COMMENT ON TABLE courses IS 'Reusable course definitions shared by many programmes.';
COMMENT ON TABLE curriculum_courses IS 'Places a course in a programme curriculum at a given term sequence.';
COMMENT ON TABLE course_prerequisites IS 'Prerequisites: AND across group_no, OR within a group.';
COMMENT ON TABLE assessment_schemes IS 'Reusable weighted assessment structures copied into each offering.';
COMMENT ON TABLE course_units IS 'ODL structure: course -> units.';
COMMENT ON TABLE lessons IS 'ODL structure: unit -> lessons with the GSOL lesson template fields (objectives, Indian Context, Spotlight, Something to Ponder, Ministry Application ...).';
COMMENT ON TABLE persons IS 'Single identity record per human (applicant, student, alumnus). Includes ecclesiastical/ministry profile.';
COMMENT ON TABLE applications IS 'Admission applications and their workflow status.';
COMMENT ON TABLE students IS 'Institutional student record keyed by GSOL-YYYY-NNNN; follows the person through the whole lifecycle.';
COMMENT ON TABLE student_programmes IS 'A student''s stint in a programme (supports Diploma -> Bachelor -> MA progression).';
COMMENT ON TABLE course_offerings IS 'A course delivered in a specific term; unit of enrolment and of Moodle course shells.';
COMMENT ON TABLE enrollments IS 'Course registration + final grade for one student in one offering.';
COMMENT ON TABLE assessments IS 'Weighted assessment items for an offering.';
COMMENT ON TABLE assessment_scores IS 'Gradebook: one score per student per assessment.';
COMMENT ON TABLE examinations IS 'Scheduled examinations (online/offline, supplementary, revaluation).';
COMMENT ON TABLE exam_results IS 'Permanent examination record incl. moderation and revaluation.';
COMMENT ON TABLE lms_enrollments IS 'Moodle sync: progress, completion, scores per enrolment. ERP stays system of record.';
COMMENT ON TABLE lms_activity IS 'Moodle sync: raw engagement events (logins, lesson/video completion, quiz attempts, forum posts).';
COMMENT ON TABLE fee_invoices IS 'Fee invoices; net_amount = gross - scholarship - discount.';
COMMENT ON TABLE payments IS 'Receipts for money received (application fees may precede a student record).';
COMMENT ON TABLE research_projects IS 'Dissertation / thesis lifecycle: proposal -> ethics -> chapters -> viva -> completion.';
COMMENT ON TABLE internships IS 'Ministry practicum / internship placements.';
COMMENT ON TABLE documents IS 'Student/applicant document vault metadata (files live in private object storage).';
COMMENT ON TABLE certificates IS 'Certificates & transcripts with public verification code (QR/URL).';
COMMENT ON TABLE graduation_applications IS 'Graduation workflow; conferral triggers alumni creation.';
COMMENT ON TABLE alumni IS 'Alumni directory, created automatically at conferral.';
COMMENT ON TABLE audit_logs IS 'Append-only audit trail (who/what/when/IP/old/new).';
