#!/usr/bin/env bash
# Install ArgoCD on a cluster and hand it the root Application: from then on, everything
# on the cluster comes from Git. Runs on any cluster (k3d, minikube, k3s, Kapsule).
# Usage: scripts/bootstrap.sh <kube context> <env: local|cloud> <git revision>
# The revision must be pushed: ArgoCD reads the repo from GitHub, not from this machine.
set -euo pipefail

context=${1:?usage: $0 <kube context> <env> <git revision>}
env=${2:?usage: $0 <kube context> <env> <git revision>}
revision=${3:?usage: $0 <kube context> <env> <git revision>}
kc=(kubectl --context "$context")
cd "$(dirname "$0")/.."

[[ -d platform/argocd/overlays/$env ]] || { echo "Unknown env: $env" >&2; exit 1; }
if ! git ls-remote --exit-code origin "$revision" >/dev/null && ! git ls-remote origin | grep -q "^$revision"; then
  echo "Revision $revision is not on origin: push it first, ArgoCD reads the repo from GitHub" >&2
  exit 1
fi

echo "== ArgoCD ($env overlay) on $context"
# Server-side apply: ArgoCD's CRDs are too large for client-side apply.
"${kc[@]}" apply -k "platform/argocd/overlays/$env" --server-side --force-conflicts >/dev/null
for workload in $("${kc[@]}" -n argocd get deployments,statefulsets -o name); do
  "${kc[@]}" -n argocd rollout status "$workload" --timeout=300s
done

echo "== Root Application (env $env, revision $revision)"
helm template root apps --set-string "env=$env,revision=$revision" --show-only templates/root.yaml \
  | "${kc[@]}" apply -f -

scripts/argocd-check.sh "$context"
