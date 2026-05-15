#!/usr/bin/env bash
# Full deployment pipeline:
#   1. Build & push Docker image to ECR
#   2. Build React frontend & upload to S3
#   3. Apply Terraform (infrastructure + task definition update)
#   4. Run database migrations via ECS Run Task
#   5. Wait for ECS service to stabilise
#
# Prerequisites:
#   - AWS CLI configured with sufficient permissions
#   - Docker running
#   - pnpm installed (Node 22)
#   - terraform.tfvars present in infra/environments/prod/
#
# Usage:
#   ./infra/scripts/deploy.sh [image-tag]
#   image-tag defaults to the short git SHA.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INFRA_DIR="$REPO_ROOT/infra/environments/prod"
REGION="ap-southeast-1"
IMAGE_TAG="${1:-$(git -C "$REPO_ROOT" rev-parse --short HEAD)}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ── 1. Read Terraform outputs (ECR URL, cluster/service names, S3 bucket) ────

log "Reading Terraform outputs..."
tf_output() { terraform -chdir="$INFRA_DIR" output -raw "$1"; }

ECR_URL=$(tf_output ecr_repository_url)
CLUSTER=$(tf_output ecs_cluster_name)
SERVICE=$(tf_output ecs_service_name)
S3_BUCKET=$(tf_output s3_web_bucket)
CF_ID=$(tf_output cloudfront_id)
TASK_FAMILY="${ECR_URL##*/}"  # strip registry prefix → project-env-api

# ── 2. Build & push API image ─────────────────────────────────────────────────

log "Authenticating with ECR ($REGION)..."
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "${ECR_URL%%/*}"

log "Building API image ($IMAGE_TAG) for linux/amd64..."
docker build \
  --platform linux/amd64 \
  --file "$REPO_ROOT/apps/api/Dockerfile" \
  --tag "$ECR_URL:$IMAGE_TAG" \
  --tag "$ECR_URL:latest" \
  --cache-from "$ECR_URL:latest" \
  "$REPO_ROOT"

log "Pushing API image..."
docker push "$ECR_URL:$IMAGE_TAG"
docker push "$ECR_URL:latest"

# ── 3. Build & upload frontend ────────────────────────────────────────────────

log "Building React frontend..."
(cd "$REPO_ROOT" && pnpm --filter @url-shortener/types build && pnpm --filter web build)

log "Uploading frontend to S3 ($S3_BUCKET)..."
aws s3 sync "$REPO_ROOT/apps/web/dist" "s3://$S3_BUCKET" \
  --delete \
  --cache-control "public,max-age=31536000,immutable" \
  --exclude "index.html"

# index.html must never be cached
aws s3 cp "$REPO_ROOT/apps/web/dist/index.html" "s3://$S3_BUCKET/index.html" \
  --cache-control "no-cache,no-store,must-revalidate"

log "Invalidating CloudFront cache..."
aws cloudfront create-invalidation \
  --distribution-id "$CF_ID" \
  --paths "/*" \
  --output text

# ── 4. Apply Terraform with the new image tag ─────────────────────────────────

log "Applying Terraform (image_tag=$IMAGE_TAG)..."
terraform -chdir="$INFRA_DIR" apply \
  -var "image_tag=$IMAGE_TAG" \
  -auto-approve

# ── 5. Run database migrations ────────────────────────────────────────────────

log "Running database migrations..."
TASK_DEF=$(aws ecs describe-task-definition \
  --task-definition "$TASK_FAMILY" \
  --region "$REGION" \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)

NETWORK_CONFIG=$(aws ecs describe-services \
  --cluster "$CLUSTER" \
  --services "$SERVICE" \
  --region "$REGION" \
  --query 'services[0].networkConfiguration' \
  --output json)

log "Starting migration task..."
MIGRATION_TASK=$(aws ecs run-task \
  --cluster "$CLUSTER" \
  --task-definition "$TASK_DEF" \
  --launch-type FARGATE \
  --network-configuration "$NETWORK_CONFIG" \
  --overrides '{"containerOverrides":[{"name":"api","command":["node_modules/.bin/prisma","migrate","deploy"]}]}' \
  --region "$REGION" \
  --query 'tasks[0].taskArn' \
  --output text)

log "Waiting for migration task to complete ($MIGRATION_TASK)..."
aws ecs wait tasks-stopped \
  --cluster "$CLUSTER" \
  --tasks "$MIGRATION_TASK" \
  --region "$REGION"

EXIT_CODE=$(aws ecs describe-tasks \
  --cluster "$CLUSTER" \
  --tasks "$MIGRATION_TASK" \
  --region "$REGION" \
  --query 'tasks[0].containers[0].exitCode' \
  --output text)

[[ "$EXIT_CODE" == "0" ]] || die "Migration task exited with code $EXIT_CODE"
log "Migrations complete."

# ── 6. Update ECS service with new task definition ────────────────────────────

log "Updating ECS service..."
aws ecs update-service \
  --cluster "$CLUSTER" \
  --service "$SERVICE" \
  --task-definition "$TASK_DEF" \
  --force-new-deployment \
  --region "$REGION" \
  --output text > /dev/null

log "Waiting for service to stabilise..."
aws ecs wait services-stable \
  --cluster "$CLUSTER" \
  --services "$SERVICE" \
  --region "$REGION"

log "Deploy complete. Image: $IMAGE_TAG"
log "  API:     $(tf_output api_url)"
log "  Web:     $(tf_output web_url)"
