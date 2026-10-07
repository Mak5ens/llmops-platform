#!/usr/bin/env python3
"""Download the community dashboards at a pinned revision into platform/monitoring/base/dashboards/, ready for
Grafana's sidecar: the import inputs (${DS_PROMETHEUS}...) become the platform's datasource UIDs.

Usage: scripts/fetch-dashboards.py, then commit the JSON files. To update one, change its revision below.
"""

import json
import urllib.request
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "platform" / "monitoring" / "base" / "dashboards"
GRAFANA_COM = "https://grafana.com/api/dashboards/{id}/revisions/{revision}/download"
ENVOY_GATEWAY = "https://raw.githubusercontent.com/envoyproxy/gateway/{ref}/charts/gateway-addons-helm/dashboards/{name}"

# file name -> source URL. Sloth's dashboards come from its author, CloudNativePG's and Envoy Gateway's from the projects.
DASHBOARDS = {
    "slo-detail.json": GRAFANA_COM.format(id=14348, revision=5),
    "slo-overview.json": GRAFANA_COM.format(id=14643, revision=2),
    "cloudnative-pg.json": GRAFANA_COM.format(id=20417, revision=4),
    # Same version as the Envoy Gateway the platform runs (platform/envoy-gateway).
    "envoy-proxy-global.json": ENVOY_GATEWAY.format(ref="v1.9.2", name="envoy-proxy-global.json"),
    "envoy-clusters.json": ENVOY_GATEWAY.format(ref="v1.9.2", name="envoy-clusters.json"),
}
DATASOURCES = {"${DS_PROMETHEUS}": "prometheus", "${DS_EXPRESSION}": "__expr__"}


def main() -> None:
    for name, url in DASHBOARDS.items():
        with urllib.request.urlopen(url, timeout=30) as response:
            text = response.read().decode()
        for placeholder, uid in DATASOURCES.items():
            text = text.replace(placeholder, uid)
        dashboard = json.loads(text)
        for key in ("__inputs", "__requires", "__elements", "id"):
            dashboard.pop(key, None)
        (OUT / name).write_text(json.dumps(dashboard, indent=2, ensure_ascii=False) + "\n")
        print(f"{name}: {dashboard['title']}")


if __name__ == "__main__":
    main()
