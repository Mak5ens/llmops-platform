#!/usr/bin/env bash
# The release of llmops-gateway the platform deploys, and the configuration that goes with it (ADR-023).
#
# The version is the tag of the gateway's images in platform/llm-gateway/base/kustomization.yaml, which Renovate
# updates. The configuration is not in the images: the platform keeps a copy of config/litellm.yaml and
# config/tenants.yaml, which has to match that release.
#
#   scripts/gateway-release.sh ref     the Git ref of that release in llmops-gateway (v1.2.0, or a commit SHA)
#   scripts/gateway-release.sh check   fail if the copies differ from the release's files
#   scripts/gateway-release.sh sync    rewrite the copies from the release's files
set -euo pipefail

repo=Mak5ens/llmops-gateway
base=platform/llm-gateway/base
files=(litellm tenants)

ref() {
  local tag
  tag=$(python3 - "$base/kustomization.yaml" <<'EOF'
import sys, yaml
images = yaml.safe_load(open(sys.argv[1]))["images"]
print(next(i["newTag"] for i in images if i["name"] == "ghcr.io/mak5ens/llmops-gateway/litellm"))
EOF
)
  if [[ $tag =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "v$tag"
  elif [[ $tag =~ ^sha-([0-9a-f]+)$ ]]; then
    # Images built from main before the first release: tag sha-<7 characters>, resolved to the full SHA.
    # Authenticated when GITHUB_TOKEN is set (CI): the anonymous API allows 60 requests an hour.
    curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
      "https://api.github.com/repos/$repo/commits/${BASH_REMATCH[1]}" \
      | python3 -c 'import json, sys; print(json.load(sys.stdin)["sha"])'
  else
    echo "Unexpected tag $tag for the gateway's images" >&2
    exit 1
  fi
}

# The copy as it should be: its own header (the comment lines up to the first "#" line), then the release's file.
expected() {
  local name=$1 release=$2
  sed '/^#$/q' "$base/config/$name.yaml"
  curl -fsSL "https://raw.githubusercontent.com/$repo/$release/config/$name.yaml"
}

case ${1:-} in
  ref)
    ref
    ;;
  check)
    release=$(ref)
    status=0
    for name in "${files[@]}"; do
      if ! diff -u "$base/config/$name.yaml" <(expected "$name" "$release") >&2; then
        echo "$base/config/$name.yaml differs from config/$name.yaml of llmops-gateway $release" >&2
        status=1
      fi
    done
    if ((status)); then
      echo "Run \`just gateway-config\` and commit the result in this PR." >&2
      exit 1
    fi
    echo "Configuration of the gateway identical to llmops-gateway $release"
    ;;
  sync)
    release=$(ref)
    for name in "${files[@]}"; do
      expected "$name" "$release" >"$base/config/$name.yaml.new"
      mv "$base/config/$name.yaml.new" "$base/config/$name.yaml"
    done
    echo "Configuration of the gateway copied from llmops-gateway $release"
    ;;
  *)
    echo "Usage: $0 ref|check|sync" >&2
    exit 2
    ;;
esac
