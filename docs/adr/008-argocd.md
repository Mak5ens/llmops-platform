# ADR-008: ArgoCD rather than Flux

- **Status:** Accepted
- **Date:** 2026-10-11 (decision applied since LAB-124, 2026-10-06)

## Context

Everything on the cluster comes from Git: an agent in the cluster reads this repo and applies it, so nothing is installed by hand and a manual change is reverted (ADR-010, ADR-017). The agent has to:

- deploy about fifteen components in order, operators and their CRDs before what uses them;
- show the state of each one to the platform team and to the teams that use the platform, who do not all read YAML;
- report the health of custom resources (a PostgreSQL cluster, a RabbitMQ cluster), not only that they were applied;
- run the same way on k3d, in the CI and on any other cluster.

Two CNCF projects do this, both graduated: Flux in November 2022, Argo (with Argo CD) in December 2022.
Weaveworks, the company behind Flux, closed in February 2024 (The Register, February 6, 2024). Flux stayed a CNCF project, maintained by its community and other vendors, but its main commercial support and the Weave GitOps interface went with the company.

## Options considered

| Option | Pros | Cons |
| -- | -- | -- |
| A. Argo CD | A web interface that shows every Application, its resources, their health and the diff with Git; projects and SSO roles to give each team a view of its own; health checks built in for many CRDs, Lua for the others; sync waves and the app of apps pattern; the most visible GitOps tool in job offers | Heavier: 7 pods (application controller, repo server, server, Redis, Dex, notifications, ApplicationSet controller); its own concept, `Application`, on top of Kustomize and Helm |
| B. Flux | Light, a set of controllers and native Kubernetes resources (`Kustomization`, `HelmRelease`); `dependsOn` and health checks to order components; image automation built in | No interface of its own since Weave GitOps stopped; multi-team access is Kubernetes RBAC only; no single company behind it since 2024 |
| C. Plain `kubectl apply` from the CI | Nothing to run in the cluster | The CI needs write access to every cluster; no continuous reconciliation, so a manual change stays until the next pipeline |

## Decision

We choose **A**, Argo CD, with an app of apps.
The interface decides it. The platform serves several client teams, and an Application per component, with its health and its diff, is what a team lead or an on-call engineer opens first. Flux would need a third-party interface for the same thing.
Its footprint, about 730 MiB of memory on the local cluster (490 MiB for the application controller), is small next to the 13 GiB of the platform it deploys.

## Consequences

- One small Helm chart, [`apps/`](../../apps/), creates one Application per component, ordered by sync waves. The root Application renders it with the environment and the Git revision, so `just bootstrap` sets them once.
- Argo CD manages its own installation from `platform/argocd/`, like any other component; a Renovate PR upgrades it.
- Every Application syncs automatically, prunes what left Git and repairs manual changes (self-heal). The CI checks that a deleted Deployment comes back (`scripts/selfheal-check.sh`).
- Argo CD compares with a server-side dry run, so the defaults the API server adds to Gateway API resources are not reported as drift.
- Deleting an Application deletes what it deployed, volumes included: recreating the job queue from Git took 109 s (LAB-134). The `argocd` Application keeps its resources, so deleting it never deletes Argo CD.
- Argo CD polls GitHub rather than being called by it: the release 0.2.1 of the gateway was merged at 07:46:08 and synced at 07:47:35 (ADR-023). A webhook would make it immediate, but needs the cluster to be reachable from GitHub.
- Image updates are Renovate PRs, not Argo CD Image Updater: every version change goes through review and the CI (ADR-023).
- We revisit this if the interface stops mattering (a single team, everything through the CLI), or if memory on the target clusters becomes tight enough for Flux's smaller footprint to matter.
