#!/usr/bin/env bash
# One-time CI setup: private ECR repository, CodeBuild service role, CodeBuild project and a
# GitHub PUSH webhook on the release branch. Safe to run again (each step updates in place).
# Prerequisite: CodeBuild must already hold a GitHub source credential (connect GitHub once in
# the CodeBuild console); the script stops with a message if it does not.
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
REPO_NAME=coworking-analytics
PROJECT=coworking-analytics-build
ROLE=coworking-codebuild-role
GITHUB_URL="${GITHUB_URL:-https://github.com/Daniel-Adekunle-Accenture/cd12355-microservices-aws-kubernetes-project-starter.git}"
BRANCH="${BRANCH:-main}"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REPO_ARN="arn:aws:ecr:${REGION}:${ACCOUNT}:repository/${REPO_NAME}"
LOG_GROUP="/aws/codebuild/${PROJECT}"

# 1. Private ECR repository: immutable tags (a version always names the same image), scan on push.
aws ecr describe-repositories --region "$REGION" --repository-names "$REPO_NAME" > /dev/null 2>&1 ||
  aws ecr create-repository --region "$REGION" --repository-name "$REPO_NAME" \
    --image-tag-mutability IMMUTABLE --image-scanning-configuration scanOnPush=true \
    --tags Key=project,Value=coworking > /dev/null
echo "ECR repository: ${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}"

# 2. Service role: CodeBuild runs with its short-lived credentials (no access keys anywhere).
if ! aws iam get-role --role-name "$ROLE" > /dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --tags Key=project,Value=coworking \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"codebuild.amazonaws.com"},"Action":"sts:AssumeRole"}]}' > /dev/null
  sleep 10   # give IAM time to propagate the new role
fi
aws iam put-role-policy --role-name "$ROLE" --policy-name coworking-codebuild-ecr-push --policy-document "$(cat <<JSON
{"Version":"2012-10-17","Statement":[
 {"Sid":"BuildLogs","Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],
  "Resource":["arn:aws:logs:${REGION}:${ACCOUNT}:log-group:${LOG_GROUP}","arn:aws:logs:${REGION}:${ACCOUNT}:log-group:${LOG_GROUP}:*"]},
 {"Sid":"EcrLogin","Effect":"Allow","Action":"ecr:GetAuthorizationToken","Resource":"*"},
 {"Sid":"EcrPushThisRepository","Effect":"Allow","Action":["ecr:BatchCheckLayerAvailability","ecr:InitiateLayerUpload","ecr:UploadLayerPart","ecr:CompleteLayerUpload","ecr:PutImage","ecr:BatchGetImage","ecr:GetDownloadUrlForLayer","ecr:DescribeImages"],"Resource":"${REPO_ARN}"}
]}
JSON
)"
echo "Service role: ${ROLE} (CloudWatch Logs for this project, ECR login, push to ${REPO_NAME} only)"

# 3. CodeBuild needs a GitHub source credential to read the repository and create the webhook.
if ! aws codebuild list-source-credentials --region "$REGION" --query 'sourceCredentialsInfos[].serverType' --output text | grep -q GITHUB; then
  echo "CodeBuild has no GitHub source credential yet. Connect GitHub once in the CodeBuild console, then run this again." >&2
  exit 2
fi

# 4. Build project: Docker-capable (privileged) x86_64 Linux build environment, logs in CloudWatch.
PROJECT_JSON=$(cat <<JSON
{"name":"${PROJECT}","description":"Build the coworking analytics image and push it to ECR",
 "source":{"type":"GITHUB","location":"${GITHUB_URL}","buildspec":"buildspec.yaml","reportBuildStatus":true,"gitCloneDepth":1},
 "sourceVersion":"${BRANCH}",
 "artifacts":{"type":"NO_ARTIFACTS"},
 "environment":{"type":"LINUX_CONTAINER","image":"${BUILD_IMAGE:-aws/codebuild/amazonlinux-x86_64-standard:5.0}","computeType":"BUILD_GENERAL1_SMALL","privilegedMode":true},
 "serviceRole":"arn:aws:iam::${ACCOUNT}:role/${ROLE}",
 "timeoutInMinutes":20,
 "logsConfig":{"cloudWatchLogs":{"status":"ENABLED","groupName":"${LOG_GROUP}"}},
 "tags":[{"key":"project","value":"coworking"}]}
JSON
)
if [ "$(aws codebuild batch-get-projects --names "$PROJECT" --query 'length(projects)' --output text)" = 1 ]; then
  aws codebuild update-project --cli-input-json "$PROJECT_JSON" > /dev/null
else
  aws codebuild create-project --cli-input-json "$PROJECT_JSON" > /dev/null
fi

# 5. PUSH webhook: every push to the branch starts a build automatically.
FILTERS='[[{"type":"EVENT","pattern":"PUSH"},{"type":"HEAD_REF","pattern":"^refs/heads/'"$BRANCH"'$"}]]'
if aws codebuild batch-get-projects --names "$PROJECT" --query 'projects[0].webhook.url' --output text | grep -q '^http'; then
  aws codebuild update-webhook --project-name "$PROJECT" --filter-groups "$FILTERS" > /dev/null
else
  aws codebuild create-webhook --project-name "$PROJECT" --filter-groups "$FILTERS" --build-type BUILD > /dev/null
fi
echo "CodeBuild project ${PROJECT} now builds every push to ${BRANCH} of ${GITHUB_URL}"
