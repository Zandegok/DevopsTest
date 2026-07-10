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

log_info "Starting smoke verification..."

run_check k3s bash -c '[[ "$(kubectl get nodes -o jsonpath="{.items[0].status.conditions[?(@.type==\"Ready\")].status}")" == "True" ]]'

run_check istio bash -c 'kubectl -n istio-system get deploy istiod istio-ingressgateway >/dev/null'

run_check harbor bash -c 'assert_http "$(harbor_url)/api/v2.0/health" 200 5000'

run_check bookinfo bash -c 'assert_http "$(bookinfo_url)" 200 8000'

if [[ -f "$ROOT_DIR/.low-memory" ]]; then
  log_info "Low-memory VM detected ($(cat "$ROOT_DIR/.low-memory") MB) — Grafana check uses extended timeout"
  run_check grafana bash -c 'assert_http "$(grafana_url)/api/health" 200 30000'
elif [[ "${SKIP_MONITORING:-0}" == "1" ]]; then
  log_info "SKIP_MONITORING=1 — skipping Grafana check"
  RESULTS+=("[SKIP] grafana")
  PASS=$((PASS + 1))
else
  run_check grafana bash -c 'assert_http "$(grafana_url)/api/health" 200 10000'
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
