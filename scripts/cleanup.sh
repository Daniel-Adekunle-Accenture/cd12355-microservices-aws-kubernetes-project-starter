#!/usr/bin/env bash
# Delete everything this project created in AWS, in a safe order, then list anything left over.
# The LoadBalancer Service goes first so AWS releases the load balancer before eksctl removes the VPC.
# Usage: scripts/cleanup.sh          (asks you to type the cluster name)
#        scripts/cleanup.sh --yes    (no prompt)
set -uo pipefail
cd "$(dirname "$0")/.."
REGION="${AWS_REGION:-us-east-1}"
CLUSTER=coworking-cluster
PROJECT=coworking-analytics-build
REPO=coworking-analytics
ROLE=coworking-codebuild-role
echo "Account $(aws sts get-caller-identity --query Account --output text), region $REGION"
echo "Deletes: namespace coworking (LoadBalancer, PostgreSQL, PVC and its EBS volume), EKS cluster $CLUSTER,"
echo "ECR repository $REPO, CodeBuild project $PROJECT with its webhook and GitHub credential, IAM role $ROLE, log groups."
if [ "${1:-}" != "--yes" ]; then
  read -r -p "Type the cluster name to confirm: " answer
  [ "$answer" = "$CLUSTER" ] || { echo "Cancelled."; exit 1; }
fi
kubectl -n coworking delete service coworking --wait=true           # releases the AWS load balancer
kubectl delete namespace coworking --wait=true                         # PostgreSQL and the PVC (EBS volume: reclaimPolicy Delete)
eksctl delete cluster --region "$REGION" --name "$CLUSTER" --wait      # node group, add-ons, VPC, IAM roles
aws ecr delete-repository --region "$REGION" --repository-name "$REPO" --force > /dev/null && echo "deleted ECR $REPO"
aws codebuild delete-webhook --region "$REGION" --project-name "$PROJECT" 2> /dev/null
aws codebuild delete-project --region "$REGION" --name "$PROJECT" && echo "deleted CodeBuild $PROJECT"
for arn in $(aws codebuild list-source-credentials --region "$REGION" --query "sourceCredentialsInfos[?serverType=='GITHUB'].arn" --output text); do
  aws codebuild delete-source-credentials --region "$REGION" --arn "$arn" > /dev/null && echo "deleted CodeBuild GitHub credential"
done
aws iam delete-role-policy --role-name "$ROLE" --policy-name coworking-codebuild-ecr-push
aws iam delete-role --role-name "$ROLE" && echo "deleted IAM role $ROLE"
for g in $(aws logs describe-log-groups --region "$REGION" --log-group-name-prefix "/aws/containerinsights/$CLUSTER" --query 'logGroups[].logGroupName' --output text) "/aws/codebuild/$PROJECT"; do
  aws logs delete-log-group --region "$REGION" --log-group-name "$g" 2> /dev/null && echo "deleted log group $g"
done
echo "== Leftovers (each line should be empty)"
echo "EKS clusters:   $(aws eks list-clusters --region "$REGION" --query clusters --output text)"
echo "EBS volumes:    $(aws ec2 describe-volumes --region "$REGION" --filters Name=tag:kubernetes.io/created-for/pvc/namespace,Values=coworking --query 'Volumes[].VolumeId' --output text)"
echo "Load balancers: $(aws elb describe-load-balancers --region "$REGION" --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text)"
echo "ECR repos:      $(aws ecr describe-repositories --region "$REGION" --query 'repositories[].repositoryName' --output text)"
echo "CodeBuild:      $(aws codebuild list-projects --region "$REGION" --query projects --output text)"
echo "Log groups:     $(aws logs describe-log-groups --region "$REGION" --log-group-name-prefix /aws/containerinsights --query 'logGroups[].logGroupName' --output text)"
echo "On GitHub, also revoke 'AWS CodeBuild' (Settings > Applications > Authorized OAuth Apps) and delete the fork's deploy key."
