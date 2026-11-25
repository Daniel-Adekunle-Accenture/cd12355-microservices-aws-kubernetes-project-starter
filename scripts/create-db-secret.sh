#!/usr/bin/env bash
# Create the coworking-db-credentials Secret from deployments/db-secret.template.yaml.
# The password comes from DB_PASSWORD_FILE (default ~/.coworking/db-password, outside the repo).
# If that file is missing and the Secret already exists, the Secret is kept: the database was
# initialised with that password, so replacing it would lock the app out.
# Otherwise a random password is generated into the file. The value is never printed or written under the repo.
set -euo pipefail
cd "$(dirname "$0")/.."
PW_FILE="${DB_PASSWORD_FILE:-$HOME/.coworking/db-password}"
if [ ! -s "$PW_FILE" ]; then
  if kubectl -n coworking get secret coworking-db-credentials > /dev/null 2>&1; then
    echo "Secret coworking-db-credentials already exists; keeping it."
    exit 0
  fi
  mkdir -p "$(dirname "$PW_FILE")" && chmod 700 "$(dirname "$PW_FILE")"
  (umask 077 && openssl rand -hex 24 > "$PW_FILE")
  echo "Generated a new database password in $PW_FILE"
fi
# Fill in the template in memory and send it straight to the cluster.
DB_PASSWORD="$(cat "$PW_FILE")" python3 -c '
import os, sys
sys.stdout.write(open(sys.argv[1]).read().replace("${DB_PASSWORD}", os.environ["DB_PASSWORD"]))
' deployments/db-secret.template.yaml | kubectl apply -f -
echo "Secret coworking-db-credentials is in place (value not shown)."
