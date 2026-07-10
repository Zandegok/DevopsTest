#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/assert.sh
source "$ROOT_DIR/scripts/lib/assert.sh"

node_ready() {
  [[ "$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')" == "True" ]]
}

log_info "Waiting for cluster and workloads..."

retry 60 10 kubectl get nodes >/dev/null

retry 60 10 node_ready

log_info "Istio control plane..."
retry 60 10 kubectl -n istio-system wait --for=condition=available deployment/istiod --timeout=30s
retry 60 10 kubectl -n istio-system wait --for=condition=available deployment/istio-ingressgateway --timeout=30s

ensure_bookinfo_ingress || true

log_info "Harbor pods and health..."
retry 120 15 assert_pods_ready harbor '' || true
wait_for_url "$(harbor_url)/api/v2.0/health" 200 600 harbor || true

log_info "Bookinfo pods and ingress..."
retry 60 10 assert_pods_ready default 'app=productpage'
wait_for_url "$(bookinfo_url)" 200 600 bookinfo

if [[ "${SKIP_MONITORING:-0}" == "1" ]]; then
  log_info "SKIP_MONITORING=1 — skipping Grafana"
else
  log_info "Grafana health..."
  wait_for_url "$(grafana_url)/api/health" 200 600 grafana || true
fi

log_pass "all core services are ready"
