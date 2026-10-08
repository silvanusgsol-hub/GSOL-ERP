-- =============================================================================
-- GSOL ERP demo seed 06 — fee structures, scholarships, invoices, payments
-- Amounts are illustrative INR figures. Payment behaviour follows each student's
-- synthetic "pay" trait so the outstanding-fee and graduation-hold reports are meaningful.
-- =============================================================================

INSERT INTO fee_structures (programme_id, fee_type_id, amount, billing_basis, effective_from)
SELECT p.id, ft.id, f.amt, f.basis, DATE '2023-07-01'
FROM (VALUES
  ('DIP-TH','APP',500,'one_time'),('DIP-TH','ADM',2000,'one_time'),('DIP-TH','TUI',12000,'per_term'),
  ('DIP-TH','EXM',1000,'per_term'),('DIP-TH','LIB',500,'per_term'),('DIP-TH','GRD',1500,'one_time'),
  ('BTH','APP',750,'one_time'),('BTH','ADM',3000,'one_time'),('BTH','TUI',18000,'per_term'),
  ('BTH','EXM',1500,'per_term'),('BTH','LIB',750,'per_term'),('BTH','GRD',2500,'one_time'),
  ('MACS','APP',1000,'one_time'),('MACS','ADM',4000,'one_time'),('MACS','TUI',24000,'per_term'),
  ('MACS','EXM',2000,'per_term'),('MACS','LIB',1000,'per_term'),('MACS','GRD',3500,'one_time'),('MACS','DIS',8000,'one_time'),
  ('MDIV','APP',1000,'one_time'),('MDIV','ADM',5000,'one_time'),('MDIV','TUI',26000,'per_term'),
  ('MDIV','EXM',2000,'per_term'),('MDIV','LIB',1000,'per_term'),('MDIV','GRD',3500,'one_time'),('MDIV','DIS',8000,'one_time')
) AS f(pc, ftc, amt, basis)
JOIN programmes p ON p.code = f.pc JOIN fee_types ft ON ft.code = f.ftc;

-- Scholarships: ~8% of continuing students (MERIT25 / MINISTRY50 / NEED3K)
INSERT INTO scholarship_applications (scholarship_id, student_id, applied_on, statement, status, decided_by, decided_on)
SELECT 1 + seed_rand(p.student_no || 'sch', 3), p.student_id,
       (t.start_date - 20), 'Applying in light of my ministry context and academic record.',
       'approved', 2, t.start_date - 5
FROM zz_seed_plan p JOIN terms t ON t.seq = p.start_seq
WHERE p.is_first_stint AND p.outcome <> 'withdrawn' AND seed_rand(p.student_no || 'sa', 100) < 8;

INSERT INTO scholarship_applications (scholarship_id, student_id, applied_on, statement, status, decided_by, decided_on)
SELECT 3, p.student_id, DATE '2026-09-15', 'Requesting need-based support for Term 8.',
       CASE WHEN seed_rand(p.student_no || 'sp', 2) = 0 THEN 'pending' ELSE 'rejected' END,
       NULL, NULL
FROM zz_seed_plan p
WHERE p.outcome = 'active' AND p.pay >= 85 AND NOT EXISTS (SELECT 1 FROM scholarship_applications x WHERE x.student_id = p.student_id)
  AND seed_rand(p.student_no || 'sn', 100) < 50;
UPDATE scholarship_applications SET decided_by = 2, decided_on = DATE '2026-09-28' WHERE status = 'rejected' AND decided_by IS NULL;

INSERT INTO scholarship_awards (application_id, student_id, scholarship_id, percentage, fixed_amount, start_term_id, end_term_id, status)
SELECT a.id, a.student_id, a.scholarship_id,
       CASE WHEN s.award_type = 'percentage' THEN s.award_value END,
       CASE WHEN s.award_type = 'fixed' THEN s.award_value END,
       sp.start_term_id, LEAST(8, sp.start_term_id + s.duration_terms - 1), 'active'
FROM scholarship_applications a
JOIN scholarships s ON s.id = a.scholarship_id
JOIN student_programmes sp ON sp.student_id = a.student_id AND sp.id = (SELECT min(id) FROM student_programmes WHERE student_id = a.student_id)
WHERE a.status = 'approved';

-- Invoices: one per student-programme per term in which the student was registered
CREATE TEMP TABLE zz_inv AS
SELECT e.student_programme_id AS sp_id, e.student_id, o.term_id, t.seq, t.start_date,
       bool_or(c.code = 'DIS599') AS has_diss,
       row_number() OVER (ORDER BY t.seq, e.student_id) AS rn
FROM enrollments e JOIN course_offerings o ON o.id = e.offering_id JOIN terms t ON t.id = o.term_id
JOIN courses c ON c.id = o.course_id
GROUP BY e.student_programme_id, e.student_id, o.term_id, t.seq, t.start_date;

CREATE TEMP TABLE zz_inv_lines AS
SELECT i.rn, ft.id AS fee_type_id, ft.name || ' — Term ' || i.seq AS descr, fs.amount
FROM zz_inv i
JOIN student_programmes sp ON sp.id = i.sp_id
JOIN fee_structures fs ON fs.programme_id = sp.programme_id
JOIN fee_types ft ON ft.id = fs.fee_type_id
WHERE (fs.billing_basis = 'per_term' AND ft.code IN ('TUI','EXM','LIB'))
   OR (ft.code = 'ADM' AND i.term_id = sp.start_term_id)
   OR (ft.code = 'DIS' AND i.has_diss);

