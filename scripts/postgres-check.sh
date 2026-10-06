#!/usr/bin/env bash
# Check the databases: secrets synced from the store, PostgreSQL clusters healthy and archiving WAL,
# then kill the primary of litellm-db and check that the replica takes over with the last commit.
# Usage: scripts/postgres-check.sh <kube context>
set -euo pipefail

context=${1:?usage: $0 <kube context>}
kc=(kubectl --context "$context")
ns=llm-gateway
cluster=litellm-db

echo "== Secrets"
"${kc[@]}" wait --for=condition=Ready clustersecretstore/platform --timeout=120s
"${kc[@]}" wait --for=condition=Ready externalsecret --all -A --timeout=120s
"${kc[@]}" get externalsecrets -A

echo "== PostgreSQL clusters"
"${kc[@]}" wait --for=condition=Ready cluster.postgresql.cnpg.io --all -A --timeout=300s
"${kc[@]}" wait --for=condition=ContinuousArchiving cluster.postgresql.cnpg.io --all -A --timeout=120s
"${kc[@]}" get cluster.postgresql.cnpg.io -A

primary() { "${kc[@]}" -n "$ns" get cluster "$cluster" -o jsonpath='{.status.currentPrimary}'; }
# Test rows go to the "postgres" database, never into the application's.
sql() { "${kc[@]}" -n "$ns" exec "$1" -c postgres -- psql -U postgres -d postgres -tAc "$2"; }

echo "== Failover of $cluster"
old=$(primary)
marker="failover-$(date +%s)"
sql "$old" "CREATE TABLE IF NOT EXISTS platform_check (marker text PRIMARY KEY, at timestamptz DEFAULT now());
  INSERT INTO platform_check (marker) VALUES ('$marker')" >/dev/null
echo "Committed $marker on $old, deleting the pod"
start=$(date +%s)
"${kc[@]}" -n "$ns" delete pod "$old" --wait=false
for _ in $(seq 120); do
  new=$(primary)
  [[ -n $new && $new != "$old" ]] && break
  sleep 1
done
[[ $new != "$old" ]] || { echo "No new primary after 120 s" >&2; exit 1; }
"${kc[@]}" -n "$ns" wait --for=condition=Ready "cluster/$cluster" --timeout=300s
echo "New primary $new after $(($(date +%s) - start)) s"
[[ $(sql "$new" "SELECT count(*) FROM platform_check WHERE marker = '$marker'") == 1 ]] \
  || { echo "$marker lost in the failover" >&2; exit 1; }
echo "$marker found on $new: no committed transaction lost"
