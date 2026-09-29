# ADR-002: Scaleway rather than OVHcloud

- **Status:** Accepted
- **Date:** 2026-09-28

## Context

Block 2 runs the platform on a managed Kubernetes cluster with GPU nodes for vLLM.
GPUs are rented for a few hours only, for the final measurements, then everything is destroyed with `terraform destroy`: the hourly GPU price and the ease of adding a GPU node pool matter more than monthly commitments.
The company in the scenario is French and handles personal data: hosting stays in the EU, with a European provider.

## Options considered

| Option | Pros | Cons |
| -- | -- | -- |
| A. Scaleway Kapsule + GPU Instances | L4 GPU (24 GB) at €0.79 per hour, billed hourly (Scaleway price list, September 2026); control plane free; GPU node pools in Kapsule come with the NVIDIA GPU Operator installed, which installs the drivers; official Terraform provider | Fewer regions; the larger GPUs (L40S, H100) are only in the PAR-2 zone |
| B. OVHcloud Managed Kubernetes + Public Cloud GPU | Free control plane on the Free plan; L4 instances in the same price range (L4-90 listed at $0.88 per hour by a third-party tracker in September 2026, with more RAM and vCPUs); SecNumCloud-qualified offers for later needs | GPU drivers and operator to set up ourselves on the node pool; hourly or monthly billing chosen at creation and not switchable |
| C. A US hyperscaler (AWS, GCP, Azure) | Most job offers mention one; richest managed services | Data under a non-EU provider, against the GDPR argument of the portfolio; GPU quotas to request on a new account |

## Decision

We choose **A**, Scaleway.
Prices are close between the two French providers, so the decision rests on the GPU path: a Kapsule GPU node pool comes up with drivers ready, which keeps the "rent for a few hours, measure, destroy" loop short and scripted in Terraform.

## Consequences

- The Terraform code targets the `scaleway` provider; locally, k3d replaces Kapsule with the same manifests.
- A GPU session of a few hours costs a few euros: the budget of block 2 is dominated by the time GPUs stay up, which the runbooks keep short.
- The cluster uses a small set of zones; multi-region resilience is out of scope.
- We revisit this if a need for SecNumCloud qualification appears, or if the L4 is no longer available at a similar price, in favor of OVHcloud.
