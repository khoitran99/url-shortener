#!/usr/bin/env bash
# Destroys ALL infrastructure and takes an RDS snapshot to preserve URL data.
#
# Cost after destroy: ~$0.10/month (snapshot storage only)
# Recreate with:     ./infra/scripts/recreate.sh <snapshot-id>
#
# What this does:
#   1. Scale ECS to 0           (clean shutdown, avoids in-flight requests)
#   2. Disable RDS deletion protection  (required for terraform destroy)
#   3. Take RDS snapshot        (preserves all URL data, ~3-5 min)
#   4. terraform destroy        (destroys everything, ~10 min)
#   5. Force-delete secrets     (prevents "pending deletion" conflict on recreate)

set -euo pipefail

REGION="ap-southeast-1"
CLUSTER="url-shortener-prod"
SERVICE="url-shortener-prod-api"
RDS_ID="url-shortener-prod"
SNAPSHOT_ID="url-shortener-prod-$(date +%Y-%m-%d-%H%M)"
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../environments/prod" && pwd)"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ── Confirm ───────────────────────────────────────────────────────────────────

echo ""
echo "  This will DESTROY all infrastructure in ap-southeast-1."
echo "  A snapshot of your URL data will be saved before destruction."
echo "  Cost after: ~\$0.10/month (snapshot only)"
echo "  Recreate:   ./infra/scripts/recreate.sh $SNAPSHOT_ID"
echo ""
read -rp "  Type 'destroy' to confirm: " CONFIRM
[[ "$CONFIRM" == "destroy" ]] || die "Cancelled."
echo ""

# ── 1. Scale ECS to 0 ─────────────────────────────────────────────────────────

log "Scaling ECS to 0 (clean shutdown)..."
aws ecs update-service \
  --cluster "$CLUSTER" \
  --service "$SERVICE" \
  --desired-count 0 \
  --region "$REGION" \
  --output text > /dev/null

# ── 2. Disable RDS deletion protection ───────────────────────────────────────

RDS_STATUS=$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_ID" \
  --region "$REGION" \
  --query 'DBInstances[0].DBInstanceStatus' \
  --output text 2>/dev/null || echo "not-found")

if [[ "$RDS_STATUS" == "not-found" ]]; then
  log "RDS not found — skipping snapshot."
else
  log "Disabling RDS deletion protection..."
  aws rds modify-db-instance \
    --db-instance-identifier "$RDS_ID" \
    --no-deletion-protection \
    --apply-immediately \
    --region "$REGION" \
    --output text > /dev/null

  # ── 3. Take RDS snapshot ───────────────────────────────────────────────────

  log "Creating RDS snapshot ($SNAPSHOT_ID)..."
  aws rds create-db-snapshot \
    --db-instance-identifier "$RDS_ID" \
    --db-snapshot-identifier "$SNAPSHOT_ID" \
    --region "$REGION" \
    --output text > /dev/null

  log "Waiting for snapshot to complete (3-5 minutes)..."
  aws rds wait db-snapshot-completed \
    --db-snapshot-identifier "$SNAPSHOT_ID" \
    --region "$REGION"

  log "Snapshot complete: $SNAPSHOT_ID"
fi

# ── 4. Destroy all infrastructure ────────────────────────────────────────────

log "Running terraform destroy (this takes ~10 minutes)..."
terraform -chdir="$INFRA_DIR" destroy -auto-approve

# ── 5. Force-delete Secrets Manager secrets immediately ──────────────────────
# Terraform schedules secrets for 30-day deletion by default.
# Force-deleting now prevents a "secret pending deletion" error on the next recreate.

log "Force-deleting secrets..."
for secret in "url-shortener/prod/database-url" "url-shortener/prod/db-password"; do
  aws secretsmanager delete-secret \
    --secret-id "$secret" \
    --force-delete-without-recovery \
    --region "$REGION" 2>/dev/null && log "  Deleted: $secret" || true
done

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
log "All infrastructure destroyed."
log ""
log "  Snapshot ID:  $SNAPSHOT_ID"
log "  Running cost: ~\$0.10/month (snapshot storage)"
log ""
log "  To recreate (restores all URL data):"
log "  ./infra/scripts/recreate.sh $SNAPSHOT_ID"
log ""
log "  To recreate with a fresh empty database:"
log "  ./infra/scripts/recreate.sh"
