#!/usr/bin/env bash
# Recreates all infrastructure after destroy.sh was run.
#
# Usage:
#   ./infra/scripts/recreate.sh                          # fresh empty database
#   ./infra/scripts/recreate.sh url-shortener-prod-2026-05-15-1730  # restore from snapshot
#
# What this does:
#   1. terraform apply   — provisions all AWS resources (~15-20 min)
#   2. deploy.sh         — builds image, uploads frontend, runs migrations, starts service
#
# Total time: ~25 minutes

set -euo pipefail

SNAPSHOT_ID="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$SCRIPT_DIR/../environments/prod"
REGION="ap-southeast-1"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ── 1. Provision all infrastructure ──────────────────────────────────────────

if [[ -n "$SNAPSHOT_ID" ]]; then
  log "Recreating infrastructure (restoring DB from snapshot: $SNAPSHOT_ID)..."

  # Verify the snapshot exists before spending 20 minutes applying
  SNAP_STATUS=$(aws rds describe-db-snapshots \
    --db-snapshot-identifier "$SNAPSHOT_ID" \
    --region "$REGION" \
    --query 'DBSnapshots[0].Status' \
    --output text 2>/dev/null || echo "not-found")

  [[ "$SNAP_STATUS" == "available" ]] || \
    die "Snapshot '$SNAPSHOT_ID' not found or not available (status: $SNAP_STATUS)"

  terraform -chdir="$INFRA_DIR" apply \
    -var "rds_snapshot_id=$SNAPSHOT_ID" \
    -auto-approve
else
  log "Recreating infrastructure (fresh empty database)..."
  terraform -chdir="$INFRA_DIR" apply -auto-approve
fi

# ── 2. Build, push, and deploy the application ────────────────────────────────

log "Deploying application (build → push → migrate → start)..."
"$SCRIPT_DIR/deploy.sh"

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
log "Infrastructure recreated and running."
log "  API: https://api.go.khoitv.com/health"
log "  Web: https://go.khoitv.com"
