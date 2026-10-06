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

hex() { openssl rand -hex "${1:-24}"; }

# LiteLLM (LAB-127): admin key and the salt that encrypts credentials in its database.
seed litellm "LITELLM_MASTER_KEY=sk-$(hex)" "LITELLM_SALT_KEY=$(hex 32)"
# Virtual keys of the client teams of tenants.yaml.
seed team-keys "TEAM_KEY_F1=sk-$(hex)" "TEAM_KEY_MJ=sk-$(hex)" "TEAM_KEY_BAUX=sk-$(hex)" "TEAM_KEY_SUPPORT=sk-$(hex)"
# Langfuse API keys: the Gateway project, then one project per team (public keys are in tenants.yaml).
seed langfuse-api-keys "LANGFUSE_PUBLIC_KEY=pk-lf-gateway" "LANGFUSE_SECRET_KEY=sk-lf-$(hex 16)" \
  "LANGFUSE_SECRET_KEY_F1=sk-lf-$(hex 16)" "LANGFUSE_SECRET_KEY_MJ=sk-lf-$(hex 16)" \
  "LANGFUSE_SECRET_KEY_BAUX=sk-lf-$(hex 16)" "LANGFUSE_SECRET_KEY_SUPPORT=sk-lf-$(hex 16)"
# Langfuse accounts: the platform admin, and the read-only account of each team's lead.
seed langfuse-accounts "LANGFUSE_ADMIN_EMAIL=admin@llmops.local" "LANGFUSE_ADMIN_PASSWORD=$(hex 16)" \
  "LANGFUSE_VIEWER_PASSWORD_F1=$(hex 16)" "LANGFUSE_VIEWER_PASSWORD_MJ=$(hex 16)" \
  "LANGFUSE_VIEWER_PASSWORD_BAUX=$(hex 16)" "LANGFUSE_VIEWER_PASSWORD_SUPPORT=$(hex 16)"
# Internal secrets of Langfuse and of its ClickHouse and Valkey; ENCRYPTION_KEY must be 64 hex characters.
seed langfuse-internal "SALT=$(hex 32)" "ENCRYPTION_KEY=$(hex 32)" "NEXTAUTH_SECRET=$(hex 32)" \
  "CLICKHOUSE_PASSWORD=$(hex 16)" "REDIS_PASSWORD=$(hex 16)"
# Langfuse's PostgreSQL user, also used by the tenant bootstrap, which writes the teams' projects there (ADR-016).
seed langfuse-db "username=langfuse" "password=$(hex 16)"
# S3 key of Langfuse's raw events and media.
seed langfuse-s3 "ACCESS_KEY_ID=$(hex 10)" "ACCESS_SECRET_KEY=$(hex 20)"
