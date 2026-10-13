# ADR-027: Commercial models on Scaleway Generative APIs, local models on Ollama

- **Status:** Accepted
- **Date:** 2026-10-13

## Context

The managed cluster with rented GPUs is dropped (ADR-002, update of 2026-10-11): the platform has no GPU of its own beyond the developer's machine.
The client apps still need a model better than what a laptop or the 16 GB CI runner can serve: the F1 agent asks for answers in French, tool calls and a JSON schema followed reliably, which only models of a few billion parameters or more do (the agent JSON test of llmops-gateway fails on every model under 3 B, LAB-137).
The company in the scenario is French and handles personal data: a prompt that leaves the gateway goes to an EU provider, after the `pii-fr` guardrail.

Since llmops-gateway 0.4.0 (LAB-185), the gateway has two kinds of aliases: local ones on Ollama (`chat-small`, `chat-medium`, `chat-large`, `embed`, priced internally by ADR-014 there) and a commercial one, `chat-pro`, on Scaleway Generative APIs, capped at $5 per 30 days.

## Options considered

Where the commercial model runs:

| Option | Pros | Cons |
| -- | -- | -- |
| A. Scaleway Generative APIs, serverless | Paris, OpenAI-compatible, billed per token: €0.15 / €0.35 per million tokens in / out for Mistral Small 3.2 (Scaleway price list, October 2026); nothing to start or stop; LiteLLM has a `scaleway` provider | No control over the model's version or its latency; a key to keep out of Git and of the CI |
| B. A dedicated GPU (Scaleway L4, vLLM) | Any open model, our own latency profile, no per-token bill | €0.79 per hour, €577 a month if always on: that money buys about 1.6 billion output tokens of option A; a GPU to start, stop and monitor; the cluster that was to host it is dropped |
| C. A US provider's API | Strongest models | Data under a non-EU provider, against the GDPR argument of the portfolio |

Which aliases move there:

| Option | Pros | Cons |
| -- | -- | -- |
| A. Only commercial aliases (`chat-pro`), local ones stay on Ollama | The CI runs without a key and costs nothing; the stack works offline; the 768-dimension embeddings of the F1 app keep their index | Local aliases keep their quality limits on the cluster (stand-in models, LAB-137) |
| B. Every alias on Scaleway | One quality level everywhere | `embed` would change dimension (3,584 or 4,096 against 768): a reindex for the F1 app; every CI run needs a key and costs money; no offline mode |

The model of `chat-pro`, among the models Scaleway lists without a preview label (October 2026):

| Model | In / out, € per million tokens | For | Against |
| -- | -- | -- | -- |
| `mistral-small-3.2-24b-instruct-2506` | 0.15 / 0.35 | Cheapest chat model listed; written in France, strong in French; tool calls, JSON mode, vision, 128k context | Less reasoning than the larger models |
| `gpt-oss-120b` | 0.15 / 0.60 | Stronger reasoning at the same input price | Its reasoning tokens are billed as output: a longer, pricier answer for the same question |
| `gemma-4-26b-a4b-it` | 0.25 / 0.50 | Fast (4 B active parameters), vision | Pricier than Mistral Small on both sides |
| `mistral-medium-3.5-128b` | 1.50 / 7.50 | The strongest Mistral listed | 10 to 20 times the price |

## Decision

We choose **Scaleway Generative APIs for the commercial aliases only**, with **Mistral Small 3.2** behind `chat-pro`, and keep the local aliases on Ollama.

Measured on 2026-10-13 ([`benchmarks/inference/`](../../benchmarks/inference/README.md), 20 streamed calls per target, answers of about 200 tokens):

| | `chat-pro`, Scaleway (24 B) | `qwen2.5:7b` on an RTX 4070 SUPER | `qwen2.5:7b` on the CPU |
| -- | -- | -- | -- |
| First token, median (p95) | 0.13 s (0.30 s) | 0.02 s (0.04 s) | 0.27 s (0.48 s) |
| Tokens per second, median | 138 | 84 | 12 |
| Answer, median (p95) | 1.7 s (2.3 s) | 2.3 s (3.1 s) | 14.4 s (22.4 s) |
| Cost per 1,000 answers | $0.07 | the machine | the machine |

A 24 B model at Scaleway answers faster than a 7 B one on a desktop GPU, for $0.07 per 1,000 answers: the gateway's $5 cap pays for about 70,000 of them a month. A local 7 B model without a GPU is not usable interactively, and the cluster's CI runner cannot hold one at all.

## Consequences

- The integration tests call Scaleway twice per run, for $0.00008. llmops-gateway's CI has the key (repository secret `SCW_SECRET_KEY`), so a release is tested against the real model; llmops-platform's CI has none and skips `chat-pro`'s tests, which run locally with the key of `.env`. Without a key, nothing else breaks.
- The key lives in the `.env` of llmops-gateway and in the store's `scaleway` secret on the cluster, never in Git. The spend is capped twice: LiteLLM's provider budget ($5 per 30 days, counted in Redis, alert `ScalewayBudgetLow`) and Scaleway's own billing alert.
- Prices are Scaleway's in euros, written as they are in `config/litellm.yaml`, whose unit is the dollar: the "$5" cap is €5 of Scaleway's bill, and so are the costs in this ADR.
- The local aliases are not production quality on the cluster: it serves them with `qwen2.5:0.5b` to fit the CI runner. They show routing, fallback, masking and cost, not answers.
- We revisit the model when the F1 evaluation (milestone 3.3) shows that Mistral Small misses answers a larger model gets right, and the provider if Scaleway stops listing a model in the price range, or if the monthly spend comes near the price of a dedicated GPU.
