#!/usr/bin/env bash
# Apply every manifest in dependency order and wait until the API is ready behind its load balancer.
# The release that gets deployed is the image tag written in deployments/coworking.yaml.
set -euo pipefail
cd "$(dirname "$0")/.."
NS=coworking
kubectl apply -f deployments/namespace.yaml -f deployments/storageclass.yaml -f deployments/configmap.yaml
scripts/create-db-secret.sh
kubectl apply -f deployments/postgresql-pvc.yaml -f deployments/postgresql-deployment.yaml -f deployments/postgresql-service.yaml
kubectl -n "$NS" rollout status deployment/postgresql --timeout=600s
scripts/seed-db.sh
kubectl apply -f deployments/coworking.yaml
kubectl -n "$NS" rollout status deployment/coworking --timeout=600s
for _ in $(seq 1 60); do
  LB=$(kubectl -n "$NS" get svc coworking -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  [ -n "$LB" ] && break
  sleep 5
done
echo "API base URL: http://${LB}:5153"
