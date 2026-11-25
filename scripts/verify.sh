#!/usr/bin/env bash
# Call the API through its load balancer (or BASE_URL) and print the HTTP status of each route.
set -euo pipefail
NS=coworking
if [ -z "${BASE_URL:-}" ]; then
  BASE_URL="http://$(kubectl -n "$NS" get svc coworking -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'):5153"
fi
echo "Base URL: $BASE_URL"
fail=0
for path in /health_check /readiness_check /api/reports/daily_usage /api/reports/user_visits; do
  code=$(curl -s -o /tmp/verify-body -w '%{http_code}' --max-time 20 "$BASE_URL$path" || true)
  printf '%-28s HTTP %s  %s bytes  %s\n' "$path" "$code" "$(wc -c < /tmp/verify-body)" "$(head -c 110 /tmp/verify-body | tr -d '\n')"
  [ "$code" = 200 ] || fail=1
done
[ "$fail" = 0 ] && echo "All routes returned HTTP 200." || { echo "At least one route failed."; exit 1; }
