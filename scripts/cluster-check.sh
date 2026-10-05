#!/usr/bin/env bash
# Check that the local k3d cluster is empty and healthy: nodes ready, system pods up,
# no Traefik, and the local registry usable from the cluster.
# Usage: scripts/cluster-check.sh <kube context>
set -euo pipefail

context=${1:?usage: $0 <kube context>}
kc=(kubectl --context "$context")
registry=localhost:5050
in_cluster_registry=registry.localhost:5050

step() { printf '\n== %s\n' "$*"; }

step "Nodes"
"${kc[@]}" wait --for=condition=Ready nodes --all --timeout=120s
"${kc[@]}" get nodes -o wide

step "System pods"
# rollout status rather than the Available condition, which a one-replica deployment meets with no pod ready.
for deployment in $("${kc[@]}" -n kube-system get deployments -o name); do
  "${kc[@]}" -n kube-system rollout status "$deployment" --timeout=180s
done
"${kc[@]}" -n kube-system get deployments

step "No Traefik"
if "${kc[@]}" -n kube-system get deployment traefik >/dev/null 2>&1; then
  echo "Traefik is installed: the k3s option --disable=traefik was not applied" >&2
  exit 1
fi
echo "Traefik is disabled"

step "Default StorageClass"
"${kc[@]}" get storageclass

step "Local registry"
docker pull -q busybox:1.37 >/dev/null
docker tag busybox:1.37 "$registry/busybox:1.37"
docker push -q "$registry/busybox:1.37" >/dev/null
"${kc[@]}" delete pod registry-check --ignore-not-found >/dev/null
"${kc[@]}" run registry-check --image="$in_cluster_registry/busybox:1.37" --restart=Never \
  --command -- echo "pulled $in_cluster_registry/busybox:1.37 from the local registry" >/dev/null
"${kc[@]}" wait pod/registry-check --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s >/dev/null
"${kc[@]}" logs registry-check
"${kc[@]}" delete pod registry-check >/dev/null

printf '\nCluster %s is healthy\n' "$context"
