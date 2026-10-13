# Runbook: the gateway's Scaleway budget runs out

**Alert:** `ScalewayBudgetLow`: less than $1 is left of what the gateway may spend at Scaleway Generative APIs over 30 days, every team together.
The cap ($5 per 30 days) is `provider_budget_config` in [`config/litellm.yaml`](../../platform/llm-gateway/base/config/litellm.yaml), a copy of llmops-gateway's. LiteLLM counts the spend in its Redis (`litellm-redis`), so restarts keep it.
Effect once the cap is reached: `chat-pro` is refused, with no fallback; the local aliases go on. The team's own budget in `config/tenants.yaml` still applies on top.

## 1. Who spends it

In Grafana (*Explore*, Prometheus), what each team and key spent at Scaleway over the last 30 days, and what is left:

```promql
sum by (team, api_key_alias) (increase(litellm_spend_metric_total{api_provider="scaleway"}[30d]))
litellm_provider_remaining_budget_metric{api_provider="scaleway"}
```

`litellm_spend_metric_total` restarts from zero with LiteLLM: over a period with restarts, `increase` still adds up the spend, but the cap itself is counted in Redis, not from this metric.

In Langfuse, each team's project shows its `chat-pro` calls and their cost (*Tracing*, filter on the model `mistral-small-3.2-24b-instruct-2506`).

| What you see | Likely cause | Next |
| -- | -- | -- |
| one team, many calls in a short time | a loop in a client (an agent retrying, a batch run on `chat-pro`) | ask the team to stop it; lower its `max_budget` or remove `chat-pro` from its aliases in `config/tenants.yaml` |
| the expected traffic, steadily | the cap is too low for the real use | raise `budget_limit` in llmops-gateway's `config/litellm.yaml`, release it, and deploy it here (ADR-023) |
| the test suite | each run of the integration tests calls Scaleway twice, for less than a hundredth of a cent ($0.00008 measured, `benchmarks/inference/`) | nothing, unless runs are looping |

## 2. Mitigate

- Nothing to do for the local aliases: they are not counted against the cap.
- To stop all spending at once, remove the key: empty `SCW_SECRET_KEY` in the store's `scaleway` secret (locally, in the `.env` of llmops-gateway, then `scripts/seed-local-secrets.sh`), and restart LiteLLM. `chat-pro` then fails with a 500.
- Scaleway's own billing alert, set in its console, is the safety net behind this one: it also sees calls made outside the gateway.
