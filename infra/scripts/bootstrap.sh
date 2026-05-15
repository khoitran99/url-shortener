#!/usr/bin/env bash
# Run once to create the S3 bucket and DynamoDB table for Terraform state.
# Then copy the printed backend_block into infra/environments/prod/main.tf.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$SCRIPT_DIR/../bootstrap"

echo "==> Initialising Terraform bootstrap..."
terraform -chdir="$BOOTSTRAP_DIR" init

echo "==> Applying bootstrap..."
terraform -chdir="$BOOTSTRAP_DIR" apply -auto-approve

echo ""
echo "==> Copy the following backend block into infra/environments/prod/main.tf:"
echo ""
terraform -chdir="$BOOTSTRAP_DIR" output -raw backend_block
echo ""
