# Runbook: calls to Scaleway fail

**Alert:** `ScalewayErrors`: more than 5 % of the gateway's calls to Scaleway Generative APIs (`chat-pro`, [ADR-027](../adr/027-scaleway-generative-apis.md)) failed over 10 minutes.
Effect: `chat-pro` has no fallback, by design: its callers get the error. Jobs on `chat-pro` are retried (5xx, 408, 429), then dead-lettered after their third failure. The local aliases are not affected.

## 1. Which errors

The *Inference* dashboard, panel *Calls and failures*, splits the failures by status. In Prometheus:

```promql
sum by (exception_status, exception_class) (rate(litellm_deployment_failure_responses_total{api_provider="scaleway"}[10m]))
```

Then LiteLLM's logs: `kubectl -n llm-gateway logs deployment/litellm --since=15m | grep -i scaleway`.

| Status | Likely cause | Next |
| -- | -- | -- |
| 429 | Scaleway's rate limit for the project (requests or tokens per minute) | fewer jobs at a time on `chat-pro` (workers × `WORKER_CONCURRENCY`), or a higher quota from Scaleway's console |
| 401, 403 | the key was revoked or lost the `GenerativeApisModelAccess` permission | a new key in the `.env` of llmops-gateway and in the store's `scaleway` secret (`scripts/seed-local-secrets.sh`), then restart LiteLLM |
| 404 | the model is gone from Scaleway's list | pick another in `config/litellm.yaml` of llmops-gateway, release, deploy; update ADR-027 |
| 408, 5xx | Scaleway slow or down ([status.scaleway.com](https://status.scaleway.com)) | wait; jobs are retried and kept in the dead letter queue after three failures ([`jobs-dead-lettered.md`](jobs-dead-lettered.md)) |

A refused call because the monthly cap is spent is not a Scaleway error: LiteLLM refuses it before calling, see [`scaleway-budget.md`](scaleway-budget.md).

## 2. Mitigate

- Callers that can live with a local model can call `chat-large` instead; the gateway will not switch for them.
- Once Scaleway answers again, replay the dead-lettered jobs ([`jobs-dead-lettered.md`](jobs-dead-lettered.md), step 2).
