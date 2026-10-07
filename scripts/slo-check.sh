#!/usr/bin/env bash
# Acceptance test of LAB-129: cut a model server, and the fast burn alert of the gateway's availability SLO fires,
# with its runbook. Stops the `ollama` server (chat-small, no fallback), sends calls to chat-small through the Gateway
# until GatewayAvailabilityBudgetBurn fires at severity critical, then puts everything back as in Git.
# ArgoCD repairs manual changes, so its reconciliation of llm-gateway is suspended meanwhile.
# Usage: scripts/slo-check.sh <kube context>
set -euo pipefail

context=${1:?usage: $0 <kube context>}
kc=(kubectl --context "$context")
ns=llm-gateway
host=llm.localtest.me
alert=GatewayAvailabilityBudgetBurn
ca=$(mktemp)
traffic=""

# Put the model server back: resume ArgoCD, which scales it back up, and wait for it.
restore() {
  [[ -n $traffic ]] && kill "$traffic" 2>/dev/null
  "${kc[@]}" -n argocd annotate application llm-gateway argocd.argoproj.io/skip-reconcile- >/dev/null
  "${kc[@]}" -n argocd annotate application llm-gateway argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  "${kc[@]}" -n "$ns" wait deployment/ollama --for=jsonpath='{.status.readyReplicas}'=1 --timeout=300s >/dev/null
  rm -f "$ca"
  echo "ollama is back"
}
trap restore EXIT

firing() {
  "${kc[@]}" get --raw /api/v1/namespaces/monitoring/services/kps-prometheus:9090/proxy/api/v1/alerts 2>/dev/null \
    | python3 -c 'import json, sys
for a in json.load(sys.stdin)["data"]["alerts"]:
    if a["labels"].get("alertname") == sys.argv[1] and a["labels"].get("severity") == "critical" and a["state"] == "firing":
        print(a["labels"]["sloth_slo"], a["labels"]["sloth_severity"], a["annotations"].get("runbook_url", "NO RUNBOOK"))
        break' "$alert"
}

echo "== Cutting the model server of chat-small"
"${kc[@]}" -n argocd annotate application llm-gateway argocd.argoproj.io/skip-reconcile=true --overwrite >/dev/null
"${kc[@]}" -n "$ns" scale deployment/ollama --replicas=0 >/dev/null
"${kc[@]}" -n "$ns" wait pod -l app.kubernetes.io/name=ollama --for=delete --timeout=120s >/dev/null
echo "ollama scaled to 0"

echo "== Calls to chat-small, until $alert fires"
"${kc[@]}" -n cert-manager get secret local-ca -o jsonpath='{.data.ca\.crt}' | base64 -d >"$ca"
key=$("${kc[@]}" -n "$ns" get secret gateway-env -o jsonpath='{.data.TEAM_KEY_F1}' | base64 -d)
(
  while true; do
    curl -s -o /dev/null --cacert "$ca" "https://$host/v1/chat/completions" -H "Authorization: Bearer $key" \
      -H 'Content-Type: application/json' -d '{"model": "chat-small", "messages": [{"role": "user", "content": "hi"}]}'
    sleep 1
  done
) &
traffic=$!

start=$SECONDS
for _ in $(seq 120); do
  result=$(firing || true)
  [[ -n $result ]] && break
  sleep 5
done
[[ -n $result ]] || { echo "$alert did not fire within 10 minutes" >&2; exit 1; }
read -r slo severity runbook <<<"$result"
echo "$alert fired after $((SECONDS - start)) s: SLO $slo, $severity, runbook $runbook"
[[ $runbook == https://* ]] || { echo "The alert has no runbook" >&2; exit 1; }
