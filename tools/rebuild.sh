#!/usr/bin/env bash
# Rebuild the demo database from scratch: schema + every seed file in order.
# Usage: PGHOST=/tmp PGPORT=5433 PGUSER=postgres tools/rebuild.sh [dbname]
set -euo pipefail
DB="${1:-gsol}"; cd "$(dirname "$0")/.."
psql -q -v ON_ERROR_STOP=1 -d postgres -c "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB"
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f database/schema.sql
for f in database/seed/*.sql; do echo "seed: $f"; psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$f" >/dev/null; done
echo "done: $DB"
