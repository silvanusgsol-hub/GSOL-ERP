#!/usr/bin/env bash
# One-command demo: needs PostgreSQL client+server binaries and Node 20+.
# Usage: tools/demo.sh            (uses PG* env vars; builds DB "gsol", starts http://localhost:3000)
set -euo pipefail
cd "$(dirname "$0")/.."
export PGDATABASE="${PGDATABASE:-gsol}"
tools/rebuild.sh "$PGDATABASE"
(cd app && npm install --silent && node server.js)
