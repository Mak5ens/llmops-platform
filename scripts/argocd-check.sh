#!/usr/bin/env bash
# Wait until every ArgoCD Application is synced and healthy, printing when each one gets there.
# Usage: scripts/argocd-check.sh <kube context> [timeout in seconds, default 900]
set -euo pipefail

context=${1:?usage: $0 <kube context> [timeout]}
timeout=${2:-900}
kc=(kubectl --context "$context" -n argocd)
start=$SECONDS
deadline=$((start + timeout))
ready=""

echo "== ArgoCD Applications"
while true; do
  # name sync health, one line per Application; empty while the root has not created its children.
  # While dozens of pods start, the API server can be too busy to answer (seen on 4-CPU CI runners): a failed call is
  # retried until the deadline, not fatal.
  status=$("${kc[@]}" get applications -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}{end}' 2>/dev/null) || status=""
  # Report each Application the first time it is synced and healthy.
  while read -r name _; do
    [[ -n $name && " $ready " != *" $name "* ]] || continue
    ready="$ready $name"
    echo "$((SECONDS - start)) s: $name synced and healthy"
  done < <(grep ' Synced Healthy$' <<<"$status")
  if [[ -n $status ]] && ! grep -qv ' Synced Healthy$' <<<"$status"; then
    echo "$status" | column -t
    echo "Every Application is synced and healthy"
    exit 0
  fi
  if ((SECONDS >= deadline)); then
    echo "$status" | column -t
    echo "Applications not synced and healthy after ${timeout} s" >&2
    "${kc[@]}" get applications -o jsonpath='{range .items[*]}{.metadata.name}: {.status.conditions}{"\n"}{end}' >&2
    exit 1
  fi
  sleep 5
done
