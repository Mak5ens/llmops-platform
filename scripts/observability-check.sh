#!/usr/bin/env bash
# Check the acceptance criterion of LAB-128 the way a user clicks through Grafana: from a point of the gateway's latency
# graph (an exemplar of Tempo's span metrics in Prometheus), open its trace in Tempo, then its logs in Loki.
# Queries go through the API server's service proxy: no port-forward, works on any cluster.
# Usage: scripts/observability-check.sh <kube context>
set -euo pipefail

context=${1:?usage: $0 <kube context>}
kc=(kubectl --context "$context")
host=llm.localtest.me
ca=$(mktemp)
trap 'rm -f "$ca"' EXIT

# GET on a Service of the monitoring namespace: get <service:port> <path> [query parameter]...
get() {
  local target=$1 path=$2
  shift 2
  local query
  query=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.urlencode([a.split("=", 1) for a in sys.argv[1:]]))' "$@")
  "${kc[@]}" get --raw "/api/v1/namespaces/monitoring/services/$target/proxy$path?$query" 2>/dev/null
}

# Retry a command until it prints something non-empty, for up to $1 seconds.
until_found() {
  local seconds=$1 result
  shift
  for _ in $(seq "$seconds"); do
    result=$("$@" || true)
    [[ -n $result ]] && { echo "$result"; return; }
    sleep 1
  done
  return 1
}

echo "== Traffic through the Gateway"
"${kc[@]}" -n cert-manager get secret local-ca -o jsonpath='{.data.ca\.crt}' | base64 -d >"$ca"
for _ in $(seq 20); do
  curl -sf --cacert "$ca" -o /dev/null "https://$host/health/liveliness"
done
echo "20 requests to https://$host"

echo "== Click 0: an exemplar on the latency graph"
exemplar() {
  local end
  end=$(date +%s)
  get kps-prometheus:9090 /api/v1/query_exemplars 'query=traces_spanmetrics_latency_bucket{service="platform.gateway"}' \
    "start=$((end - 600))" "end=$end" \
    | python3 -c 'import json, sys
found = [e["labels"]["trace_id"] for s in json.load(sys.stdin)["data"] for e in s["exemplars"] if "trace_id" in e["labels"]]
print(found[-1] if found else "")'
}
trace_id=$(until_found 180 exemplar) || { echo "No exemplar on the gateway's latency after 180 s" >&2; exit 1; }
echo "Exemplar with trace ID $trace_id"

echo "== Click 1: its trace in Tempo"
trace() { get tempo:3200 "/api/v2/traces/$trace_id" | python3 -c 'import json, sys
spans = [s for b in json.load(sys.stdin)["trace"]["resourceSpans"] for ss in b["scopeSpans"] for s in ss["spans"]]
print(f"{len(spans)} span(s): " + ", ".join(sorted({s["name"] for s in spans})) if spans else "")'; }
until_found 60 trace || { echo "Trace $trace_id not found in Tempo" >&2; exit 1; }

echo "== Click 2: its logs in Loki"
logs() {
  local end
  end=$(date +%s)
  get loki:3100 /loki/api/v1/query_range "query={service_name=\"platform.gateway\"} | trace_id=\"$trace_id\"" \
    "start=$((end - 900))000000000" "end=${end}000000000" \
    | python3 -c 'import json, sys
lines = [v[1] for r in json.load(sys.stdin)["data"]["result"] for v in r["values"]]
print(f"{len(lines)} line(s): {lines[0][:160]}" if lines else "")'
}
until_found 60 logs || { echo "No log line with trace ID $trace_id in Loki" >&2; exit 1; }
echo "From the latency graph to the request's trace and logs: OK"
