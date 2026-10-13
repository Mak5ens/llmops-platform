# Inference benchmarks

What a call to the gateway's chat models costs in time and money, measured (LAB-137, [ADR-027](../../docs/adr/027-scaleway-generative-apis.md)): `chat-pro` on Scaleway Generative APIs against the local models, through the gateway and as jobs through the queue.

```bash
just bench-inference                                    # chat-small and chat-pro, 20 calls each, and jobs; about 2 min
OLLAMA_GPU_URL=http://localhost:11499 OLLAMA_CPU_URL=http://localhost:11498 just bench-inference   # with local models
```

`chat-pro` calls Scaleway with the key of the cluster's `scaleway` secret (from the `.env` of llmops-gateway): a run costs about a cent. The local models run in Ollama containers of their own, here started with `docker run --gpus all -p 11499:11434 ollama/ollama:0.34.4` and the same without `--gpus` on port 11498, with `qwen2.5:0.5b`, `1.5b` and `7b` pulled.

## Method

- Five French prompts about Formula 1 strategy (an explanation, a decision to justify, a summary, a list, a radio message), sent in turn, at temperature 0, with up to 256 tokens out, streamed. 20 calls per target, after one call that is not counted and loads the model. [`scripts/bench-inference.py`](../../scripts/bench-inference.py).
- **TTFT**: from the request to the first token of text. **Tokens/s**: the tokens after the first, over the time they took: the speed of generation, without the queueing and the reading of the prompt. **Latency**: the whole answer.
- **Cost**: the tokens of each call at the prices of `config/litellm.yaml`, Scaleway's public price for `chat-pro` (€0.15 / €0.35 per million tokens in / out, counted as dollars) and the internal price of ADR-014 for the local aliases. LiteLLM does not send its cost header with streamed answers.
- **Through the gateway** (the k3d cluster, team `f1`): `chat-small`, `qwen2.5:0.5b` on the CPU of a cluster node, and `chat-pro`, Mistral Small 3.2 at Scaleway, in Paris. The `f1` team has no PII masking (race data), so Presidio is not in these times; its cost is measured in llmops-gateway's own benchmark.
- **Directly on Ollama**, on the developer's machine (Intel Core i7-14700KF, NVIDIA RTX 4070 SUPER 12 GB, Docker on WSL2): the real models of `chat-small` (`qwen2.5:0.5b`), `chat-large` (`1.5b`) and `chat-medium` (`7b`), which the cluster replaces with `0.5b` to fit its CI runner.
- **Jobs**: the same prompts as jobs of the `f1` team through `jobs.inference`, from their publication to their reply, one at a time; the first while the workers are at zero, so KEDA starts one.

## Results

Measured on 2026-10-13, from a home connection in France ([`results.md`](results.md), every call in [`results.json`](results.json)):

| Target | Model | TTFT median | TTFT p95 | Tokens/s median | Latency median | Latency p95 | Tokens out median | Cost per 1,000 calls |
| -- | -- | -- | -- | -- | -- | -- | -- | -- |
| chat-small | `chat-small` | 0.05 s | 0.11 s | 111 | 1.47 s | 2.45 s | 163 | $0.07 |
| chat-pro | `chat-pro` | 0.13 s | 0.30 s | 138 | 1.67 s | 2.29 s | 202 | $0.07 |
| Ollama on a GPU, qwen2.5:0.5b | `qwen2.5:0.5b` | 0.01 s | 0.02 s | 411 | 0.28 s | 0.66 s | 113 | - |
| Ollama on a GPU, qwen2.5:1.5b | `qwen2.5:1.5b` | 0.02 s | 0.02 s | 252 | 0.44 s | 1.05 s | 110 | - |
| Ollama on a GPU, qwen2.5:7b | `qwen2.5:7b` | 0.02 s | 0.04 s | 84 | 2.27 s | 3.10 s | 188 | - |
| Ollama on the CPU, qwen2.5:7b | `qwen2.5:7b` | 0.27 s | 0.48 s | 12 | 14.44 s | 22.37 s | 173 | - |

| Jobs through the queue | First job, workers at zero | Next jobs, median | Next jobs, p95 | In the worker, median | Cost per 1,000 jobs |
| -- | -- | -- | -- | -- | -- |
| `chat-pro` | 13.4 s | 1.8 s | 2.8 s | 1.7 s | $0.07 |
| `chat-small` | - | 1.8 s | 2.4 s | 1.7 s | $0.07 |

**A run of the gateway's integration tests** with the key (llmops-gateway v0.4.1 against the cluster, 3 min 43 s) spent **$0.00008** at Scaleway: the two real calls of `chat-pro` (an answer of 20 tokens at most, and the agent's JSON), read on LiteLLM's `litellm_spend_metric_total{api_provider="scaleway"}` in Prometheus over the run. The CI, without a key, spends nothing.

## What the numbers say

- **A 24 B model at Scaleway answers faster than a 7 B model on a gaming GPU.** `chat-pro` writes 138 tokens per second against 84 for `qwen2.5:7b` on the RTX 4070 SUPER, and a 200-token answer takes 1.7 s against 2.3 s. Its first token comes after 0.13 s (0.30 s at p95), the network round trip to Paris included. Only the small local models are faster, and they fail the agent's JSON test (LAB-137).
- **Without a GPU, a local 7 B model is not usable interactively**: 12 tokens per second, 14 s per answer, 22 s at p95. This is what `chat-medium` gives in the compose stack on a machine without an NVIDIA GPU.
- **`chat-pro` costs $0.07 per 1,000 answers of about 200 tokens**: the $5 monthly cap of the gateway pays for about 70,000 of them. Prompts here are short (20 to 50 tokens); a RAG prompt of a few thousand tokens moves the cost to the input side, at €0.15 per million.
- **The queue adds almost nothing once a worker runs**: a job takes 1.8 s from its publication to its reply, of which 1.7 s inside the worker, mostly the call to the gateway. The first job after a quiet period waits 13.4 s for KEDA to start a worker, as measured in the [autoscaling benchmarks](../README.md) (12 to 21 s).
- `chat-small` and `chat-pro` cost about the same per call here: the internal price of `chat-small` ($0.10 / $0.40 per million tokens, ADR-014) is close to Scaleway's price for `chat-pro` (€0.15 / €0.35). That internal price is a convention to make budgets work, not the cost of a GPU.

## Limits

- One run per target, on one evening: Scaleway's serverless models are shared, and their latency varies with the time of day. The p95 says more than the median about what a user may see.
- The prompts are short. Long prompts (RAG context) raise the time to the first token, which these numbers do not show.
- The local models run on a desktop GPU with nothing else on it; the cluster's `chat-small` runs on the CPU of a k3d node, next to the rest of the platform. The two are not the same hardware, so the gateway's own overhead is not isolated here.
