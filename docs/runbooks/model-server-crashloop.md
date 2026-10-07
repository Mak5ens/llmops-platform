# Runbook: a model server restarts in a loop

**Alert:** `ModelServerCrashLooping` (`ollama` or `ollama-large` today, vLLM at milestone 3): a container has been in `CrashLoopBackOff` for 5 minutes.
Effect: the aliases it serves fail (`chat-small` and `embed` for `ollama`), or fall back (`chat-large` to `chat-small`, after its 20 s timeout). The SLO alerts usually fire too.

## 1. Why it restarts

```bash
kubectl -n llm-gateway get pods -l app.kubernetes.io/name=ollama        # or ollama-large
kubectl -n llm-gateway describe pod -l app.kubernetes.io/name=ollama | sed -n '/Last State/,/Ready/p;/Events/,$p'
kubectl -n llm-gateway logs deployment/ollama --previous --tail=50
kubectl -n llm-gateway logs deployment/ollama -c pull-models --tail=20   # the init container that downloads the models
```

| What you see | Likely cause | Next |
| -- | -- | -- |
| `OOMKilled` in *Last State* | the model needs more memory than the limit (2 GiB for `ollama`, 3 GiB for `ollama-large`) | raise the limit in [`platform/llm-gateway/base/ollama.yaml`](../../platform/llm-gateway/base/ollama.yaml), or use a smaller model; change it in Git |
| the init container fails on `ollama pull` | no access to the model registry, or a model name that does not exist | check the network, and the model names against `config/litellm.yaml` |
| `no space left on device` | the 3 GiB volume is full (a bigger model was added) | raise the PVC size in Git, then delete the pod |
| the readiness probe fails, no error | the node is short of CPU or memory | `kubectl top nodes`, `kubectl -n llm-gateway top pods` |

## 2. Mitigate

- While it is down, `chat-large` still answers through `chat-small`. `chat-small` and `embed` have no fallback.
- Fix the cause in Git and let ArgoCD deploy it. A manual `kubectl edit` is reverted.
- To start from a clean volume: delete the PVC and the pod. The init container downloads the models again, about 2 GB.

## 3. After

Check that the pod is `Running` and `Ready`, that the alias answers (`just test-gateway -k routing`), and that the alert resolves.
