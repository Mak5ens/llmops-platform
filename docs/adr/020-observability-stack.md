# ADR-020: Observability with Prometheus, Loki and Tempo, fed by one OpenTelemetry Collector

- **Status:** Accepted
- **Date:** 2026-10-07

## Context

The platform needs metrics, logs and traces that lead to one another: from a latency spike of the gateway, a click must open the trace of a slow request, and another its logs (LAB-128).
The stack must fit next to everything else on the local cluster and on a CI runner, which has 16 GB for the whole platform. Before this ADR, the platform already took about 13 GB.
Two parts of the usual setup moved in 2026. Promtail, Loki's own log agent, reached end of life. Grafana Labs handed the Loki and Tempo Helm charts to the community repository `grafana-community/helm-charts`, which is where new versions are released.

## Options considered

For storage and display, the choice is open source and self-hosted (the cluster also runs on k3d, without internet services). Prometheus, Loki, Tempo and Grafana are the market standard for that, so the questions are how to run them and what feeds them.

How to run Loki and Tempo:

| Option | Pros | Cons |
| -- | -- | -- |
| A. One process each (Loki single binary, Tempo monolithic), on a volume | Two pods, about 1 GB of RAM together; nothing else to run | No horizontal scaling; a pod restart pauses ingestion |
| B. Microservices (distributed charts) on S3 | Scales each path apart, as in production at large scale | A dozen pods and caches (Memcached) for a few requests per second |

What collects and ships telemetry:

| Option | Pros | Cons |
| -- | -- | -- |
| A. The OpenTelemetry Collector, as a DaemonSet | One vendor-neutral agent for the three signals: pod logs (filelog), OTLP from applications, Kubernetes attributes; the protocol applications already speak | Its configuration is more verbose than Alloy's for logs |
| B. Grafana Alloy | Promtail's successor, good Loki integration | Ties collection to Grafana's stack; a second agent anyway if applications send OTLP elsewhere |
| C. Promtail | Simple | End of life |

Where the gateway's latency comes from:

| Option | Pros | Cons |
| -- | -- | -- |
| A. Envoy, at the Gateway: OpenTelemetry tracing of every request, access logs with the trace ID, span metrics with exemplars from Tempo | Covers every route (LiteLLM, Langfuse, Grafana, ArgoCD) without touching the applications; the latency a client sees | Does not see inside LiteLLM: guardrail, model call, fallback |
| B. LiteLLM's own OpenTelemetry spans | Shows the steps of a call | Spans may hold prompts, so personal data: it needs its own leak test first, as for Langfuse in block 1 |

## Decision

We choose **Prometheus, Loki and Tempo in their smallest form** (kube-prometheus-stack; Loki and Tempo as one process each), **fed by one OpenTelemetry Collector** on every node, and **Envoy as the source of the gateway's telemetry**.

- Envoy traces every request locally and sends its access logs over OTLP, with the trace ID of the request.
- Tempo's metrics generator turns the spans into rate and latency metrics, with exemplars (trace IDs), and pushes them to Prometheus.
- Grafana's datasources link the three: an exemplar opens its trace, and a trace opens its logs.

## Consequences

- `scripts/observability-check.sh` follows the two clicks on every PR: an exemplar of the latency graph, its trace in Tempo, its logs in Loki.
- The control plane is not scraped. It is embedded in k3s and managed on Kapsule, and its rules would fire for missing targets.
- Retention is 2 days for metrics, 48 h for logs and 24 h for traces, on 5 GB volumes. That is enough to debug a PR or a demo, not to keep a history.
- LiteLLM's spans join the traces later, behind a leak test on what Tempo stores (LAB-129 or later).
- Envoy samples 100 % of requests. On Kapsule, with real traffic, the sampling rate goes down and the exemplars stay.
- We revisit option B (microservices on Object Storage) when logs or traces outgrow one process, or when retention must reach weeks.
