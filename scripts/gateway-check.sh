#!/usr/bin/env bash
# Check HTTP exposure: ArgoCD answers over HTTPS through the Gateway, with a certificate issued
# by cert-manager and trusted through the local CA; plain HTTP redirects to HTTPS; no Ingress.
# Usage: scripts/gateway-check.sh <kube context>
set -euo pipefail

context=${1:?usage: $0 <kube context>}
kc=(kubectl --context "$context")
host=argocd.localtest.me
ca=$(mktemp)
trap 'rm -f "$ca"' EXIT

echo "== Certificates"
"${kc[@]}" wait --for=condition=Ready certificate --all -A --timeout=120s
"${kc[@]}" get certificates -A

echo "== Gateway"
"${kc[@]}" -n gateway wait --for=condition=Programmed gateway/platform --timeout=120s
"${kc[@]}" -n gateway get gateway platform

echo "== HTTPS on $host"
"${kc[@]}" -n cert-manager get secret local-ca -o jsonpath='{.data.ca\.crt}' | base64 -d >"$ca"
# The Gateway can take a few seconds to serve a route that was just accepted.
for _ in $(seq 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$ca" "https://$host/") && [[ $code == 200 ]] && break
  sleep 2
done
[[ $code == 200 ]] || { echo "https://$host/ answered $code" >&2; exit 1; }
curl -sv --cacert "$ca" -o /dev/null "https://$host/" 2>&1 | grep -E "subject:|issuer:|SSL certificate verify"

echo "== HTTP redirects to HTTPS"
location=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "http://$host/")
[[ $location == "301 https://$host/" ]] || { echo "http://$host/ answered $location" >&2; exit 1; }
echo "$location"

echo "== No Ingress"
ingresses=$("${kc[@]}" get ingress -A --no-headers 2>/dev/null | wc -l)
[[ $ingresses == 0 ]] || { echo "$ingresses Ingress resources found" >&2; exit 1; }
echo "No Ingress resource in the cluster"
