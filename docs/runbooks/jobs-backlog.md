# Runbook: jobs pile up with every worker busy

**Alert:** `JobsBacklogAtMaxWorkers`: the jobs waiting in `jobs.inference` have grown for 10 minutes while the workers are at the maximum of their `ScaledObject` (6, [`platform/job-worker/base/autoscaling.yaml`](../../platform/job-worker/base/autoscaling.yaml)).
Effect: no job is lost, but each new one waits longer. Nothing fails until a producer gives up waiting.

The *Inference* dashboard shows it on one time axis: *Jobs in the queue* grows, *Workers* is at *at most*, and *Jobs answered* tells whether the workers still answer at their usual pace.

## 1. Why

| What you see | Likely cause | Next |
| -- | -- | -- |
| *Jobs answered* at its usual pace, more jobs published than usual | a larger batch than the workers can take (a season of F1 sessions) | let it drain, or raise `maxReplicaCount` if the cluster has room (`kubectl top nodes`) |
| *Jobs answered* low, *Time to first token* or failures up | the model is slow or failing: the workers wait on the gateway | follow the model: [`scaleway-errors.md`](scaleway-errors.md) for `chat-pro`, [`model-server-crashloop.md`](model-server-crashloop.md) for a local alias |
| *Jobs answered* low, models fine, workers restarting | the workers themselves (`OOMKilled`, crash) | `kubectl -n jobs get pods`, `kubectl -n jobs logs deployment/worker --previous` |

## 2. Mitigate

- Raising `maxReplicaCount` in Git helps only if the model is not the limit: more workers on a slow model only add calls that wait.
- Each worker runs 2 jobs at a time (`WORKER_CONCURRENCY`); jobs of 30 s or more may justify more per worker on a remote model like `chat-pro`, whose limit is Scaleway's, not the cluster's.
- A job that waits long is still answered: its reply goes to its `reply_to` queue whenever it runs.
