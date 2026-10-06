# ADR-019: External Secrets Operator, with a local backend that never touches Git

- **Status:** Accepted
- **Date:** 2026-10-06

## Context

The platform needs secrets that Git must not hold: S3 keys for backups now, then the LiteLLM master key, Langfuse's salts and the model providers' API keys (LAB-127).
In GitOps, everything else comes from Git, so secrets need a path of their own. On Kapsule, Scaleway Secret Manager is the natural store. Locally and in the CI there is no secret manager, and gitleaks fails the CI if a secret shows up in the history.

## Options considered

| Option | Pros | Cons |
| -- | -- | -- |
| A. External Secrets Operator (ESO), v2.11.0 | Reads a secret manager and writes Kubernetes Secrets; a Scaleway provider; secrets rotate in the manager without a commit; templates render config files (SeaweedFS's S3 identities) | One more operator; the secrets live in a second system |
| B. Sealed Secrets | Secrets encrypted in Git, no external system | The key is in the cluster: losing it means re-encrypting everything; rotating a secret takes a commit |
| C. SOPS with age | Encrypted in Git, readable diffs of the keys | ArgoCD needs a plugin to decrypt; an age key to distribute to every machine and to the CI |
| D. Vault or OpenBao | The reference for secrets, dynamic credentials | A stateful service to run, unseal and back up, for a handful of secrets |

For the local backend of ESO:

| Option | Pros | Cons |
| -- | -- | -- |
| A. ESO's Kubernetes provider, reading a `local-secrets` namespace filled with random values by a script | Nothing in Git; the same ExternalSecrets as in the cloud; recreated with every cluster | A script runs before ArgoCD, outside GitOps |
| B. ESO's Fake provider | Fully declarative | The values are in the manifests, so in Git |
| C. OpenBao in dev mode | Closer to a real secret manager | A whole service for the local environment only |

## Decision

We choose **External Secrets Operator**, with one `ClusterSecretStore` named `platform` whose backend changes per environment:
locally, Kubernetes Secrets in `local-secrets`, written with random values by `scripts/seed-local-secrets.sh`, which `just bootstrap` runs;
on Kapsule, Scaleway Secret Manager, filled by Terraform.

ESO keeps the secrets out of Git without any key to distribute, and the ExternalSecrets of each application stay the same in every environment.

## Consequences

- No secret value in Git, checked by gitleaks on the whole history in the CI.
- The seed script keeps existing secrets: re-running the bootstrap does not change a key that a database or SeaweedFS already uses.
- ESO is installed from its Helm chart, through Kustomize, because the static manifest of the release hardcodes the `default` namespace. ArgoCD runs Kustomize with `--enable-helm`, which LAB-127 also needs for the LiteLLM and Langfuse charts.
- Scaleway names secrets with a prefix (`name:s3-backup`), where the Kubernetes provider takes the bare name: the cloud overlay will patch the keys (LAB-132).
- Passwords that an operator can generate are not in the store: CloudNativePG creates the database credentials itself ([ADR-018](018-postgresql-cloudnativepg.md)).
- We revisit this if the platform needs dynamic credentials (short-lived database users), which would point to OpenBao.
