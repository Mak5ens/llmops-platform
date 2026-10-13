#!/usr/bin/env bash
# A peak of real jobs (LAB-138): the spike scenario of benchmarks/k6 (two bursts of 150 jobs, 95 s apart), each job
# asking an alias a question about Formula 1 strategy, for the Inference dashboard and the cost per job. With chat-pro,
# it calls Scaleway: about 150,000 tokens out, €0.05. Run scripts/scaleway-bill.py snapshot before, compare after.
# Usage: scripts/inference-peak.sh <kube context> [alias, default chat-pro] [max tokens per job, default 512]
set -euo pipefail

context=${1:?usage: $0 <kube context> [alias] [max tokens]}
alias=${2:-chat-pro}
max_tokens=${3:-512}
root=$(cd "$(dirname "$0")/.." && pwd)
kc=(kubectl --context "$context" -n jobs)

cleanup() { "${kc[@]}" delete configmap bench-k6 bench-k6-env --ignore-not-found >/dev/null; }
trap cleanup EXIT

"${kc[@]}" create configmap bench-k6 --from-file="$root/benchmarks/k6/autoscaling.js" \
  --dry-run=client -o yaml | "${kc[@]}" apply -f - >/dev/null
"${kc[@]}" create configmap bench-k6-env --from-literal=SCENARIO=spike --from-literal=JOB_ALIAS="$alias" \
  --from-literal=JOB_MAX_TOKENS="$max_tokens" --dry-run=client -o yaml | "${kc[@]}" apply -f - >/dev/null
"${kc[@]}" delete job bench-k6 --ignore-not-found --wait=true >/dev/null
"${kc[@]}" apply -f "$root/benchmarks/k6/job.yaml" >/dev/null
echo "$(date -u +%T) k6 started: spike, real jobs on $alias, up to $max_tokens tokens each"

"${kc[@]}" wait job/bench-k6 --for=condition=Complete --timeout=1800s >/dev/null \
  || { "${kc[@]}" logs job/bench-k6 | tail -30 >&2; echo "k6 failed" >&2; exit 1; }
echo "$(date -u +%T) k6 done"
"${kc[@]}" logs job/bench-k6 | sed -n 's/^BENCH_SUMMARY //p' | python3 -c 'import json, sys
s = json.load(sys.stdin)
lat = {k: v / 1000 for k, v in s["latency"].items() if k != "count"}
print("%d/%d jobs answered, %d failed; latency median %.1f s, p95 %.1f s, max %.1f s"
      % (s["answered"], s["published"], s["failed"], lat["med"], lat["p(95)"], lat["max"]))'
