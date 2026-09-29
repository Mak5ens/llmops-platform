# ADR-006: Self-hosted Langfuse rather than Langfuse Cloud

- **Status:** Accepted
- **Date:** 2026-09-28

## Context

Every LLM call is traced with its prompt, answer, latency, tokens and cost per team, from milestone 1.3 of the gateway.
Prompts from the lease compliance tenant contain personal data. Presidio anonymizes them before inference, but no detector reaches 100 %: the benchmark of milestone 1.2 measures its detection rate on 100 annotated texts, and whatever it misses would end up in the traces.
Under the GDPR, sending those traces to a SaaS makes its vendor a processor: a data processing agreement, a transfer analysis and an entry in the records of processing.

## Options considered

| Option | Pros | Cons |
| -- | -- | -- |
| A. Self-hosted Langfuse | Traces never leave the company; open source under the MIT license, apart from enterprise folders; no limit on events or retention | Four stateful services to run: PostgreSQL, ClickHouse, Redis and S3-compatible storage (Langfuse docs), plus backups and upgrades |
| B. Langfuse Cloud, EU region | Nothing to operate; free Hobby plan (50k units per month, 30 days of retention), Core at $29 per month (Langfuse pricing, September 2026) | Traces, including any personal data missed by Presidio, stored by a processor; retention and volume tied to the plan |
| C. No LLM tracing, only metrics | Simplest | No per-call debugging, no datasets for evaluation, no cost per team at the call level |

## Decision

We choose **A**, self-hosted Langfuse from milestone 1 onwards, in the gateway's Docker Compose and later on the cluster.
It turns the privacy promise of the portfolio into a checkable fact: no trace leaves the company, and an automated test checks that traces hold no personal data (LAB-119).

## Consequences

- The local stack grows by several containers; the gateway CI job must stay under 10 minutes with them.
- On the cluster, PostgreSQL goes through CloudNativePG; ClickHouse, Redis and object storage get backups and are covered by the SLOs.
- Upgrades follow Langfuse releases through Renovate; major versions can change the storage layout, so they are tested locally first.
- We revisit this if running the four services costs more time than the compliance work of a SaaS, for example in a company that already has a data processing framework with Langfuse.
