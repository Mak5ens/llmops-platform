# ADR-023: Releases by release-please, deployed through Renovate PRs, gated on signature and configuration

- **Status:** Accepted
- **Date:** 2026-10-09

## Context

The code of an application lives in its own repo, and llmops-platform describes which version of it runs (ADR-010). Until now, deploying a new image of llmops-gateway meant copying a `sha-<commit>` tag by hand into `platform/llm-gateway/base/kustomization.yaml`, and its configuration files with it (LAB-141).
Three things have to be decided:

- how an application publishes a version;
- how the platform learns about it;
- what has to hold before that version is deployed.

The platform keeps a copy of `config/litellm.yaml` and `config/tenants.yaml` from llmops-gateway, mounted as ConfigMaps. LiteLLM's Helm chart always mounts its configuration from a ConfigMap. Renovate, hosted by Mend, only changes version strings: it cannot run a script to copy files (`postUpgradeTasks` is self-hosted only).

## Options considered

How a version is published:

| Option | Pros | Cons |
| -- | -- | -- |
| A. release-please, from the Conventional Commits already enforced on PR titles | The version follows from what was merged (`fix:` patch, `feat:` minor, `!` major); a release PR shows the version and the changelog before anything is tagged | One more PR to merge per release; the PR is opened with `GITHUB_TOKEN`, so no CI runs on it |
| B. A tag pushed by hand (`just release 1.2.0`) | Simplest | The version and the changelog are decided by hand, and easy to get wrong |
| C. Every commit of `main` is a release (`sha-<commit>`) | Nothing to do | No semantic version: Renovate cannot tell a fix from a breaking change, so nothing can be merged automatically |

How the platform learns about it:

| Option | Pros | Cons |
| -- | -- | -- |
| A. Renovate follows the image tags on GHCR | Already runs on the platform (ADR-022); the update is a reviewed PR, tested by the platform's CI, then deployed by ArgoCD | Renovate polls: a release reaches the platform at its next run, within the hour |
| B. The application's workflow opens the PR on the platform | Immediate | A token able to write to another repo, stored in every application repo |
| C. ArgoCD Image Updater | No PR | Writes to Git or overrides it, outside of the PR review and the platform's CI |

What keeps the configuration in step with the image:

| Option | Pros | Cons |
| -- | -- | -- |
| A. The platform's CI compares its copies with the files of the deployed release, and runs the gateway's tests from that release | Renovate's PR stays automatic when the configuration did not change, and fails with the diff when it did; the configuration stays readable and overridable per environment in the platform | A release that changes the configuration needs one commit on the PR (`just gateway-config`) |
| B. The configuration inside the LiteLLM image | One artifact | Fights the chart, which mounts a ConfigMap over it; the configuration of an environment (Kapsule, vLLM) can no longer differ |

## Decision

We choose **release-please**, **Renovate on the image tags**, and a **CI check of the configuration**.

1. In llmops-gateway, release-please keeps a release PR open. Merging it tags `vX.Y.Z`, and the same workflow publishes both images as `X.Y.Z` as well as `sha-<commit>`, with the signature and SBOM of ADR-022.
2. On llmops-platform, Renovate groups the gateway's images into one PR per release. A patch is merged by Renovate once every check passes. A minor needs a merge by hand. A major also needs an approval on the dependency dashboard.
3. Every PR of the platform runs the `gateway-release` job:
   - `scripts/verify-images.sh` checks that every image of our own is signed by `build-image.yml` with an SBOM;
   - `scripts/gateway-release.sh check` checks that the configuration copies match the release.

   The `cluster` job then runs the gateway's integration tests from the tag of the release it deploys.
4. Once merged, ArgoCD deploys it.

## Consequences

- From a merged fix to the cluster without a human:
  1. a `fix:` PR is merged in llmops-gateway;
  2. its release PR is merged;
  3. the signed images `X.Y.Z` are published;
  4. Renovate opens the PR on the platform at its next run;
  5. the PR is merged once the CI passes, about 20 minutes;
  6. ArgoCD syncs.

  Two merges by hand, both in the application repo.
- The signature is checked before the merge, not before Renovate proposes the update: Renovate has no hook for it. A PR towards an unsigned image is opened, then blocked by the `gateway-release` job. Checking signatures at admission in the cluster (Kyverno or Sigstore's policy-controller) is the next step, so a manual `kubectl apply` cannot bypass it either.
- Nothing forces the merge: the repos have no branch protection. Renovate merges only when every check has passed, and a person merging by hand sees the same checks.
- The release PR of llmops-gateway gets no CI, because PRs opened with `GITHUB_TOKEN` trigger no workflow. It only changes the version and `CHANGELOG.md`, and the commits it releases were tested in their own PRs. A GitHub App token would run the CI on it.
- llmops-gateway's first release is v0.2.0. It was meant to be 1.0.0 through `release-as`, but the PR that removed the setting was merged before the release PR, and release-please recomputed the version: a `feat:` before 1.0 bumps the minor. We kept it. A commit with a `Release-As: 1.0.0` footer will mark the stable version.
- Two release-please runs in parallel once built a release PR from the files of one commit on top of a later one: it reverted four dependency updates, and was closed before merging. The release job now runs one at a time (`concurrency`).
- The gateway's tests are now those of the deployed release, not of its `main`. A test changed after a release runs on the platform with the next release.
- We revisit if a release often changes the configuration: the copy could then move to a Helm chart or an OCI artifact published with the release.
