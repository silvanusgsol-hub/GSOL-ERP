// GSOL ERP — demo API (read-only) + static dashboard.
// Every figure comes straight from the PostgreSQL schema (views, functions, constraints);
// no business logic is duplicated here. Run:  PGHOST=/tmp PGPORT=5433 PGUSER=postgres PGDATABASE=gsol node server.js
import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import pg from 'pg';

const pool = new pg.Pool({
  max: 6,
  ssl: { rejectUnauthorized: false }
});
const PUBLIC = path.join(path.dirname(fileURLToPath(import.meta.url)), 'public');
const q = async (sql, params = []) => (await pool.query(sql, params)).rows;
const one = async (sql, params = []) => (await q(sql, params))[0] ?? null;
const num = (r) => JSON.parse(JSON.stringify(r, (k, v) => (typeof v === 'string' && /^-?\d+(\.\d+)?$/.test(v) && k !== 'student_no' && k !== 'code' ? Number(v) : v)));

const routes = {
  '/api/dashboard': async () => {
    const [k] = await q(`
      SELECT (SELECT count(*) FROM students) AS total_students,
             (SELECT count(*) FROM students WHERE status_code = 'active') AS active_students,
             (SELECT count(*) FROM student_programmes sp JOIN terms t ON t.id = sp.start_term_id
                WHERE fn_as_of() BETWEEN t.start_date AND t.end_date) AS new_admissions,
             (SELECT count(*) FROM applications WHERE status NOT IN ('draft','enrolled')) AS open_applications,
             (SELECT count(*) FROM graduation_applications WHERE status IN ('applied','eligibility_check','pending_approval')) AS graduating,
             (SELECT count(*) FROM faculty) AS faculty,
             (SELECT count(*) FROM programmes WHERE is_active) AS programmes,
             (SELECT COALESCE(sum(amount),0) FROM payments WHERE status = 'confirmed') AS revenue,
             (SELECT COALESCE(sum(GREATEST(outstanding_balance,0)),0) FROM v_student_finance) AS outstanding_fees,
             (SELECT ROUND(100.0 * count(*) FILTER (WHERE status <> 'withdrawn') / count(*), 1) FROM student_programmes) AS retention_pct,
             (SELECT ROUND(100.0 * count(*) FILTER (WHERE status = 'graduated') /
                      NULLIF(count(*) FILTER (WHERE status IN ('graduated','withdrawn')) , 0), 1) FROM student_programmes) AS completion_pct`);
    const byProgramme = await q(`SELECT p.code, p.name, count(*) FILTER (WHERE sp.status = 'active') AS active,
                                        count(*) FILTER (WHERE sp.status = 'graduated') AS graduated,
                                        count(*) FILTER (WHERE sp.status = 'withdrawn') AS withdrawn
                                 FROM programmes p LEFT JOIN student_programmes sp ON sp.programme_id = p.id GROUP BY p.id ORDER BY p.id`);
    const byYear = await q(`SELECT ay.label AS label, count(*) AS n FROM student_programmes sp JOIN terms t ON t.id = sp.start_term_id
                            JOIN academic_years ay ON ay.id = t.academic_year_id GROUP BY ay.label ORDER BY ay.label`);
    const geo = await q(`SELECT COALESCE(NULLIF(pe.state,''), pe.country) AS label, count(*) AS n
                         FROM students s JOIN persons pe ON pe.id = s.person_id GROUP BY 1 ORDER BY 2 DESC LIMIT 10`);
    const fees = await q(`SELECT 'T' || t.seq || ' ' || ay.label AS label, sum(i.net_amount) AS invoiced,
                                 COALESCE(sum((SELECT sum(p.amount) FROM payments p WHERE p.invoice_id = i.id AND p.status = 'confirmed')),0) AS collected
                          FROM fee_invoices i JOIN terms t ON t.id = i.term_id JOIN academic_years ay ON ay.id = t.academic_year_id
                          GROUP BY t.seq, ay.label ORDER BY t.seq`);
    const gradTrend = await q(`SELECT graduation_year AS label, count(*) AS n FROM alumni GROUP BY 1 ORDER BY 1`);
    const grades = await q(`SELECT grade_letter AS label, count(*) AS n FROM enrollments WHERE grade_letter IS NOT NULL GROUP BY 1 ORDER BY 1`);
    const risk = await q(`SELECT retention_risk AS label, count(*) AS n FROM v_student_risk GROUP BY 1`);
    const asOf = (await one(`SELECT fn_as_of()::text AS d`)).d;
    return num({ asOf, kpis: k, byProgramme, byYear, geo, fees, gradTrend, grades, risk });
  },

  '/api/programmes': async () => num(await q(`SELECT d.*, (SELECT count(*) FROM faculty f WHERE f.department_id = p.department_id) AS faculty,
        (SELECT COALESCE(sum(GREATEST(f.outstanding_balance,0)),0) FROM student_programmes sp JOIN v_student_finance f ON f.student_id = sp.student_id
          WHERE sp.programme_id = p.id AND sp.status = 'active') AS outstanding_fees,
        p.total_credits, p.duration_months, p.mode_of_study
        FROM v_programme_dashboard d JOIN programmes p ON p.id = d.programme_id ORDER BY d.programme_id`)),

  '/api/students': async (u) => {
    const s = u.searchParams, like = `%${(s.get('q') || '').toLowerCase()}%`;
    return num(await q(`
      SELECT s.id, s.student_no, pe.first_name || ' ' || pe.last_name AS name, s.status_code, pr.code AS programme,
             vp.completion_pct, vp.cgpa, COALESCE(r.retention_risk, '-') AS risk
      FROM students s JOIN persons pe ON pe.id = s.person_id
      LEFT JOIN student_programmes sp ON sp.id = (SELECT id FROM student_programmes WHERE student_id = s.id ORDER BY id DESC LIMIT 1)
      LEFT JOIN programmes pr ON pr.id = sp.programme_id
      LEFT JOIN v_student_progress vp ON vp.student_programme_id = sp.id
      LEFT JOIN LATERAL (SELECT retention_risk FROM v_student_risk x WHERE x.student_id = s.id) r ON true
      WHERE (lower(pe.first_name || ' ' || pe.last_name) LIKE $1 OR lower(s.student_no) LIKE $1)
        AND ($2 = '' OR pr.code = $2) AND ($3 = '' OR s.status_code = $3)
      ORDER BY s.id LIMIT 60`, [like, s.get('programme') || '', s.get('status') || '']));
  },

  '/api/student': async (u) => {
    const id = Number(u.searchParams.get('id'));
    const st = await one(`SELECT s.id, s.student_no, s.status_code, s.admitted_on, pe.first_name, pe.last_name, pe.email, pe.country, pe.state,
                                 pe.church_name, pe.denomination, pe.ministry_role, ad_u.full_name AS advisor
                          FROM students s JOIN persons pe ON pe.id = s.person_id
                          LEFT JOIN faculty ad ON ad.id = s.advisor_id LEFT JOIN users ad_u ON ad_u.id = ad.user_id WHERE s.id = $1`, [id]);
    if (!st) return { error: 'not found' };
    const progress = await q(`SELECT vp.*, fn_graduation_eligibility(vp.student_programme_id) AS eligibility
                              FROM v_student_progress vp WHERE student_id = $1 ORDER BY student_programme_id`, [id]);
    const courses = await q(`SELECT c.code, c.title, 'T' || t.seq AS term, ay.label AS year, e.status, e.final_pct, e.current_pct, e.grade_letter,
                                    le.progress_pct, er.risk_level
                             FROM enrollments e JOIN course_offerings o ON o.id = e.offering_id JOIN courses c ON c.id = o.course_id
                             JOIN terms t ON t.id = o.term_id JOIN academic_years ay ON ay.id = t.academic_year_id
                             LEFT JOIN lms_enrollments le ON le.enrollment_id = e.id LEFT JOIN v_engagement_risk er ON er.enrollment_id = e.id
                             WHERE e.student_id = $1 ORDER BY t.seq, c.code`, [id]);
    const finance = await one(`SELECT * FROM v_student_finance WHERE student_id = $1`, [id]);
    const gpa = await q(`SELECT term_label, semester_gpa, credits_attempted FROM v_semester_gpa WHERE student_id = $1 ORDER BY term_seq`, [id]);
    const certs = await q(`SELECT certificate_no, cert_type, issued_on, verification_code FROM certificates WHERE student_id = $1 ORDER BY issued_on`, [id]);
    const history = await q(`SELECT from_code, to_code, changed_at::date AS on FROM student_status_history WHERE student_id = $1 ORDER BY changed_at, id`, [id]);
    return num({ student: st, progress, courses, finance, gpa, certs, history });
  },

  '/api/search': async (u) => num(await q(`SELECT * FROM fn_global_search($1, 25)`, [u.searchParams.get('q') || ''])),

  '/api/engagement': async () => {
    const summary = await q(`SELECT risk_level AS label, count(*) AS n FROM v_engagement_risk GROUP BY 1`);
    const rows = await q(`SELECT er.student_id, s.student_no, pe.first_name || ' ' || pe.last_name AS name, c.code, c.title,
                                 er.progress_pct, er.days_inactive, er.missed_assessments, er.failed_assessments, er.risk_level
                          FROM v_engagement_risk er JOIN students s ON s.id = er.student_id JOIN persons pe ON pe.id = s.person_id
                          JOIN courses c ON c.id = er.course_id WHERE er.risk_level IN ('red','yellow')
                          ORDER BY (er.risk_level = 'red') DESC, er.days_inactive DESC LIMIT 40`);
    return num({ summary, rows });
  },

  '/api/finance': async () => {
    const byProgramme = await q(`SELECT p.code, sum(i.net_amount) AS invoiced,
          COALESCE(sum((SELECT sum(x.amount) FROM payments x WHERE x.invoice_id = i.id AND x.status = 'confirmed')),0) AS collected
          FROM fee_invoices i JOIN student_programmes sp ON sp.id = i.student_programme_id JOIN programmes p ON p.id = sp.programme_id GROUP BY p.code ORDER BY p.code`);
    const methods = await q(`SELECT method AS label, count(*) AS n, sum(amount) AS amount FROM payments WHERE status = 'confirmed' GROUP BY 1 ORDER BY 3 DESC`);
    const overdue = await q(`SELECT s.id AS student_id, s.student_no, pe.first_name || ' ' || pe.last_name AS name, f.net_payable, f.amount_paid, f.outstanding_balance, f.overdue_amount
                             FROM v_student_finance f JOIN students s ON s.id = f.student_id JOIN persons pe ON pe.id = s.person_id
                             WHERE f.overdue_amount > 0 ORDER BY f.overdue_amount DESC LIMIT 15`);
    const scholarships = await q(`SELECT sc.name, count(*) AS awards FROM scholarship_awards a JOIN scholarships sc ON sc.id = a.scholarship_id GROUP BY 1`);
    return num({ byProgramme, methods, overdue, scholarships });
  },

  '/api/graduation': async () => num(await q(`
      SELECT ga.id, s.id AS student_id, s.student_no, pe.first_name || ' ' || pe.last_name AS name, pr.code AS programme, ga.status,
             ga.graduation_date, ga.final_cgpa, fn_graduation_eligibility(sp.id) AS eligibility
      FROM graduation_applications ga JOIN student_programmes sp ON sp.id = ga.student_programme_id
      JOIN students s ON s.id = sp.student_id JOIN persons pe ON pe.id = s.person_id JOIN programmes pr ON pr.id = sp.programme_id
      ORDER BY (ga.status = 'conferred'), ga.applied_on DESC, ga.id LIMIT 60`)),

  '/api/alumni': async () => num(await q(`SELECT a.graduation_year, pr.code AS programme, s.student_no, pe.first_name || ' ' || pe.last_name AS name,
        a.current_ministry, a.church, a.country FROM alumni a JOIN students s ON s.id = a.student_id JOIN persons pe ON pe.id = s.person_id
        JOIN programmes pr ON pr.id = a.programme_id WHERE a.directory_visible ORDER BY a.graduation_year DESC, pe.last_name LIMIT 60`)),

  '/api/verify': async (u) => {
    const r = await one(`SELECT c.certificate_no, c.cert_type, c.issued_on, c.status, pe.first_name || ' ' || pe.last_name AS holder, pr.name AS programme
                         FROM certificates c JOIN students s ON s.id = c.student_id JOIN persons pe ON pe.id = s.person_id
                         LEFT JOIN student_programmes sp ON sp.id = c.student_programme_id LEFT JOIN programmes pr ON pr.id = sp.programme_id
                         WHERE c.verification_code = $1 OR c.certificate_no = $1`, [(u.searchParams.get('code') || '').trim()]);
    return r ? { valid: r.status === 'valid', ...r } : { valid: false, error: 'No certificate matches this code' };
  },

  // Registration rule demo: does the student satisfy the prerequisites of a course?
  '/api/prereq': async (u) => {
    const stu = await one(`SELECT id FROM students WHERE student_no = $1`, [u.searchParams.get('student') || '']);
    const course = await one(`SELECT id, code, title FROM courses WHERE code = $1`, [(u.searchParams.get('course') || '').toUpperCase()]);
    if (!stu || !course) return { error: 'Unknown student number or course code' };
    const ok = (await one(`SELECT fn_prereqs_met($1, $2) AS ok`, [stu.id, course.id])).ok;
    const prereqs = await q(`SELECT g.group_no, c.code, c.title, p.min_grade_point,
        EXISTS (SELECT 1 FROM enrollments e JOIN course_offerings o ON o.id = e.offering_id WHERE e.student_id = $1 AND o.course_id = p.prerequisite_course_id
                AND e.status = 'completed' AND e.grade_point >= p.min_grade_point) AS satisfied
        FROM course_prerequisites p JOIN courses c ON c.id = p.prerequisite_course_id
        JOIN (SELECT DISTINCT group_no FROM course_prerequisites WHERE course_id = $2) g ON g.group_no = p.group_no WHERE p.course_id = $2 ORDER BY 1, 2`, [stu.id, course.id]);
    return num({ course, eligible: ok, prereqs });
  },

  '/api/rbac': async () => {
    const rows = await q(`SELECT r.code AS role, pm.resource, string_agg(DISTINCT pm.action, ',' ORDER BY pm.action) AS actions, max(rp.scope) AS scope
                          FROM roles r JOIN role_permissions rp ON rp.role_id = r.id JOIN permissions pm ON pm.id = rp.permission_id
                          GROUP BY r.code, pm.resource ORDER BY r.code, pm.resource`);
    return rows;
  },

  '/api/audit': async () => num(await q(`SELECT occurred_at, action, table_name, record_id FROM audit_logs ORDER BY id DESC LIMIT 15`)),
};

