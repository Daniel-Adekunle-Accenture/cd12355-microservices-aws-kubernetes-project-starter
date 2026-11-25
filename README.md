# Coworking Space Service: analytics API on Amazon EKS

## Build
The analytics API in `analytics/` (Flask, port 5153) runs on Amazon EKS next to a PostgreSQL 17 database, all in the `coworking` namespace of the `coworking-cluster` cluster in `us-east-1`.
Every push to `main` triggers a CodeBuild webhook: `buildspec.yaml` logs Docker in to Amazon ECR, builds `analytics/Dockerfile` for `linux/amd64` and pushes `coworking-analytics:1.0.<build number>`, printing the image URI and digest in the build log.
ECR tags are immutable, so a version number always identifies exactly one image.

## Release, verify and roll back
Building does not deploy: to release, change the `image:` line in `deployments/coworking.yaml` to the new tag (or to `@sha256:<digest>` to pin the exact image), commit it and run `kubectl apply -f deployments/coworking.yaml`.
Check the rollout with `kubectl -n coworking rollout status deployment/coworking` and `scripts/verify.sh`, which calls the health, readiness and both report routes through the load balancer.
To roll back, run `kubectl -n coworking rollout undo deployment/coworking`, then put the previous tag back in the manifest so Git matches the cluster.
The liveness probe (`/health_check`) and the readiness probe (`/readiness_check`, which queries the database) keep traffic away from a pod that cannot serve, so a bad release stops at its first new pod.

## Configuration, secret and data
Non-secret settings (`DB_HOST`, `DB_PORT=5432`, `DB_USERNAME`, `DB_NAME`) are in the `coworking-config` ConfigMap, and the only secret, `DB_PASSWORD`, comes from the `coworking-db-credentials` Secret.
`scripts/create-db-secret.sh` creates that Secret by filling in `deployments/db-secret.template.yaml` in memory from a password file kept outside the repository (generated on first use), so no real value is ever committed.
PostgreSQL keeps its data on a 1 GiB encrypted gp3 EBS volume provisioned by the EBS CSI driver and is reachable only inside the cluster at `postgresql-service:5432`.
`scripts/seed-db.sh` loads `db/*.sql` through a loopback-only port-forward (127.0.0.1:5433), skips any step whose data already exists and prints only row counts.
The `coworking` LoadBalancer Service exposes the API on port 5153, and `loadBalancerSourceRanges` limits it to the test client's address.

## Logging
CloudWatch Container Insights (EKS add-on `amazon-cloudwatch-observability`) ships each container's stdout to `/aws/containerinsights/coworking-cluster/application`, where the probe requests and the API's 30-second usage report appear.
The add-on's Application Signals auto-instrumentation is switched off in `infra/addons.sh`, because it injects OpenTelemetry agents into the pod and diverts the app's own log lines away from stdout.

## Setup, evidence and cleanup
The application code is the official starter, unchanged; its placeholder `deployment/` templates are replaced by `deployments/`, whose ConfigMap uses `DB_USERNAME`, the name `config.py` actually reads.
A fresh setup runs `eksctl create cluster -f infra/eks-cluster.yaml`, `infra/addons.sh`, `scripts/setup-ci.sh` and `scripts/deploy.sh`, in that order (`scripts/local-check.sh` runs the API locally and in Docker against the same database).
The screenshots listed below are in `screenshots/`.
`scripts/cleanup.sh` removes everything, deleting the LoadBalancer Service before the cluster so AWS releases the load balancer, and then lists anything left over.

