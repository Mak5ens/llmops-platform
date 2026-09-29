# ADR-010: Several repos rather than a monorepo

- **Status:** Accepted
- **Date:** 2026-09-28

## Context

The platform has three kinds of code: the LLM gateway (block 1), the cluster infrastructure and its GitOps configuration (block 2), and tenant applications (block 3, three themes planned).
ArgoCD deploys what Git describes. The Argo CD best practices recommend keeping manifests in a repo separate from application source code: config changes without a CI build, a cleaner audit log of what reached production, separate write access, and no loop where CI commits to the repo that triggers it.
The work is also a portfolio: a reader should land on one project and understand it without reading the others.

## Options considered

| Option | Pros | Cons |
| -- | -- | -- |
| A. One repo per building block, plus a profile README linking them | Matches the GitOps split (code repos publish images, `llmops-platform` describes what runs); each repo has a focused README, CI and history; a recruiter can read one block alone | A change across repos needs one PR per repo; shared tooling is copied; versions must be propagated between repos |
| B. Monorepo | One PR for a cross-cutting change; one CI config; atomic refactors | CI must filter paths to avoid running everything; the GitOps config mixes with code; one long README for five projects |

## Decision

We choose **A**: `llmops-gateway`, `llmops-platform`, `f1-strategy-analyst`, then `dnd-gm-assistant` and `lease-compliance-checker`, linked by the GitHub profile README.
`llmops-platform` is the single source of truth for what runs on the cluster, and holds the cross-cutting ADRs.

## Consequences

- Application repos build and sign images; Renovate opens a PR in `llmops-platform` when a new version is published, and ArgoCD deploys after the merge (LAB-141). Deployments are therefore reviewed changes in Git.
- Shared tooling is duplicated, and the cost is real: replacing `make` with `just` in September 2026 took three PRs, one per repo. Shared CI steps can move to reusable GitHub workflows if the copies drift.
- Cross-cutting decisions live here, in `docs/adr/`; each repo keeps its own ADRs. ADR numbers are global to the portfolio, so a number is never reused.
- We revisit this if cross-repo PRs become the common case rather than the exception.
