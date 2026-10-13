"""What Scaleway bills for chat-pro against what the gateway counted (LAB-138).

`snapshot` saves the month's Generative APIs consumption of Mistral Small 3.2 (tokens in and out, euros) from
Scaleway's billing API; `compare`, after some traffic, reads it again and puts the difference next to what LiteLLM
counted over the same time in Prometheus (litellm_*_tokens_metric_total and litellm_spend_metric_total of the
scaleway provider). Scaleway bills per thousand tokens and updates its consumption with a delay: compare once its
`updated_at` is past the end of the traffic. The bill covers the whole project, every key: other calls to chat-pro
during the window (another app, a test run) show up on Scaleway's side only if they skip this gateway.

The key is SCW_BILLING_SECRET_KEY (an IAM application with BillingReadOnly on the organization) and
SCW_ORGANIZATION_ID, from the environment or from the .env of a clone of llmops-gateway (SCALEWAY_ENV_FILE,
../llmops-gateway/.env by default).

Usage: python3 scripts/scaleway-bill.py snapshot <file>
       python3 scripts/scaleway-bill.py compare <file> <kube context>
"""

import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKU = "/ai/generative_apis/consumption/mistral_small_3_2_24b_instruct_2506_{}/fr-par"
PROMETHEUS = "/api/v1/namespaces/monitoring/services/kps-prometheus:9090/proxy/api/v1/query"


def setting(name: str) -> str:
    if os.environ.get(name):
        return os.environ[name]
    env = Path(os.environ.get("SCALEWAY_ENV_FILE", ROOT.parent / "llmops-gateway/.env"))
    for line in env.read_text().splitlines() if env.exists() else []:
        if line.startswith(f"{name}="):
            return line.split("=", 1)[1].strip().strip('"')
    sys.exit(f"{name} is not set, in the environment or in {env}")


def bill() -> dict:
    """Thousands of tokens in and out, and euros, billed this month for Mistral Small 3.2."""
    query = urllib.parse.urlencode({"organization_id": setting("SCW_ORGANIZATION_ID"), "page_size": 100})
    request = urllib.request.Request(f"https://api.scaleway.com/billing/v2beta1/consumptions?{query}",
                                     headers={"X-Auth-Token": setting("SCW_BILLING_SECRET_KEY")})
    with urllib.request.urlopen(request, timeout=30) as response:
        data = json.load(response)
    result = {"updated_at": data["updated_at"], "taken_at": time.time()}
    for side in ("input", "output"):
        lines = [c for c in data["consumptions"] if c["sku"] == SKU.format(side)]
        result[f"k_tokens_{side}"] = sum(int(c["billed_quantity"]) for c in lines)
        result[f"eur_{side}"] = sum(c["value"]["units"] + c["value"]["nanos"] / 1e9 for c in lines)
    return result


def prometheus(context: str, expr: str) -> float:
    raw = subprocess.run(["kubectl", "--context", context, "get", "--raw",
                          f"{PROMETHEUS}?{urllib.parse.urlencode({'query': expr})}"],
                         capture_output=True, text=True, check=True).stdout
    result = json.loads(raw)["data"]["result"]
    return float(result[0]["value"][1]) if result else 0.0


def main() -> None:
    command, path = sys.argv[1], Path(sys.argv[2])
    if command == "snapshot":
        path.write_text(json.dumps(bill(), indent=2) + "\n")
        print(f"Scaleway's bill at {path}: {path.read_text()}")
        return

    before, after = json.loads(path.read_text()), bill()
    # Each series now minus at the snapshot, or all of it if it appeared since (a restart of LiteLLM starts new
    # series): increase() would miss the first call of every new series, since LiteLLM creates it with its value.
    def since_snapshot(metric: str) -> float:
        series = f'{metric}{{api_provider="scaleway"}}'
        at = int(before["taken_at"])
        return prometheus(sys.argv[3], f"sum(({series} - {series} @ {at}) or {series})")

    gateway = {side: since_snapshot(f"litellm_{side}_tokens_metric_total") for side in ("input", "output")}
    spend = since_snapshot("litellm_spend_metric_total")
    print(f"Scaleway's consumption updated at {after['updated_at']}, snapshot taken at "
          f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(before['taken_at']))}\n")
    print("| | Gateway (LiteLLM) | Scaleway's bill | Difference |")
    print("| -- | -- | -- | -- |")
    for side in ("input", "output"):
        billed = (after[f"k_tokens_{side}"] - before[f"k_tokens_{side}"]) * 1000
        diff = f"{(gateway[side] - billed) / billed:+.1%}" if billed else "-"
        print(f"| Tokens {side} | {gateway[side]:,.0f} | {billed:,.0f} (per thousand) | {diff} |")
    eur = sum(after[f"eur_{s}"] - before[f"eur_{s}"] for s in ("input", "output"))
    diff = f"{(spend - eur) / eur:+.1%}" if eur else "-"
    print(f"| Cost | {spend:.4f} (euros counted as dollars) | €{eur:.4f} (rounded to the cent per line) | {diff} |")


if __name__ == "__main__":
    main()
