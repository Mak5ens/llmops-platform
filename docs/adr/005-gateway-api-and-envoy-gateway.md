# ADR-005: Gateway API with Envoy Gateway for HTTP exposure

- **Status:** Accepted
- **Date:** 2026-09-28

## Context

The cluster exposes several HTTP services: the LLM gateway, Langfuse, Grafana, ArgoCD and the tenant applications, each on its own host name with TLS from cert-manager.
For years the default answer was the Ingress API with ingress-nginx. On November 11, 2025, Kubernetes SIG Network announced the retirement of ingress-nginx: best-effort maintenance until March 2026, then no releases and no security fixes. It recommends the Gateway API, whose core resources (Gateway, GatewayClass, HTTPRoute) became GA with v1.0 on October 31, 2023.

Two kinds of gateway must not be confused here. The HTTP gateway routes traffic into the cluster (host names, TLS, paths). The LLM gateway, LiteLLM (block 1), handles what is specific to models: team keys, budgets, anonymization, fallback between models.

## Options considered

| Option | Pros | Cons |
| -- | -- | -- |
| A. Envoy Gateway | Built for the Gateway API from the start, by the Envoy project; GA since v1.0 on March 13, 2024; Envoy data plane, as in most service meshes | Younger than Traefik; extensions go through its own policy resources |
| B. Traefik | Mature, simple, supports both Ingress and the Gateway API | Its richer features rely on its own CRDs; the Gateway API is one input among others |
| C. Cilium Gateway | No extra proxy when Cilium is already the CNI | Requires Cilium as CNI, which k3d does not use by default, so local and cloud clusters would differ |
| D. ingress-nginx | Most documented | Retired since March 2026: no security fixes |

## Decision

We choose **A**, the Gateway API with Envoy Gateway, and cert-manager for certificates.
It is an implementation designed for the standard API, which runs the same on k3d and on Kapsule.
LiteLLM stays the LLM gateway, behind Envoy Gateway: each tool does the job it is built for.

## Consequences

- Routes are `HTTPRoute` resources in Git, reviewed like any other change; no Ingress resource in the platform.
- Rate limiting per team stays in LiteLLM (budgets and tokens); Envoy Gateway only protects the edge (TLS, request size, global limits).
- We do not use Envoy AI Gateway for now: it overlaps with LiteLLM, compared in ADR-007.
- We revisit this if Envoy Gateway falls behind the Gateway API conformance reports, or if the platform adopts a service mesh with its own gateway.
