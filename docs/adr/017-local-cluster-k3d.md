# ADR-017: k3d for the local cluster, with scripts that run on any cluster

- **Status:** Accepted
- **Date:** 2026-10-05

## Context

Block 2 is built locally so that it costs nothing day to day: the cloud cluster on Scaleway Kapsule only arrives at milestone 2.3 ([ADR-002](002-scaleway.md)).
The local cluster has several jobs:

- run the same manifests as Kapsule, deployed by ArgoCD from this repo;
- be destroyed and recreated often, since the GitOps loop is `just up`, change, `just down`;
- run in GitHub Actions, so that every PR deploys the platform on a fresh cluster and runs the tests against it;
- leave room for a heavy stack: ArgoCD, kube-prometheus-stack, Loki, Tempo, CloudNativePG, LiteLLM and Langfuse with ClickHouse. The development machine has 28 cores and 31 GB of RAM; a GitHub-hosted runner has 4 cores and 16 GB.

There is no GPU locally: GPUs are rented on Scaleway for a few hours, so GPU support does not weigh in the choice.

The scripts must not be locked to the tool we pick. Someone who already has minikube, or a server running k3s, should be able to deploy the platform on it.

## Options considered

| Option | Pros | Cons |
| -- | -- | -- |
| A. k3d (k3s in Docker), v5.9.0 of June 2026 | Cluster created in about 20 seconds, the lightest footprint; Services of type LoadBalancer work out of the box (k3s ServiceLB, ports mapped by k3d); local image registry built in (`k3d registry create`); multi-node; one versioned YAML file describes the cluster | k3s is not upstream Kubernetes: it bundles Traefik, ServiceLB, local-path storage and flannel, which Kapsule does not have; a smaller project than kind (6,600 GitHub stars against 15,500) |
| B. kind (upstream Kubernetes in Docker), v0.33.0 of August 2026 | Closest to Kapsule: plain kubeadm, and Cilium can replace the default CNI, as on Kapsule where Cilium is the default; used by the CI of Kubernetes itself | LoadBalancer needs an extra component (cloud-provider-kind or MetalLB); local registry wired by hand with a script; heavier nodes |
| C. minikube, v1.39.0 of September 2026 | Well known, many addons, several drivers (Docker, VM) | LoadBalancer needs `minikube tunnel` running in a terminal; built around one node and its addons, which overlap with what ArgoCD deploys; slower to recreate |
| D. k3s installed on the machine (WSL) | Same distribution as k3d, no Docker layer | No clean reset between runs; needs systemd; not usable as is in CI |

## Decision

We choose **A**, k3d, for the local cluster and the CI.
The deciding argument is the CI: a cluster that comes up in seconds on a GitHub runner, with LoadBalancer and a registry already working, lets each PR deploy the whole platform and run the tests on it, without extra components that only exist for the test environment.
kind would be more faithful to Kapsule, but the gap stays small because the platform only relies on standard APIs (Gateway API, StorageClass, operators' CRDs), and milestone 2.3 checks everything again on Kapsule.

To keep the scripts portable, k3d is confined to cluster creation:

- `local/k3d.yaml` and the `just cluster-up` and `just cluster-down` recipes are the only k3d-specific files.
- Everything after creation (installing ArgoCD, the app of apps, the tests) goes through `kubectl` and `helm` on a kube context passed explicitly, never the current one by default, so that a deployment never lands on the wrong cluster. `just up` chains `cluster-up` and this bootstrap; on minikube or k3s, one runs the bootstrap alone on that context.
- No manifest depends on what k3s bundles: Traefik is disabled (Envoy Gateway handles exposure, [ADR-005](005-gateway-api-and-envoy-gateway.md)), so are the Gateway API CRDs that k3s 1.37 bundles (they conflict with Envoy Gateway's, added on 2026-10-06), PersistentVolumeClaims use the cluster's default StorageClass instead of naming `local-path`, and the type of the Envoy Gateway Service can be set per environment.
- Images come from GHCR, as on Kapsule. The local registry only serves images built on the machine during development.

## Consequences

- Each PR gets a real deployment test on a fresh cluster, within the time limit of a CI job.
- The cluster is recreated in seconds, so we test from scratch often instead of patching a long-lived cluster.
- The k3d cluster keeps two k3s components that Kapsule does not have: ServiceLB and local-path storage. Manifests stay independent of them, but a bug tied to Cilium or Scaleway Block Storage only shows on Kapsule, at milestone 2.3.
- Portability has a cost: one more parameter (the kube context) and a few values set per environment. The README documents the bootstrap on minikube (`minikube tunnel` for the LoadBalancer) and on a k3s server (Traefik disabled in `/etc/rancher/k3s/config.yaml`). These two paths are checked by hand once at the end of milestone 2.1, not in CI.
- We revisit this if the k3d project stops shipping releases compatible with the Kubernetes version of Kapsule, or if we adopt Cilium features (network policies, Cilium Gateway) that need the same CNI locally: kind would then be the natural replacement, and only `local/` and two recipes would change.