| Screenshot | Shows |
|---|---|
| `01-codebuild-webhook-success.png` | Build 1 Succeeded, initiator `GitHub-Hookshot` (push webhook), commit `fb31ca6` |
| `01b-codebuild-log-push-trigger.png` | Build log: `event PUSH, trigger branch/main`, image `coworking-analytics:1.0.1` |
| `01c-codebuild-log-image-digest.png` | Build log: push of `1.0.1`, digest `sha256:1ca735e4...` |
| `01d-codebuild-push-webhook.png` | Webhook ACTIVE, event `PUSH`, `HEAD_REF ^refs/heads/main$` |
| `01e-codebuild-build-history.png` | Builds 1 and 2, both started by the webhook |
| `02-ecr-image.png`, `02b-ecr-image-1.0.1-digest.png` | ECR images `1.0.1` (deployed) and `1.0.2`, with URI and digest |
| `03-kubectl-services.png` | `kubectl get svc`: `coworking` LoadBalancer with its hostname, `postgresql-service` |
| `04-kubectl-pods.png` | `kubectl get pods`: both pods `1/1 Running` |
| `05-postgres-service.png` | `kubectl describe svc postgresql-service`: port 5432, selector, endpoint |
| `06-analytics-deployment.png`, `06b-...` | `kubectl describe deployment coworking`: image `1.0.1`, 1 available, probes, ConfigMap and Secret |
| `07-cloudwatch-application-logs.png`, `07b-...`, `07c-...` | Container Insights application log group: recurring `GET /health_check` and `/readiness_check` 200, usage report |
| `08-deployed-api-checks.png` | Both report routes through the load balancer, HTTP 200 |
| `09-local-and-docker-checks.txt` | Local virtualenv and Docker runs against the same database, HTTP 200 |

| AWS resource (us-east-1) | Name |
|---|---|
| EKS cluster and node group | `coworking-cluster` (Kubernetes 1.36), `coworking-nodes` (2 x t3.small) |
| EKS add-ons | `aws-ebs-csi-driver`, `amazon-cloudwatch-observability` |
| ECR repository | `coworking-analytics` |
| CodeBuild project and role | `coworking-analytics-build` (PUSH webhook on `main`), `coworking-codebuild-role` |
| Kubernetes objects (namespace `coworking`) | Deployments `coworking`, `postgresql`; Services `coworking`, `postgresql-service`; ConfigMap `coworking-config`; Secret `coworking-db-credentials`; PVC `postgresql-pvc`; StorageClass `coworking-gp3` |
| CloudWatch log groups | `/aws/containerinsights/coworking-cluster/{application,dataplane,host,performance}`, `/aws/codebuild/coworking-analytics-build` |

```bash
# Cleanup, step by step (scripts/cleanup.sh runs the same commands and checks for leftovers)
kubectl -n coworking delete service coworking          # first, so AWS deletes the load balancer
kubectl delete namespace coworking                     # PostgreSQL and the PVC (its EBS volume is deleted too)
eksctl delete cluster -f infra/eks-cluster.yaml --wait
aws ecr delete-repository --repository-name coworking-analytics --force
aws codebuild delete-webhook --project-name coworking-analytics-build
aws codebuild delete-project --name coworking-analytics-build
aws iam delete-role-policy --role-name coworking-codebuild-role --policy-name coworking-codebuild-ecr-push
aws iam delete-role --role-name coworking-codebuild-role
for g in application dataplane host performance; do aws logs delete-log-group --log-group-name /aws/containerinsights/coworking-cluster/$g; done
aws logs delete-log-group --log-group-name /aws/codebuild/coworking-analytics-build
```

## Optional: sizing and cost
**Memory and CPU.** The API requests 100m CPU and 128Mi and is capped at 500m and 256Mi, while PostgreSQL requests 100m and 256Mi with a 512Mi cap.
These fit an idle Flask process with a background scheduler and a small seeded database, and leave room for a rolling update on two nodes.
Revisit them with the Container Insights performance metrics before adding replicas.

**Instance type.** A t3.small (2 burstable vCPUs, 2 GiB) suits this low-traffic, I/O-bound API and its small database.
Burst credits cover the 30-second report job and occasional queries, but a t3.small runs only 11 pods, which is why the node group uses two nodes.
Move to t3.medium for more replicas or a larger database, or to t4g with an arm64 build for a lower price.

**Saving costs.** The EKS control plane (about $0.10 an hour) is the largest fixed cost, so delete the stack with `scripts/cleanup.sh` whenever it is not in use.
Set a retention period (for example 7 days) on the Container Insights log groups and an ECR lifecycle rule that keeps the last ten images, because both grow with every push.
The VPC has no NAT gateway and the API runs as one replica behind one load balancer, which keeps network charges low.
