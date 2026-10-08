# ADR-022: One build workflow for every image: Trivy gate, Syft SBOM, keyless cosign signature

- **Status:** Accepted
- **Date:** 2026-10-08

## Context

The platform runs images built by its own repos: the French Presidio Analyzer and LiteLLM with its guardrail (llmops-gateway), and soon the F1 application. Nothing said what they contain, who built them, or that they were not changed after the build (LAB-130).
The first scan made the gap concrete. The two gateway images in production had 10 and 9 critical CVEs with a fix available. One of them was in LiteLLM itself: CVE-2026-49468, an authentication bypass through the `Host` header, CVSS 9.5, fixed in 1.84.0.
CI tooling is itself an attack surface. On March 19, 2026, 76 of the 77 tags of `aquasecurity/trivy-action` were moved to code that stole the secrets of the pipelines running it (CVE-2026-33634).

## Options considered

Where the build logic lives:

| Option | Pros | Cons |
| -- | -- | -- |
| A. A reusable workflow in llmops-platform, called by every repo | One gate for every image, changed in one place; the signing certificate names this workflow, so a signature proves the image went through it | Callers depend on this repo; a change here affects every repo at once |
| B. A copy of the steps in each repo | Each repo is independent | The gate drifts apart between repos; a signature only proves "built by some workflow of that repo" |

Which images the scan blocks:

| Option | Pros | Cons |
| -- | -- | -- |
| A. Critical CVEs that have a fix | Every block can be acted on: upgrade the package or the base image | A critical CVE without a fix passes, reported in the logs |
| B. Every critical CVE | Strictest | Blocks on CVEs nobody can fix yet, which leads to blanket exceptions |
| C. Report only | Never blocks | A report nobody reads |

How images are signed:

| Option | Pros | Cons |
| -- | -- | -- |
| A. cosign keyless (GitHub OIDC, Sigstore's Fulcio and Rekor) | No key to store or rotate; the certificate names the workflow and the commit; the signature is in a public transparency log | Depends on Sigstore's public services |
| B. cosign with a key pair | Works offline | A private key to protect and rotate, in a secret the workflow can read |
| C. GitHub artifact attestations | Native to GitHub | `gh attestation verify` rather than `cosign verify`; ties verification to GitHub's API |

## Decision

We choose a **reusable workflow in llmops-platform** (`.github/workflows/build-image.yml`), a **Trivy gate on critical CVEs that have a fix**, and **keyless cosign**. The workflow:

1. builds the image and scans it with Trivy;
2. on `main`, publishes it to GHCR;
3. generates its SBOM with Syft (SPDX JSON);
4. signs the image and attaches the SBOM as a signed attestation;
5. verifies both before ending.

Every action in it is pinned to a commit SHA, and Trivy is installed from its release, checked against a pinned SHA-256.

## Consequences

- An image is verified with:

  ```bash
  cosign verify --certificate-identity-regexp '^https://github.com/Mak5ens/llmops-platform/\.github/workflows/build-image\.yml@' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com ghcr.io/mak5ens/llmops-gateway/litellm:sha-<commit>
  ```

  `cosign verify-attestation --type spdxjson` with the same options returns the SBOM.
- The gate tests itself: the CI of this repo builds an image with known critical CVEs (`.github/fixtures/vulnerable-image`) and fails if the scan lets it through.
- To pass the gate, the gateway moved from LiteLLM 1.83.14 to 1.104.1, which closes CVE-2026-49468. The Presidio Analyzer image gets its Debian packages and anyio upgraded on top of Microsoft's last image (2.2.362).
- The Presidio Anonymizer runs Microsoft's image unchanged: the gate covers the images we build, not third-party ones. Scanning what runs in the cluster (Trivy Operator) is a next step.
- Renovate updates the pinned SHAs and versions, so pinning does not mean freezing.
- We revisit if Sigstore's public services become a constraint (outages, regulation): cosign with a key held in a KMS.
