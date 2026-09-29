# ADR-004: RabbitMQ rather than Redis Streams or NATS JetStream

- **Status:** Accepted
- **Date:** 2026-09-28

## Context

Long inference jobs (batch analyses, document checks) go through a queue: the API accepts the job, workers running vLLM consume it, and KEDA scales the workers from 0 to N on the queue length.
A job can fail on a worker crash, an out-of-memory error or a model timeout. The queue must retry it a bounded number of times, then set it aside in a dead letter queue for inspection, without code of our own for that path.
All three candidates have a KEDA scaler, so autoscaling does not decide between them.

## Options considered

| Option | Pros | Cons |
| -- | -- | -- |
| A. RabbitMQ (quorum queues) | Retry and dead lettering are native: since RabbitMQ 4.0, quorum queues stop redelivering a message after 20 attempts by default, and dead-letter it with at-least-once guarantees (RabbitMQ docs); acknowledgments per message; the Cluster Operator runs it on Kubernetes | One more stateful system to operate; not suited to replaying a history of events |
| B. Redis Streams | Often already in the stack (Langfuse uses Redis); simple; very fast | No dead letter queue: the application reads delivery counts with `XPENDING` / `XAUTOCLAIM` and moves failed entries itself; licensing moved from BSD to SSPL/RSAL in March 2024, then added AGPLv3 with Redis 8 in May 2025 |
| C. NATS JetStream | Light, fast, good at streams and replay | No dead letter queue: after `MaxDeliver` attempts a message is dropped with an advisory, and a DLQ must be built from those advisories |

## Decision

We choose **A**, RabbitMQ with quorum queues.
The failure path of a job queue is where bugs hide; RabbitMQ gives retries and a dead letter queue as configuration, where the other two need code we would have to write and test.

## Consequences

- Each job queue declares a delivery limit and a dead-letter exchange; a failed job lands in a DLQ that is monitored and can be replayed by hand (LAB-134).
- RabbitMQ runs through its Kubernetes operator with persistent volumes, and exports metrics to Prometheus.
- The platform does not use RabbitMQ for event streaming; if that need appears, Kafka or NATS is evaluated in a new ADR.
- We revisit this if throughput needs exceed what one small cluster sustains, which is far above the job rates of this platform.
