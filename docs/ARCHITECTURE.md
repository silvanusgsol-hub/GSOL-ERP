# GSOL ERP — Architecture (Steps 1–10 of the master prompt, condensed)

The database is the product: lifecycle rules live in PostgreSQL (constraints, triggers, functions, views), so every
client — this demo UI, a future Next.js app, Moodle sync jobs, report exports — gets identical behaviour.

## 1. System architecture
```
 Browser / mobile ──► REST API (app/server.js today; NestJS/Django later) ──► PostgreSQL 14+ (system of record)
                                   │                                              ▲
                                   ├── Moodle web services (lms_* tables, lms_sync_log) ┘
                                   └── Payment gateway · Email/SMS/WhatsApp · Library · ID verification (hooks in schema)
```
Files (documents, submissions, question papers) are referenced by `storage_key` into a private object store.

## 2. Module map → tables
| Module | Core tables |
|---|---|
| Identity & RBAC | users, roles, permissions, role_permissions, user_roles, audit_logs |
| Admissions | persons, applications, application_status_history, documents |
| Students & lifecycle | students, student_programmes, student_status_*, advising_notes, credit_transfers |
| Programmes & curriculum | programmes, departments, curricula, curriculum_courses, courses, course_prerequisites, academic_years, terms |
| ODL content | course_units, lessons, lesson activities (template, term-independent) |
| Delivery & LMS | course_offerings, course_faculty, lms_users, lms_enrollments, lms_activity, lms_sync_log, forums, attendance |
| Assessment & exams | assessments, submissions, assessment_scores, examinations, exam_registrations, exam_results, exam_centres, exam_invigilators |
| Finance | fee_types, fee_structures, fee_invoices, invoice_lines, payments, scholarships, scholarship_applications, scholarship_awards |
| Research & ministry | research_projects, research_chapters, internships, internship_reports |
| Library | library_resources, authors, publishers, library_members, library_loans |
| Communication | message_templates, communications, notification_rules, notifications |
| Completion | graduation_applications, certificates, alumni |

## 3. Lifecycle (one student record end to end)
`application → admission (fn_admit_student) → student record → programme stint → curriculum → registration
(prerequisite + capacity guard) → Moodle → assessments → grade (fn_finalize_enrollment) → progress views → fees →
graduation eligibility (fn_graduation_eligibility) → conferral trigger → certificate → alumni`

Student status transitions are data (`student_status_transitions`): an illegal jump raises an error and every change is logged.
A student can hold several `student_programmes` rows over time (Diploma → Bachelor → MA) with approved credit transfer between them.

## 4. What the database enforces (not the app)
- Prerequisites (AND across groups, OR within) and capacity at registration — `trg_enrollment_guard`
- Unique student ID / application no. / receipt no. / certificate no.; no duplicate enrolment
- Weighted gradebook → % → letter → grade point → pass/fail → credits (configurable grade scales per programme)
- Graduation = credits + required courses + CGPA + no outstanding fees + dissertation accepted
- Append-only audit log (UPDATE/DELETE/TRUNCATE blocked); audit triggers on authoritative tables
- Engagement Risk Indicator (🟢🟡🔴) tunable through `engagement_config`; retention risk is decision support only

## 5. RBAC
`role_permissions` grants resource × action (view/create/edit/delete/approve/export/publish) with a row scope
(`own` / `assigned` / `programme` / `all`); `fn_permission_scope(user, resource, action)` returns the scope for the API
to turn into a row filter. Browse the live matrix in the demo (Roles & Permissions).

## 6. API surface
Demo (read-only): `/api/dashboard /programmes /students /student /search /engagement /finance /graduation /alumni /verify /prereq /rbac /audit`.
Target production namespaces follow the master prompt (`/api/auth … /api/lms`).

## 7. Roadmap
1. Foundation (done in schema) → 2. Admissions → 3. Academic → 4. ODL/Moodle → 5. Finance → 6. Research & ministry → 7. Graduation/alumni → 8. Analytics.
Next engineering steps: authentication (argon2 + TOTP), write APIs with `SET LOCAL gsol.user_id` for audit attribution,
Next.js front end, Moodle web-service sync worker, payment-gateway webhook, nightly backup job (`pg_dump` + object-store sync).

## 8. Known gaps in this demo
No login/2FA, no write endpoints, no supplementary-exam or revaluation workflow data, no PDF/Excel export, Moodle and
payment integrations are schema hooks only, and all people/amounts are synthetic.
