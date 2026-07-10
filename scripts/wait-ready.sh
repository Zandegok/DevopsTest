#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/assert.sh
source "$ROOT_DIR/scripts/lib/assert.sh"

log_info "Waiting for cluster and workloads..."

retry 60 10 kubectl get nodes >/dev/null

retry 60 10 bash -c '[[ "$(kubectl get nodes -o jsonpath="{.items[0].status.conditions[?(@.type==\"Ready\")].status}")" == "True" ]]'

retry 60 10 kubectl -n istio-system wait --for=condition=available deployment/istiod --timeout=30s
retry 60 10 kubectl -n istio-system wait --for=condition=available deployment/istio-ingressgateway --timeout=30s

retry 120 15 assert_pods_ready harbor '' || true
retry 60 10 wait_for_url "$(harbor_url)/api/v2.0/health" 200 30 || true

retry 60 10 assert_pods_ready default 'app=productpage'
retry 60 10 wait_for_url "$(bookinfo_url)" 200 30

retry 60 10 wait_for_url "$(grafana_url)/api/health" 200 30 || true

log_pass "all core services are ready"
