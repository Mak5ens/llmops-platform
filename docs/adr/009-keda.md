# ADR-009: KEDA to scale the job workers, rather than an HPA alone

- **Status:** Accepted
- **Date:** 2026-10-13

## Context

The job workers (llmops-gateway's `worker/`, [`platform/job-worker/`](../../platform/job-worker/)) consume `jobs.inference` on RabbitMQ ([ADR-004](004-rabbitmq.md)) and call the gateway, which calls the model. They must run only when there is work: zero workers on an empty queue, then as many as the jobs need, up to 6, the most the 16 GB CI runner holds next to the rest of the platform.

What a worker does is wait. During a peak of 302 `chat-pro` jobs on 2026-10-13, with up to 180 jobs in the queue, each of the 6 workers used 2 to 3 millicores of CPU on average and 21 at most, for a request of 50; its memory stayed between 56 and 70 MiB. The load of a worker is the queue, not its CPU or its memory: the model works elsewhere (Scaleway, Ollama), and a worker held by a rate limit does nothing at all.

On Kubernetes 1.37, the version of the k3d cluster, the `HPAScaleToZero` feature gate is beta and enabled: an HPA alone can now go down to zero replicas on an external metric, which it could not when the platform was planned.

## Options considered

| Option | Pros | Cons |
| -- | -- | -- |
| A. HPA on CPU or memory | Built in, nothing to install | The wrong signal: in the peak above, a CPU target of 70 % of the request would never have added a worker. No scale to zero on a resource metric |
| B. HPA on an external metric, through Prometheus Adapter, with `minReplicas: 0` | Built in, plus one adapter; the queue length is already in Prometheus | The queue reaches the HPA through Prometheus's scrape (30 s here) on top of RabbitMQ's own statistics (5 to 12 s): a later cold start, not measured here. Autoscaling depends on Prometheus being up. The scale to zero is a beta feature, and the adapter's rules are a query language of their own to maintain |
| C. KEDA `ScaledObject` with its RabbitMQ scaler | Reads RabbitMQ's management API directly, every 5 s, with the jobs held by workers counted, so busy workers are not scaled down; takes the workers from 0 to 1 and back itself (activation, `cooldownPeriod`), and hands 1 to N to an HPA it manages; a CNCF graduated project, installed from its release manifest | One more operator: three pods, 112 MiB in all on the cluster; the HPA behind it keeps its own behaviour (see Consequences) |
| D. KEDA `ScaledJob`, a Kubernetes Job per message | No long-running consumer at all | A pod start (several seconds) for each job of a few seconds; the worker's concurrency, graceful stop and connection reuse are lost |

## Decision

We choose **C, KEDA's `ScaledObject` with the RabbitMQ scaler**: it scales on the signal that matters, the jobs in the queue, read straight from RabbitMQ, without Prometheus in the loop, and the 0 ↔ 1 transitions are its job, separate from the HPA's.

The settings come from the load tests of LAB-136 ([`benchmarks/README.md`](../../benchmarks/README.md)), five settings over three k6 scenarios:

| Setting | Value | Measured reason |
| -- | -- | -- |
| Jobs per worker | 2 | a worker runs 2 jobs at a time: once the workers have caught up, no job waits |
| Zero workers after | 60 s | 30 s cost a second burst a cold start: 31.9 s median latency against 11.3 s |
| HPA scale-down window | 120 s | 300 s, Kubernetes' default, kept 6 workers for a load that needed 3; 30 s made them flap and slowed the jobs (4.0 s median against 2.4 s) |
| Polling | every 5 s | the first job is answered 12 to 21 s after its publication with every setting tried |

## Consequences

- From zero, the first job waits 12 to 21 s: RabbitMQ's statistics show it to KEDA 5 to 12 s late, then KEDA's polling, the pod's start and the 2 s of the job. KEDA's settings do not shorten it; RabbitMQ's statistics interval would.
- From one to six workers, the HPA's own pace applies: at most 4 more pods, or twice as many, every 15 s, so 1 → 5 → 6 in two of its cycles.
- The HPA behind KEDA remembers its replica counts for its scale-down window, across KEDA's scale to zero: a job arriving within that window restarts the workers at the previous peak (`New size: 6; reason: All metrics below target`). The load tests recreate the HPA before each run for that reason.
- Scaling on the queue ignores what the jobs call: with the `f1` team's key at 60 requests a minute, 6 workers asked for more and got 429s. The worker now waits for the limit to reset and gives the job back without spending an attempt (LAB-194); some workers wait while the limit holds. Capping the workers per team would need a scaler per team's queue.
- Alerts follow the same signal: `JobsBacklogAtMaxWorkers` fires when the queue grows for 10 minutes with every worker busy.
- We revisit this if the cluster drops KEDA for another reason, or if `HPAScaleToZero` becomes stable and a scaler that reads RabbitMQ directly appears for the HPA: then option B loses its Prometheus delay and its extra moving part.
