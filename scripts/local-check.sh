#!/usr/bin/env bash
# Run the API outside Kubernetes against the EKS database through a loopback-only port-forward
# (127.0.0.1:5433 -> postgresql-service:5432): first with the local Python virtualenv, then as the
# Docker image with host networking. DB settings are passed at runtime; nothing secret is printed.
# Usage: scripts/local-check.sh [virtualenv dir]   (default /root/venvs/coworking)
set -euo pipefail
cd "$(dirname "$0")/.."
VENV="${1:-/root/venvs/coworking}"
NS=coworking
export DB_HOST=127.0.0.1 DB_PORT=5433
DB_USERNAME=$(kubectl -n "$NS" get configmap coworking-config -o jsonpath='{.data.DB_USERNAME}')
DB_NAME=$(kubectl -n "$NS" get configmap coworking-config -o jsonpath='{.data.DB_NAME}')
DB_PASSWORD=$(kubectl -n "$NS" get secret coworking-db-credentials -o jsonpath='{.data.DB_PASSWORD}' | base64 -d)
export DB_USERNAME DB_NAME DB_PASSWORD
kubectl -n "$NS" port-forward --address 127.0.0.1 svc/postgresql-service 5433:5432 > /tmp/local-port-forward.log 2>&1 &
PF=$!
APP=""
cleanup() { [ -n "$APP" ] && kill "$APP" 2>/dev/null; docker rm -f coworking-local > /dev/null 2>&1; kill "$PF" 2>/dev/null; true; }
trap cleanup EXIT
wait_up() { for _ in $(seq 1 40); do curl -s -o /dev/null http://127.0.0.1:5153/health_check && return 0; sleep 1; done; echo "API did not start"; return 1; }
check() {
  echo "== $1"
  for p in /health_check /readiness_check /api/reports/daily_usage /api/reports/user_visits; do
    code=$(curl -s -o /tmp/local-body -w '%{http_code}' "http://127.0.0.1:5153$p")
    printf '%-26s HTTP %s %7s bytes  %s\n' "$p" "$code" "$(wc -c < /tmp/local-body)" "$(head -c 80 /tmp/local-body | tr -d '\n')"
  done
}
sleep 3
# 1. Plain Python in the virtualenv.
(cd analytics && exec "$VENV/bin/python" app.py) > /tmp/local-app.log 2>&1 &
APP=$!
wait_up && check "python app.py ($("$VENV/bin/python" -V))"
kill "$APP"; wait "$APP" 2>/dev/null || true; APP=""
# 2. The Docker image; host networking lets it reach the same port-forward. Stop the Python process first.
docker build -q -t coworking-analytics:local -f analytics/Dockerfile analytics > /dev/null
docker run -d --name coworking-local --network host -e DB_HOST -e DB_PORT -e DB_USERNAME -e DB_NAME -e DB_PASSWORD coworking-analytics:local > /dev/null
wait_up && check "docker run coworking-analytics:local --network host (user $(docker exec coworking-local id -u))"
echo "== container log (last 4 lines)"; docker logs --tail 4 coworking-local 2>&1
