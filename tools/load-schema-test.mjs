import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';
const db = new PGlite();
try {
  await db.exec(readFileSync('../database/schema.sql', 'utf8'));
  const t = await db.query(`select count(*)::int n from pg_tables where schemaname='public'`);
  const v = await db.query(`select count(*)::int n from pg_views where schemaname='public'`);
  const f = await db.query(`select count(*)::int n from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'`);
  console.log('OK tables', t.rows[0].n, 'views', v.rows[0].n, 'functions', f.rows[0].n);
} catch (e) { console.error('FAIL:', e.message, e.position ?? ''); process.exit(1); }