const cache = new Map(); // 60 s response cache: the heavy analytic views are recomputed at most once a minute
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml' };

http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  try {
    if (routes[u.pathname]) {
      const key = req.url, hit = cache.get(key);
      let body;
      if (hit && Date.now() - hit.t < 60_000) body = hit.body;
      else { body = JSON.stringify(await routes[u.pathname](u)); cache.set(key, { t: Date.now(), body }); }
      res.writeHead(200, { 'content-type': 'application/json' }).end(body);
    } else {
      const file = path.join(PUBLIC, u.pathname === '/' ? 'index.html' : u.pathname.replace(/\.\./g, ''));
      const data = await readFile(file);
      res.writeHead(200, { 'content-type': MIME[path.extname(file)] || 'application/octet-stream' }).end(data);
    }
  } catch (e) {
    const notFound = e.code === 'ENOENT';
    res.writeHead(notFound ? 404 : 500, { 'content-type': 'application/json' }).end(JSON.stringify({ error: notFound ? 'not found' : e.message }));
  }
}).listen(Number(process.env.PORT || 3000), () => console.log(`GSOL ERP demo on http://localhost:${process.env.PORT || 3000}`));

// Warm the cache so the first page view is instant
setTimeout(() => {
  for (const p of ['/api/dashboard', '/api/programmes', '/api/students?q=&programme=&status=', '/api/engagement', '/api/finance', '/api/graduation', '/api/alumni'])
    fetch(`http://localhost:${process.env.PORT || 3000}${p}`).catch(() => {});
}, 200);
