#!/usr/bin/env bash
# Stops the environment to save cost (~$66/month saving).
# What this does:
#   1. Scales ECS service to 0 tasks       (saves ~$10/month, instant)
#   2. Stops RDS instance                  (saves ~$11/month, 30 seconds to initiate)
#   3. Destroys NAT gateway via Terraform  (saves ~$43/month, ~2 minutes)
#
# What keeps running (unavoidable costs ~$32/month):
#   - ALB                ($17) — too slow to delete/recreate (DNS propagation)
#   - ElastiCache Redis  ($12) — AWS does not support pause for Redis
#   - RDS storage         ($2) — storage is always charged even when stopped
#   - ECR, Secrets Mgr    ($1) — negligible
#
# Restart with: ./infra/scripts/start.sh  (~8 minutes)

set -euo pipefail

REGION="ap-southeast-1"
CLUSTER="url-shortener-prod"
SERVICE="url-shortener-prod-api"
RDS_ID="url-shortener-prod"
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../environments/prod" && pwd)"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] WARN: $*"; }

# ── 1. Scale ECS to 0 ────────────────────────────────────────────────────────

log "Scaling ECS service to 0 tasks..."
aws ecs update-service \
  --cluster "$CLUSTER" \
  --service "$SERVICE" \
  --desired-count 0 \
  --region "$REGION" \
  --output text > /dev/null
log "ECS scaled to 0."

# ── 2. Stop RDS ───────────────────────────────────────────────────────────────

RDS_STATUS=$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_ID" \
  --region "$REGION" \
  --query 'DBInstances[0].DBInstanceStatus' \
  --output text 2>/dev/null || echo "not-found")

if [[ "$RDS_STATUS" == "available" ]]; then
  log "Stopping RDS instance ($RDS_ID)..."
  aws rds stop-db-instance \
    --db-instance-identifier "$RDS_ID" \
    --region "$REGION" \
    --output text > /dev/null
  log "RDS stop initiated (will complete in ~30 seconds in background)."
elif [[ "$RDS_STATUS" == "stopped" ]]; then
  log "RDS is already stopped."
else
  warn "RDS status is '$RDS_STATUS' — skipping stop."
fi

# ── 3. Destroy NAT gateway via Terraform ─────────────────────────────────────

log "Destroying NAT gateway (saves \$43/month)..."
terraform -chdir="$INFRA_DIR" apply \
  -var "enable_nat_gateway=false" \
  -auto-approve

log ""
log "Environment stopped."
log "  Running cost while stopped: ~\$32/month"
log "  Saving:                     ~\$66/month"
log ""
log "To restart: ./infra/scripts/start.sh"
