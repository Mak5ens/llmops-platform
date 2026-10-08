# Self-test of the supply chain gate (build-image.yml, ADR-022): an image with critical CVEs that have a fix
# (krb5-libs CVE-2024-37371, libexpat CVE-2024-45491 and CVE-2024-45492). Its scan must fail. Never published.
# Pinned by digest, so the test does not change when the tag is updated.
FROM python:3.11.0-alpine@sha256:a651419779f8b2a0dbd6c46dd238d7309b01ec65164bcce51a680fc868415eea
