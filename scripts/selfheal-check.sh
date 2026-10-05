#!/usr/bin/env bash
# Delete a resource managed by ArgoCD and check that ArgoCD recreates it (self-heal).
# Usage: scripts/selfheal-check.sh <kube context>
set -euo pipefail

context=${1:?usage: $0 <kube context>}
kc=(kubectl --context "$context" -n argocd)
target=deployment/argocd-applicationset-controller

echo "== Self-heal: deleting $target"
"${kc[@]}" delete "$target" --wait=true
for _ in $(seq 60); do
  "${kc[@]}" get "$target" >/dev/null 2>&1 && break
  sleep 2
done
"${kc[@]}" rollout status "$target" --timeout=180s
echo "ArgoCD recreated $target"
