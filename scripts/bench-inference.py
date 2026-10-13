"""Latency, throughput and cost of the gateway's chat models (LAB-137).

Each target gets the same French prompts, streamed, at temperature 0, with up to 256 tokens out: the time to the
first token, the throughput after it, the total latency, and the cost of the tokens used at the prices of
config/litellm.yaml (Scaleway's public price for chat-pro, internal prices for the local aliases, ADR-014; LiteLLM
does not send its cost header on streamed answers). One call per target first, not counted, loads the model.

With BENCH_RABBITMQ_URL (RabbitMQ's management API, http://user:password@host:port), it also sends jobs through the
queue for each alias of BENCH_JOB_ALIASES (default chat-pro): the first while the workers are at zero, then one at a
time, timed from their publication to their reply. KEDA starts the workers.

Usage: uv run --with openai --with pyyaml scripts/bench-inference.py <results dir> <runs> <label>=<base url>|<model>...
The key of every target is BENCH_API_KEY (a team key of the gateway; Ollama ignores it). A target whose model is an
alias of platform/llm-gateway/base/config/litellm.yaml is priced at that alias's price.
Writes <results dir>/results.md (the tables) and results.json (every call); `<results dir> --render` writes the
tables again from results.json.
"""

import base64
import json
import os
import statistics
import sys
import time
import urllib.request
from pathlib import Path

import yaml
from openai import OpenAI

CONFIG = Path(__file__).resolve().parent.parent / "platform/llm-gateway/base/config/litellm.yaml"

PROMPTS = [
    "Explique en trois phrases ce qu'est un undercut en Formule 1.",
    ("Un pilote a des pneus durs usés de 25 tours et la voiture de sécurité sort. Doit-il s'arrêter ? Justifie en un "
    "paragraphe."),
    "Résume la règle des deux composés de pneus obligatoires en course sèche, pour un débutant.",
    "Donne trois questions qu'un ingénieur de course pose avant de choisir une stratégie à un arrêt.",
    "Rédige un court message radio, calme et précis, pour annoncer au pilote un arrêt au prochain tour.",
]
MAX_TOKENS = 256


def call(client: OpenAI, model: str, prompt: str) -> dict:
    start = time.perf_counter()
    first = None
    chunks = 0
    usage = None
    with client.chat.completions.with_streaming_response.create(
        model=model,
        messages=[{"role": "user", "content": prompt}],
        max_tokens=MAX_TOKENS,
        temperature=0,
        stream=True,
        stream_options={"include_usage": True},
    ) as response:
        for chunk in response.parse():
            if chunk.usage:
                usage = chunk.usage
            if chunk.choices and chunk.choices[0].delta.content:
                chunks += 1
                if first is None:
                    first = time.perf_counter()
    end = time.perf_counter()
    tokens = usage.completion_tokens if usage else chunks
    return {
        "ttft": first - start,
        "total": end - start,
        "tokens_out": tokens,
        "tokens_in": usage.prompt_tokens if usage else None,
        # Throughput after the first token: the model's generation speed, without the queueing and the prompt.
        "tokens_per_s": (tokens - 1) / (end - first) if tokens > 1 and end > first else None,
    }


