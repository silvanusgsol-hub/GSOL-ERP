// Usage: node run-seed.mjs [upToFileNumber]   -- loads schema + seed files in order and prints row counts
import { PGlite } from '@electric-sql/pglite';
import { readFileSync, readdirSync } from 'node:fs';
const limit = Number(process.argv[2] ?? 99);
const db = new PGlite();
await db.exec(readFileSync('../database/schema.sql', 'utf8'));
for (const f of readdirSync('../database/seed').filter(f => f.endsWith('.sql')).sort()) {
  if (Number(f.slice(0, 2)) > limit) break;
  const t0 = Date.now();
  try { await db.exec(readFileSync('../database/seed/' + f, 'utf8')); console.log('ok  ', f, (Date.now() - t0) + 'ms'); }
  catch (e) { console.error('FAIL', f, '\n ', e.message); process.exit(1); }
}
for (const t of ['programmes','courses','curriculum_courses','faculty','users','role_permissions','terms','library_resources'])
  console.log(t.padEnd(20), (await db.query(`select count(*)::int n from ${t}`)).rows[0].n);
console.log((await db.query(`select code,total_credits,total_learning_hours from programmes order by id`)).rows);
const q = async (s) => (await db.query(s)).rows;
if (limit >= 4) {
  console.log(await q(`select status_code, count(*)::int n from students group by 1 order by 2 desc`));
  console.log(await q(`select p.code, count(*)::int n from student_programmes sp join programmes p on p.id=sp.programme_id group by 1`));
  console.log(await q(`select status, count(*)::int n from applications group by 1 order by 2 desc`));
  console.log(await q(`select outcome, count(*)::int n from zz_seed_plan group by 1`));
  console.log(await q(`select (select count(*) from credit_transfers)::int xfers, (select count(*) from documents)::int docs, (select count(*) from persons)::int persons`));
}
