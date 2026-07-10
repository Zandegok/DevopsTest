#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/assert.sh
source "$ROOT_DIR/scripts/lib/assert.sh"

IP=$(vm_ip)
BOOKINFO=$(bookinfo_url)
HARBOR=$(harbor_url)
GRAFANA=$(grafana_url)

cat <<EOF
=== Access URLs (VM IP: $IP) ===

Bookinfo:  $BOOKINFO
Harbor:    $HARBOR  (admin / Harbor12345)
Grafana:   $GRAFANA  (admin / prom-operator)

Quick checks:
  curl -sS -o /dev/null -w "%{http_code}" $BOOKINFO
  curl -sS -o /dev/null -w "%{http_code}" $HARBOR/api/v2.0/health
  curl -sS -o /dev/null -w "%{http_code}" $GRAFANA/api/health
EOF
