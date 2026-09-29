# ADR-001: GitHub and GitHub Actions rather than GitLab CI

- **Status:** Accepted
- **Date:** 2026-09-28

## Context

The platform needs a Git forge, a CI system and a container registry for five public repos.
The CI jobs are heavy for a hobby budget: the gateway job starts LiteLLM, PostgreSQL and two Ollama servers and downloads about 2 GB of models on every PR (2 min 43 s measured in September 2026), and block 2 adds image builds, Trivy scans and signatures.
The work is also a portfolio: the repos must be found and read by recruiters, and the practices must match what most job offers ask for.

## Options considered

| Option | Pros | Cons |
| -- | -- | -- |
| A. GitHub + GitHub Actions + GitHub Container Registry | Actions minutes are free for public repos on standard hosted runners (GitHub billing docs, September 2026); profile README and pinned repos make the portfolio visible; Renovate, Trivy, cosign and uv ship ready-made actions | Tied to one vendor; workflows are YAML plus third-party actions that must be pinned |
| B. GitLab.com + GitLab CI | Excellent integrated CI, built-in registry and environments; can be self-hosted | Free tier gives 400 compute minutes per month (GitLab docs, September 2026), about 150 runs of the gateway job; less visible to recruiters |
| C. GitHub for code, GitLab CI or another CI for pipelines | Best CI of each | Two tools to operate and secure for one person, and status checks crossing two platforms |

## Decision

We choose **A**, GitHub for code, CI, registry and the profile README.
Unlimited minutes on public repos remove the need to shrink CI jobs to fit a quota, so the tests can run the real stack with the real models.

## Consequences

- Every repo shares the same toolchain: pre-commit, just, uv, `amannn/action-semantic-pull-request` for PR titles, `gitleaks/gitleaks-action` for secrets.
- Third-party actions are a supply chain risk: they are pinned to a version and updated by Renovate (LAB-141).
- Images go to `ghcr.io`, signed with cosign, next to the code that builds them.
- We revisit this if a repo turns private (2,000 free minutes per month on the Free plan) or if GPU jobs need self-hosted runners, which work the same way on both forges.
