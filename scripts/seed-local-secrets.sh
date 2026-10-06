#!/usr/bin/env bash
# Local stand-in for the cloud secret manager: random values, written once into the local-secrets
# namespace, where the ClusterSecretStore "platform" reads them (ADR-019). Existing secrets are kept,
# so a re-run does not break what already uses them. In the cloud, Terraform writes the same
# secrets to Scaleway Secret Manager.
# Usage: scripts/seed-local-secrets.sh <kube context>
set -euo pipefail

context=${1:?usage: $0 <kube context>}
kc=(kubectl --context "$context")

"${kc[@]}" create namespace local-secrets --dry-run=client -o yaml | "${kc[@]}" apply -f - >/dev/null

# seed <secret name> <KEY=value>...; values go through a file descriptor, never on a command line.
seed() {
  local name=$1
  shift
  if "${kc[@]}" -n local-secrets get secret "$name" >/dev/null 2>&1; then
    echo "$name: kept"
    return
  fi
  "${kc[@]}" -n local-secrets create secret generic "$name" --from-env-file=<(printf '%s\n' "$@") >/dev/null
  echo "$name: created"
}

# S3 key of the PostgreSQL backups, shared by SeaweedFS and the clusters.
seed s3-backup "ACCESS_KEY_ID=$(openssl rand -hex 10)" "ACCESS_SECRET_KEY=$(openssl rand -hex 20)"
