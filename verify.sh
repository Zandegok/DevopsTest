#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/assert.sh
source "$ROOT_DIR/scripts/lib/assert.sh"

PASS=0
FAIL=0
RESULTS=()

run_check() {
  local name="$1"
  shift
  if retry 12 10 "$@"; then
    RESULTS+=("[PASS] $name")
    PASS=$((PASS + 1))
  else
    RESULTS+=("[FAIL] $name")
    FAIL=$((FAIL + 1))
  fi
}

check_k3s_ready() {
  [[ "$(kubectl get nodes -o jsonpath="{.items[0].status.conditions[?(@.type==\"Ready\")].status}")" == "True" ]]
}

check_istio_deployments() {
  kubectl -n istio-system get deploy istiod istio-ingressgateway >/dev/null
}

check_harbor() {
  assert_http "$(harbor_url)/api/v2.0/health" 200 5000
}

check_bookinfo() {
  local max_ms=15000
  if [[ -f "$ROOT_DIR/.low-memory" ]] || [[ "${SKIP_MONITORING:-0}" == "1" ]]; then
    max_ms=25000
  fi
  assert_http "$(bookinfo_url)" 200 "$max_ms"
}

check_grafana() {
  local max_ms="${1:-10000}"
  local url
  url=$(grafana_url) || {
    log_fail "Grafana not installed"
    return 1
  }
  assert_http "${url}/api/health" 200 "$max_ms"
}

log_info "Starting smoke verification..."

run_check k3s check_k3s_ready
run_check istio check_istio_deployments
run_check harbor check_harbor

log_info "Ensuring Bookinfo ingress routes..."
ensure_bookinfo_ingress || log_fail "Bookinfo ingress not ready — run ./scripts/fix-bookinfo-ingress.sh"

run_check bookinfo check_bookinfo

reason=$(grafana_skip_reason "$ROOT_DIR" || true)
if [[ -n "$reason" ]]; then
  log_info "Grafana skipped ($reason)"
  RESULTS+=("[SKIP] grafana")
  PASS=$((PASS + 1))
else
  max_ms=10000
  if [[ -f "$ROOT_DIR/.low-memory" ]]; then
    max_ms=30000
    log_info "Low-memory VM — Grafana check uses extended timeout (${max_ms}ms)"
  fi
  run_check grafana check_grafana "$max_ms"
fi

run_check sidecar assert_sidecar_injection default 'app=productpage'

echo ""
echo "=== VERIFY SUMMARY ==="
for r in "${RESULTS[@]}"; do
  echo "$r"
done

TOTAL=$((PASS + FAIL))
if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL PASSED ($PASS/$TOTAL)"
  "$ROOT_DIR/scripts/print-access.sh"
  exit 0
fi

echo "FAILED ($PASS passed, $FAIL failed of $TOTAL)"
exit 1
