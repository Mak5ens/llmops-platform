# Runbook: the gateway returns 5xx

**Alert:** `GatewayAvailabilityBudgetBurn` (SLO `availability` of `llm-gateway`, [slo/gateway.yaml](../../slo/gateway.yaml)).
`severity: critical` (page) means the error budget of 30 days goes in a few hours or days at this rate; `severity: warning` (ticket) means it goes before the end of the period.

What counts: responses 5xx from LiteLLM on `https://llm.localtest.me`, as Envoy sees them. 4xx (a refused key, a budget or a rate limit) do not count.

## 1. How bad, since when

Grafana, dashboard **SLO / Detail** (`sloth_service=llm-gateway`, `sloth_slo=availability`): error rate, burn rate, budget left.
Dashboard **Gateway**: requests per second by status; a dot on the latency graph opens a request's trace.

Last failed requests, with their trace ID: Grafana, Explore, Loki, `{service_name="platform.gateway"} |~ "\" 5[0-9][0-9] "`.

## 2. Which part fails

The path of a call: Envoy → LiteLLM → Presidio (masked teams) → Ollama (vLLM later) → Langfuse (traces, asynchronous).

```bash
kubectl -n llm-gateway get pods
kubectl -n llm-gateway logs deployment/litellm --since=15m | grep -E 'ERROR|Exception|APIConnectionError' | tail -30
```

| What the logs say | Likely cause | Next |
| -- | -- | -- |
| `APIConnectionError` to `ollama...:11434` | a model server is down or restarting | [model-server-crashloop.md](model-server-crashloop.md); `chat-large` falls back to `chat-small`, the others do not |
| errors from the `pii-fr` guardrail, 500 for masked teams | Presidio Analyzer or Anonymizer down (the guardrail fails closed: nothing reaches the model) | `kubectl -n llm-gateway rollout status deployment/presidio-analyzer`; it needs 1.6 GiB and about a minute to load its models |
| database errors, `prisma` | `litellm-db` failing over or down | `kubectl -n llm-gateway get cluster litellm-db`; a failover takes about 20 s |
| no LiteLLM log for the failed requests | LiteLLM itself is down: Envoy answers 503 | `kubectl -n llm-gateway describe pod -l app.kubernetes.io/name=litellm` |
| `upstream request timeout` in Envoy's log | a call took more than the route's 90 s | see [gateway-latency.md](gateway-latency.md) |

## 3. Mitigate

- A model server down: restart it (`kubectl -n llm-gateway rollout restart deployment/ollama`), or, if a release broke it, revert the commit in Git: ArgoCD deploys the previous version.
- A bad configuration (`config/litellm.yaml`, `tenants.yaml`): revert the commit. Do not edit the cluster by hand, ArgoCD reverts it within minutes.
- Presidio down for good: there is no bypass on purpose, masked teams must not send personal data unmasked.

## 4. After

- Check that the alert resolves and that the error rate is back to zero on the SLO dashboard.
- Write down the start, the end, the cause and the budget spent. If the cause is new, add a row to the table above.
