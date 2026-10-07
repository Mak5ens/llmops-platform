#!/usr/bin/env bash
# Generate the Prometheus rules of the SLOs in slo/ with Sloth (ADR-021), into platform/monitoring/base/slo/.
# With --check, fail if the committed rules differ from what the SLOs generate (pre-commit hook and CI).
# Usage: scripts/slo-generate.sh [--check]
set -euo pipefail

cd "$(dirname "$0")/.."
image=ghcr.io/slok/sloth:v0.16.0
out=platform/monitoring/base/slo

for slo in slo/*.yaml; do
  target=$out/$(basename "$slo" .yaml).rules.yaml
  generated=$(docker run --rm -v "$PWD:/work:ro" -w /work "$image" generate -i "$slo" 2>/dev/null)
  if [[ ${1:-} == --check ]]; then
    diff -q <(echo "$generated") "$target" >/dev/null \
      || { echo "$target is out of date: run just slo" >&2; exit 1; }
  else
    echo "$generated" >"$target"
    echo "$target"
  fi
done
