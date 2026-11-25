#!/usr/bin/env bash
# Seed PostgreSQL with db/*.sql through a loopback-only port-forward (127.0.0.1:5433 -> service port 5432).
# Each step runs only if it is still needed, so the script is safe to run again, and it
# stops only the port-forward it started. It prints row counts, never user or token data.
set -euo pipefail
cd "$(dirname "$0")/.."
NS="${NAMESPACE:-coworking}"
LOCAL_PORT="${LOCAL_PORT:-5433}"
DB_USER=$(kubectl -n "$NS" get configmap coworking-config -o jsonpath='{.data.DB_USERNAME}')
DB_NAME=$(kubectl -n "$NS" get configmap coworking-config -o jsonpath='{.data.DB_NAME}')
PGPASSWORD="$(kubectl -n "$NS" get secret coworking-db-credentials -o jsonpath='{.data.DB_PASSWORD}' | base64 -d)"
export PGPASSWORD
kubectl -n "$NS" port-forward --address 127.0.0.1 svc/postgresql-service "${LOCAL_PORT}:5432" > /tmp/seed-port-forward.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do pg_isready -q -h 127.0.0.1 -p "$LOCAL_PORT" && break; sleep 1; done
psql_q() { psql -h 127.0.0.1 -p "$LOCAL_PORT" -U "$DB_USER" -d "$DB_NAME" -X -v ON_ERROR_STOP=1 "$@"; }
run_sql() { echo "Running $1"; psql_q -q --single-transaction -f "$1" > /dev/null; }
[ "$(psql_q -tAc "SELECT to_regclass('public.tokens') IS NOT NULL")" = t ] || run_sql db/1_create_tables.sql
[ "$(psql_q -tAc 'SELECT count(*) FROM users')" -gt 0 ] || run_sql db/2_seed_users.sql
[ "$(psql_q -tAc 'SELECT count(*) FROM tokens')" -gt 0 ] || run_sql db/3_seed_tokens.sql
psql_q -c "SELECT 'users' AS table_name, count(*) AS row_count FROM users UNION ALL SELECT 'tokens', count(*) FROM tokens UNION ALL SELECT 'tokens used', count(*) FROM tokens WHERE used_at IS NOT NULL;"
