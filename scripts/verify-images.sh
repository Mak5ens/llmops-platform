#!/usr/bin/env bash
# Checks the signature and the SBOM of every image of our own the platform deploys (ADR-022, ADR-023): the images of
# the `images` entries of the kustomizations under ghcr.io/mak5ens/. Each one must be signed by the reusable
# workflow build-image.yml of llmops-platform, keyless, with an SPDX SBOM attached.
# CI runs it on every PR, so a Renovate PR towards an unsigned image cannot be merged, automatically or not.
set -euo pipefail

signer='^https://github.com/Mak5ens/llmops-platform/\.github/workflows/build-image\.yml@'
issuer=https://token.actions.githubusercontent.com

mapfile -t images < <(python3 - platform <<'EOF'
import pathlib, sys, yaml
for path in sorted(pathlib.Path(sys.argv[1]).rglob("kustomization.yaml")):
    for image in yaml.safe_load(path.read_text()).get("images", []):
        name = image.get("newName", image["name"])
        if name.startswith("ghcr.io/mak5ens/"):
            print(f"{name}:{image['newTag']}")
EOF
)
((${#images[@]})) || { echo "No image of our own in the kustomizations" >&2; exit 1; }

for image in $(printf '%s\n' "${images[@]}" | sort -u); do
  # cosign lists every check it made on stderr: printed only when one fails.
  if ! out=$(cosign verify --certificate-identity-regexp "$signer" --certificate-oidc-issuer "$issuer" "$image" 2>&1) ||
    ! out=$(cosign verify-attestation --type spdxjson --certificate-identity-regexp "$signer" \
      --certificate-oidc-issuer "$issuer" "$image" 2>&1); then
    echo "$out" | tail -5 >&2
    echo "$image is not signed by build-image.yml of llmops-platform, or has no SBOM" >&2
    exit 1
  fi
  echo "Signed by build-image.yml, SBOM attached: $image"
done
