#!/usr/bin/env bash
# Restarts the environment after it was stopped with stop.sh.
# What this does:
#   1. Recreates NAT gateway via Terraform   (~2 minutes)
#   2. Starts RDS instance and waits         (~5 minutes)
#   3. Scales ECS service back to 1 task     (~2 minutes)
#
# Total restart time: ~8-10 minutes

set -euo pipefail

REGION="ap-southeast-1"
CLUSTER="url-shortener-prod"
SERVICE="url-shortener-prod-api"
RDS_ID="url-shortener-prod"
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../environments/prod" && pwd)"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ── 1. Recreate NAT gateway via Terraform ────────────────────────────────────

log "Recreating NAT gateway..."
terraform -chdir="$INFRA_DIR" apply \
  -var "enable_nat_gateway=true" \
  -auto-approve
log "NAT gateway is up."

# ── 2. Start RDS ─────────────────────────────────────────────────────────────

RDS_STATUS=$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_ID" \
  --region "$REGION" \
  --query 'DBInstances[0].DBInstanceStatus' \
  --output text 2>/dev/null || echo "not-found")

if [[ "$RDS_STATUS" == "stopped" ]]; then
  log "Starting RDS instance (this takes 3-5 minutes)..."
  aws rds start-db-instance \
    --db-instance-identifier "$RDS_ID" \
    --region "$REGION" \
    --output text > /dev/null

  log "Waiting for RDS to become available..."
  aws rds wait db-instance-available \
    --db-instance-identifier "$RDS_ID" \
    --region "$REGION"
  log "RDS is available."
elif [[ "$RDS_STATUS" == "available" ]]; then
  log "RDS is already running."
else
  die "Unexpected RDS status: '$RDS_STATUS'. Check the AWS console."
fi

# ── 3. Scale ECS to 1 ────────────────────────────────────────────────────────

log "Scaling ECS service to 1 task..."
aws ecs update-service \
  --cluster "$CLUSTER" \
  --service "$SERVICE" \
  --desired-count 1 \
  --region "$REGION" \
  --output text > /dev/null

log "Waiting for ECS service to stabilise..."
aws ecs wait services-stable \
  --cluster "$CLUSTER" \
  --services "$SERVICE" \
  --region "$REGION"

log ""
log "Environment is running."
log "  API: https://api.go.khoitv.com/health"
log "  Web: https://go.khoitv.com"
