# Runbook: the gateway is slow

**Alert:** `GatewayLatencyBudgetBurn` (SLO `latency` of `llm-gateway`, [slo/gateway.yaml](../../slo/gateway.yaml)): too many requests take more than 30 s, from the request to the last byte of the answer.

## 1. Find slow requests

Grafana, dashboard **Gateway**: the dots on the latency graph are requests; click a slow one to open its trace, then *Logs for this span*.

## 2. Usual causes

| Symptom | Likely cause | Next |
| -- | -- | -- |
| slow calls are on `chat-large` and end on `chat-small` | the `chat-large` server is down: each call waits for its 20 s timeout, then falls back | [model-server-crashloop.md](model-server-crashloop.md) |
| every alias is slow, model servers use all their CPU | more traffic than the CPUs can serve (Ollama on CPU) | lower `max_tokens` on the teams' side, or add capacity; vLLM on GPU at milestone 3 |
| slow for masked teams only | Presidio Analyzer under load | `kubectl -n monitoring top pods` and `kubectl -n llm-gateway top pods` |
| requests cut at 90 s (`upstream request timeout`) | the route's timeout, above LiteLLM's 60 s cap | a call that long is already failing: check the model server |

## 3. After

Same as for 5xx: check that the burn rate goes down on the SLO dashboard, and write down cause and budget spent.