INSERT INTO fee_invoices (invoice_no, student_id, student_programme_id, term_id, issued_on, due_on,
                          gross_amount, scholarship_amount, discount_amount, status)
SELECT 'INV-' || i.seq || '-' || lpad(i.rn::text, 5, '0'), i.student_id, i.sp_id, i.term_id,
       i.start_date - 14, i.start_date + 16,
       g.gross,
       COALESCE(ROUND(g.tui * aw.percentage / 100 + COALESCE(aw.fixed_amount, 0), 0), 0),
       CASE WHEN seed_rand(i.rn::text || 'disc', 100) < 4 THEN 500 ELSE 0 END,
       'issued'
FROM zz_inv i
CROSS JOIN LATERAL (SELECT SUM(l.amount) AS gross, SUM(l.amount) FILTER (WHERE l.fee_type_id = 3) AS tui
                    FROM zz_inv_lines l WHERE l.rn = i.rn) g
LEFT JOIN scholarship_awards aw ON aw.student_id = i.student_id AND aw.status = 'active'
     AND i.term_id BETWEEN aw.start_term_id AND COALESCE(aw.end_term_id, 99)
WHERE g.gross IS NOT NULL;
-- keep scholarship within the gross amount
UPDATE fee_invoices SET scholarship_amount = LEAST(scholarship_amount, gross_amount - discount_amount);

INSERT INTO invoice_lines (invoice_id, fee_type_id, description, amount)
SELECT fi.id, l.fee_type_id, l.descr, l.amount
FROM zz_inv_lines l JOIN zz_inv i ON i.rn = l.rn
JOIN fee_invoices fi ON fi.student_programme_id = i.sp_id AND fi.term_id = i.term_id;

-- Payments against invoices (full / instalments / late / unpaid depending on the pay trait)
INSERT INTO payments (receipt_no, student_id, invoice_id, amount, method, reference, paid_on, recorded_by, status)
SELECT 'RCP-' || to_char(x.paid_on, 'YYYY') || '-' || lpad(row_number() OVER (ORDER BY x.paid_on, x.invoice_id, x.k)::text, 5, '0'),
       x.student_id, x.invoice_id, x.amount,
       (ARRAY['upi','upi','bank_transfer','online_gateway','cash','cheque','bank_transfer'])[1 + seed_rand(x.invoice_id || 'm' || x.k, 7)],
       'TXN' || lpad((100000 + seed_rand(x.invoice_id || 'ref' || x.k, 900000))::text, 6, '0'),
       x.paid_on, 3, 'confirmed'
FROM (
    SELECT fi.id AS invoice_id, fi.student_id, k.k,
           CASE WHEN p.pay < 55 OR (t.seq <= 4 AND p.pay < 85) THEN (CASE k.k WHEN 1 THEN fi.net_amount END)
                WHEN p.pay < 80 THEN (CASE k.k WHEN 1 THEN ROUND(fi.net_amount * 0.6) ELSE fi.net_amount - ROUND(fi.net_amount * 0.6) END)
                ELSE (CASE k.k WHEN 1 THEN ROUND(fi.net_amount * 0.5) END) END AS amount,
           CASE WHEN p.pay < 55 OR (t.seq <= 4 AND p.pay < 85) THEN fi.due_on - 5 + seed_rand(fi.id || 'pd', 8)
                WHEN p.pay < 80 THEN CASE k.k WHEN 1 THEN fi.due_on + seed_rand(fi.id || 'pa', 6) ELSE fi.due_on + 25 + seed_rand(fi.id || 'pb', 20) END
                ELSE fi.due_on + 20 + seed_rand(fi.id || 'pc', 30) END AS paid_on
    FROM fee_invoices fi
    JOIN terms t ON t.id = fi.term_id
    JOIN zz_seed_plan p ON p.sp_id = fi.student_programme_id
    CROSS JOIN (VALUES (1), (2)) AS k(k)
    WHERE fi.net_amount > 0
      -- very poor payers stop paying in the most recent terms
      AND NOT (p.pay >= 90 AND t.seq >= 6)
) x
WHERE x.amount IS NOT NULL AND x.amount > 0 AND x.paid_on <= fn_as_of();

-- Application-fee receipts (pre-date the student record)
INSERT INTO payments (receipt_no, application_id, amount, method, reference, paid_on, recorded_by, status)
SELECT 'RCP-APP-' || lpad(a.id::text, 5, '0'), a.id, fs.amount,
       (ARRAY['upi','online_gateway','online_gateway','bank_transfer'])[1 + seed_rand(a.id::text, 4)],
       'APPTXN' || lpad(a.id::text, 5, '0'), a.submitted_at::date, NULL, 'confirmed'
FROM applications a
JOIN fee_structures fs ON fs.programme_id = a.programme_id AND fs.fee_type_id = (SELECT id FROM fee_types WHERE code = 'APP')
WHERE a.submitted_at IS NOT NULL;

-- A couple of realistic exceptions: one failed gateway attempt, one refund
UPDATE payments SET status = 'failed' WHERE id = (SELECT min(id) FROM payments WHERE method = 'online_gateway' AND invoice_id IS NOT NULL);
UPDATE payments SET status = 'refunded' WHERE id = (SELECT min(id) FROM payments WHERE method = 'cash' AND invoice_id IS NOT NULL AND id > 500);
