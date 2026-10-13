#!/usr/bin/env bash
# Latency, throughput and cost of the gateway's chat models (LAB-137), into benchmarks/inference/: chat-small and
# chat-pro through the cluster's Gateway, the same as jobs through the queue, and, with OLLAMA_GPU_URL and
# OLLAMA_CPU_URL, the real local models served by Ollama on this machine, which the cluster replaces with a small one
# (platform/llm-gateway/base/ollama.yaml). chat-pro calls Scaleway: a run costs about $0.01.
# Usage: scripts/bench-inference.sh <kube context> [runs, default 20]
set -euo pipefail

context=${1:?usage: $0 <kube context> [runs]}
runs=${2:-20}
root=$(cd "$(dirname "$0")/.." && pwd)
port=15674
gateway=https://llm.localtest.me/v1

secret() { kubectl --context "$context" -n "$1" get secret "$2" -o jsonpath="{.data.$3}" | base64 -d; }
[[ -n $(secret llm-gateway gateway-env SCW_SECRET_KEY) ]] || { echo "No Scaleway key on the cluster: chat-pro cannot answer" >&2; exit 1; }

kubectl --context "$context" -n jobs port-forward svc/rabbitmq "$port:15672" >/dev/null &
forward=$!
trap 'kill $forward 2>/dev/null' EXIT
sleep 3

# The first job measures a cold start: wait for the workers to be at zero.
for _ in $(seq 300); do
  [[ -z $(kubectl --context "$context" -n jobs get deployment worker -o jsonpath='{.status.replicas}') ]] && break
  sleep 1
done

ca=$(mktemp)
secret cert-manager local-ca 'ca\.crt' >"$ca"
targets=("chat-small=$gateway|chat-small" "chat-pro=$gateway|chat-pro")
for model in qwen2.5:0.5b qwen2.5:1.5b qwen2.5:7b; do
  [[ -n ${OLLAMA_GPU_URL:-} ]] && targets+=("Ollama on a GPU, $model=$OLLAMA_GPU_URL/v1|$model")
done
[[ -n ${OLLAMA_CPU_URL:-} ]] && targets+=("Ollama on the CPU, qwen2.5:7b=$OLLAMA_CPU_URL/v1|qwen2.5:7b")

BENCH_API_KEY=$(secret llm-gateway gateway-env TEAM_KEY_F1) \
  BENCH_RABBITMQ_URL="http://$(secret jobs rabbitmq-default-user username):$(secret jobs rabbitmq-default-user password)@localhost:$port" \
  BENCH_JOB_ALIASES=chat-pro,chat-small \
  uv run --quiet --with openai --with pyyaml -- env SSL_CERT_FILE="$ca" \
  python "$root/scripts/bench-inference.py" "$root/benchmarks/inference" "$runs" "${targets[@]}"
rm -f "$ca"
