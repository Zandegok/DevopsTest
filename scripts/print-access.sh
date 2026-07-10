#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/assert.sh
source "$ROOT_DIR/scripts/lib/assert.sh"

IP=$(vm_ip)
BOOKINFO=$(bookinfo_url)
HARBOR=$(harbor_url)
GRAFANA=$(grafana_url)
BOOKINFO_PORT=$(bookinfo_nodeport || echo "?")
HARBOR_PORT=$(harbor_nodeport || echo "?")
GRAFANA_PORT=$(grafana_nodeport || echo "?")

cat <<EOF
=== Access URLs (VM IP: $IP) ===

Bookinfo:  $BOOKINFO  (NodePort ${BOOKINFO_PORT})
Harbor:    $HARBOR  (admin / Harbor12345, NodePort ${HARBOR_PORT})
Grafana:   $GRAFANA  (admin / prom-operator, NodePort ${GRAFANA_PORT})

Pin ports (optional): HARBOR_NODEPORT=30002 GRAFANA_NODEPORT=30300 ./setup.sh

Quick checks:
  curl -sS -o /dev/null -w "%{http_code}" $BOOKINFO
  curl -sS -o /dev/null -w "%{http_code}" $HARBOR/api/v2.0/health
  curl -sS -o /dev/null -w "%{http_code}" $GRAFANA/api/health
EOF
