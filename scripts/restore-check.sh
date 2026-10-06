#!/usr/bin/env bash
# Restore test of litellm-db, as in docs/runbooks/postgres-restore.md: commit a marker, take a
# backup, restore it into a new cluster from S3 only, find the marker there, then clean up.
# Usage: scripts/restore-check.sh <kube context>
set -euo pipefail

context=${1:?usage: $0 <kube context>}
kc=(kubectl --context "$context")
ns=llm-gateway
cluster=litellm-db
restored=$cluster-restore-check
backup=$cluster-restore-check-$(date +%s)
trap '"${kc[@]}" -n "$ns" delete cluster "$restored" --ignore-not-found --wait=false >/dev/null' EXIT

sql() { "${kc[@]}" -n "$ns" exec "$1" -c postgres -- psql -U postgres -d postgres -qtA -c "SET client_min_messages = warning" -c "$2"; }

primary=$("${kc[@]}" -n "$ns" get cluster "$cluster" -o jsonpath='{.status.currentPrimary}')
marker="restore-$(date +%s)"
sql "$primary" "CREATE TABLE IF NOT EXISTS platform_check (marker text PRIMARY KEY, at timestamptz DEFAULT now());
  INSERT INTO platform_check (marker) VALUES ('$marker')" >/dev/null
echo "== Committed $marker on $primary, backing up"
start=$(date +%s)
"${kc[@]}" -n "$ns" apply -f - >/dev/null <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $backup
spec:
  cluster:
    name: $cluster
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
YAML
"${kc[@]}" -n "$ns" wait --for=jsonpath='{.status.phase}'=completed "backup/$backup" --timeout=300s
echo "Backup $backup completed in $(($(date +%s) - start)) s"
# Close the current WAL segment and wait for it to reach S3: the restore replays WAL up to the
# last archived segment, and PostgreSQL would only switch on its own after archive_timeout (5 min).
segment=$(sql "$primary" "SELECT pg_walfile_name(pg_switch_wal())")
for _ in $(seq 60); do
  [[ $(sql "$primary" "SELECT last_archived_wal >= '$segment' FROM pg_stat_archiver") == t ]] && break
  sleep 1
done
echo "WAL archived up to $segment"

echo "== Restoring into $restored"
start=$(date +%s)
"${kc[@]}" -n "$ns" apply -f - >/dev/null <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $restored
spec:
  instances: 1
  storage:
    size: 1Gi
  bootstrap:
    recovery:
      source: origin
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: backups
          serverName: $cluster
YAML
"${kc[@]}" -n "$ns" wait --for=condition=Ready "cluster/$restored" --timeout=600s
echo "Restored in $(($(date +%s) - start)) s"
[[ $(sql "$restored-1" "SELECT count(*) FROM platform_check WHERE marker = '$marker'") == 1 ]] \
  || { echo "$marker missing from the restored cluster" >&2; exit 1; }
echo "$marker found in $restored"
"${kc[@]}" -n "$ns" delete backup "$backup" >/dev/null
