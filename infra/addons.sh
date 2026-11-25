#!/usr/bin/env bash
# EKS add-ons and node count used by this project. Run once after:  eksctl create cluster -f infra/eks-cluster.yaml
# Both add-ons use the node-role policies that infra/eks-cluster.yaml attaches (withAddonPolicies: ebs, cloudWatch).
set -euo pipefail
CLUSTER=coworking-cluster
REGION=us-east-1

# EBS CSI driver: dynamic, encrypted gp3 volumes for the PostgreSQL PVC (StorageClass coworking-gp3).
aws eks create-addon --region "$REGION" --cluster-name "$CLUSTER" --addon-name aws-ebs-csi-driver --tags project=coworking

# CloudWatch Observability: Container Insights, with Fluent Bit shipping every container's stdout/stderr to
# /aws/containerinsights/<cluster>/application. Application Signals auto-instrumentation is switched off: it
# injects OpenTelemetry init containers into every pod and moves the app's own log lines to OTLP, which would
# change the app's runtime and drop its health and report lines from the container log.
aws eks create-addon --region "$REGION" --cluster-name "$CLUSTER" --addon-name amazon-cloudwatch-observability --tags project=coworking \
  --configuration-values '{"applicationSignals":{"enabled":false},"manager":{"applicationSignals":{"autoMonitor":{"monitorAllServices":false}}}}'

for addon in aws-ebs-csi-driver amazon-cloudwatch-observability; do
  aws eks wait addon-active --region "$REGION" --cluster-name "$CLUSTER" --addon-name "$addon"
done

# A t3.small node runs at most 11 pods; the system and add-on pods alone need more, so run two nodes (max 2).
eksctl scale nodegroup --region "$REGION" --cluster "$CLUSTER" --name coworking-nodes --nodes 2 --nodes-min 1 --nodes-max 2
