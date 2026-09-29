# ADR-003: Terraform rather than OpenTofu

- **Status:** Accepted
- **Date:** 2026-09-28

## Context

The cloud cluster, its node pools, the network and the registry access are described as code, so the whole platform can be created and destroyed on demand (ADR-002).
Two tools read the same language (HCL) and the same providers:

- **Terraform**, by HashiCorp. On August 10, 2023, its license changed from MPL 2.0 to the Business Source License 1.1 (BUSL), which is not an open-source license. IBM completed its acquisition of HashiCorp on February 27, 2025.
- **OpenTofu**, the fork of the last MPL version, accepted by the Linux Foundation on September 20, 2023, generally available since version 1.6.0 on January 10, 2024, and a CNCF sandbox project since April 23, 2025.

## Options considered

| Option | Pros | Cons |
| -- | -- | -- |
| A. Terraform | The name job offers ask for; largest base of documentation, modules and answers | BUSL: the license forbids offering a product that competes with HashiCorp, and its terms can change again under IBM |
| B. OpenTofu | MPL 2.0, open governance under the Linux Foundation and the CNCF; compatible with Terraform code up to 1.5 and its providers; extra features such as state encryption | Less visible in job offers; features drift apart over time, so switching back gets harder |

## Decision

We choose **A**, Terraform.
The BUSL restricts products that compete with HashiCorp; an internal platform that provisions its own cluster is not one, so the license does not constrain this use.
The portfolio shows the tool most teams run today, and this ADR shows the license question was weighed.

## Consequences

- Code stays within the language shared by both tools: no feature specific to Terraform or to OpenTofu, so switching is changing the binary in CI and running `init` again.
- The Terraform version is pinned in CI and in `required_version`.
- We revisit this if HashiCorp or IBM changes the terms again, if the Scaleway provider stops supporting Terraform, or if a target employer standardizes on OpenTofu.