class Rabbit:
    """The few calls of RabbitMQ's management API the jobs need, as the k6 scenarios use it (benchmarks/k6)."""

    def __init__(self, url: str) -> None:
        scheme, rest = url.split("://", 1)
        credentials, host = rest.rsplit("@", 1)
        self.base = f"{scheme}://{host.rstrip('/')}/api"
        self.auth = "Basic " + base64.b64encode(credentials.encode()).decode()

    def request(self, method: str, path: str, body: dict | None = None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(f"{self.base}/{path}", data=data, method=method,
                                     headers={"Authorization": self.auth, "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as response:
            text = response.read()
        return json.loads(text) if text else None


def job(rabbit: Rabbit, alias: str, prompt: str, n: int, replies: str) -> dict:
    """One job of the f1 team through jobs.inference, from its publication to its reply."""
    body = {"id": f"bench-{alias}-{n}", "team": "f1", "alias": alias, "max_tokens": MAX_TOKENS,
            "messages": [{"role": "user", "content": prompt}]}
    start = time.perf_counter()
    rabbit.request("POST", "exchanges/%2F/jobs/publish", {
        "routing_key": "inference", "properties": {"reply_to": replies, "delivery_mode": 2},
        "payload": json.dumps(body), "payload_encoding": "string"})
    while True:
        got = rabbit.request("POST", f"queues/%2F/{replies}/get",
                             {"count": 1, "ackmode": "ack_requeue_false", "encoding": "auto"})
        if got:
            reply = json.loads(got[0]["payload"])
            break
        if time.perf_counter() - start > 600:
            raise RuntimeError(f"no reply to job {body['id']} after 600 s")
        time.sleep(0.2)
    if reply.get("status") != "done":
        raise RuntimeError(f"job {body['id']} failed: {reply}")
    return {"total": time.perf_counter() - start, "worker_seconds": reply["seconds"],
            "tokens_in": reply["usage"]["prompt_tokens"], "tokens_out": reply["usage"]["completion_tokens"]}


def jobs(rabbit: Rabbit, aliases: list[str], runs: int, prices: dict) -> dict:
    replies = "bench-inference-replies"
    rabbit.request("PUT", f"queues/%2F/{replies}", {"durable": True, "arguments": {"x-queue-type": "quorum"}})
    results = {}
    try:
        for alias in aliases:
            calls = [job(rabbit, alias, PROMPTS[i % len(PROMPTS)], i, replies) for i in range(runs + 1)]
            price_in, price_out = prices[alias]
            for x in calls:
                x["cost"] = x["tokens_in"] * price_in + x["tokens_out"] * price_out
            results[alias] = {"cold": calls[0], "warm": calls[1:]}
            print(f"jobs on {alias}: done", file=sys.stderr)
    finally:
        rabbit.request("DELETE", f"queues/%2F/{replies}")
    return results


def p95(values: list[float]) -> float:
    return statistics.quantiles(values, n=20, method="inclusive")[-1] if len(values) > 1 else values[0]


def main() -> None:
    if sys.argv[2] == "--render":
        render(Path(sys.argv[1]))
        return
    out, runs, targets = Path(sys.argv[1]), int(sys.argv[2]), sys.argv[3:]
    key = os.environ.get("BENCH_API_KEY", "none")
    prices = {
        m["model_name"]: (m["litellm_params"]["input_cost_per_token"], m["litellm_params"]["output_cost_per_token"])
        for m in yaml.safe_load(CONFIG.read_text())["model_list"]
        if "output_cost_per_token" in m["litellm_params"]
    }
    results = {}
    for target in targets:
        label, spec = target.split("=", 1)
        base_url, model = spec.split("|", 1)
        client = OpenAI(base_url=base_url, api_key=key, max_retries=0, timeout=300)
        call(client, model, PROMPTS[0])
        calls = []
        for i in range(runs):
            calls.append(call(client, model, PROMPTS[i % len(PROMPTS)]))
            print(f"{label}: {i + 1}/{runs}", file=sys.stderr)
        if model in prices and all(x["tokens_in"] is not None for x in calls):
            price_in, price_out = prices[model]
            for x in calls:
                x["cost"] = x["tokens_in"] * price_in + x["tokens_out"] * price_out
        results[label] = {"base_url": base_url, "model": model, "calls": calls}

    job_results = {}
    if os.environ.get("BENCH_RABBITMQ_URL"):
        aliases = os.environ.get("BENCH_JOB_ALIASES", "chat-pro").split(",")
        job_results = jobs(Rabbit(os.environ["BENCH_RABBITMQ_URL"]), aliases, runs, prices)

    out.mkdir(parents=True, exist_ok=True)
    (out / "results.json").write_text(json.dumps({"calls": results, "jobs": job_results}, indent=2) + "\n")
    render(out)


def render(out: Path) -> None:
    """results.md from results.json."""
    data = json.loads((out / "results.json").read_text())
    results, job_results = data["calls"], data["jobs"]
    lines = [
        "# Inference benchmark results",
        "",
        "Generated by `just bench-inference` (scripts/bench-inference.py); method and reading in README.md.",
        "",
        ("| Target | Model | TTFT median | TTFT p95 | Tokens/s median | Latency median | Latency p95 | Tokens out "
        "median | Cost per 1,000 calls |"),
        "| -- | -- | -- | -- | -- | -- | -- | -- | -- |",
    ]
    for label, r in results.items():
        c = r["calls"]
        ttft, total = [x["ttft"] for x in c], [x["total"] for x in c]
        speed = [x["tokens_per_s"] for x in c if x["tokens_per_s"]]
        costs = [x["cost"] for x in c if x.get("cost") is not None]
        cost = f"${statistics.mean(costs) * 1000:.2f}" if costs else "-"
        lines.append(
            f"| {label} | `{r['model']}` | {statistics.median(ttft):.2f} s | {p95(ttft):.2f} s | "
            f"{statistics.median(speed):.0f} | {statistics.median(total):.2f} s | {p95(total):.2f} s | "
            f"{statistics.median(x['tokens_out'] for x in c):.0f} | {cost} |"
        )
    if job_results:
        lines += [
            "",
            ("| Jobs through the queue | First job, workers at zero | Next jobs, median | Next jobs, p95 | In the worker, "
            "median | Cost per 1,000 jobs |"),
            "| -- | -- | -- | -- | -- | -- |",
        ]
        for n, (alias, r) in enumerate(job_results.items()):
            warm = [x["total"] for x in r["warm"]]
            cost = statistics.mean(x["cost"] for x in [r["cold"], *r["warm"]]) * 1000
            # Only the first alias starts from zero workers: the next ones find them still up (cooldown of 60 s).
            cold = f"{r['cold']['total']:.1f} s" if n == 0 else "-"
            lines.append(
                f"| `{alias}` | {cold} | {statistics.median(warm):.1f} s | {p95(warm):.1f} s | "
                f"{statistics.median(x['worker_seconds'] for x in r['warm']):.1f} s | ${cost:.2f} |"
            )
    (out / "results.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
