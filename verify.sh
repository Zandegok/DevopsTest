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
  assert_http "$(bookinfo_url)" 200 8000
}

check_grafana() {
  local max_ms="${1:-10000}"
  assert_http "$(grafana_url)/api/health" 200 "$max_ms"
}

log_info "Starting smoke verification..."

ensure_bookinfo_gateway || true

run_check k3s check_k3s_ready
run_check istio check_istio_deployments
run_check harbor check_harbor
run_check bookinfo check_bookinfo

if [[ -f "$ROOT_DIR/.low-memory" ]]; then
  log_info "Low-memory VM detected ($(cat "$ROOT_DIR/.low-memory") MB) — Grafana check uses extended timeout"
  run_check grafana check_grafana 30000
elif [[ "${SKIP_MONITORING:-0}" == "1" ]]; then
  log_info "SKIP_MONITORING=1 — skipping Grafana check"
  RESULTS+=("[SKIP] grafana")
  PASS=$((PASS + 1))
else
  run_check grafana check_grafana 10000
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
