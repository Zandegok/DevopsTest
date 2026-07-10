#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/assert.sh
source "$ROOT_DIR/scripts/lib/assert.sh"

log_info "=== Experiment: 04-custom-cpu-stress ==="

log_info "[1/7] BASELINE"
assert_http "$(bookinfo_url)" 200 5000

pause_or_skip "Baseline OK. Press Enter to start CPU stress in ratings pod..."

log_info "[2/7] APPLY CPU stress"
if ! kubectl exec deploy/ratings-v1 -c ratings -- sh -c 'command -v stress-ng >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq stress-ng >/dev/null 2>&1); stress-ng --cpu 2 --timeout 30s' 2>/dev/null; then
  log_info "stress-ng unavailable in ratings image; using dd CPU load fallback"
  kubectl exec deploy/ratings-v1 -c ratings -- sh -c 'timeout 25s dd if=/dev/zero of=/dev/null' &
  STRESS_PID=$!
fi

sleep 5

log_info "[3/7] ASSERT degradation"
URL="$(bookinfo_url)"
DEGRADED=0
local_ms
for _ in 1 2 3 4 5; do
  local_ms=$(measure_latency_ms "$URL" 60)
  if [[ "$local_ms" -gt 3000 ]]; then
    DEGRADED=1
    log_pass "productpage latency spike ${local_ms}ms during CPU stress"
    break
  fi
  sleep 2
done

if [[ "$DEGRADED" -eq 0 ]]; then
  not_ready=$(kubectl get pods -l app=ratings --no-headers 2>/dev/null | awk '$3 != "Running" {c++} END {print c+0}')
  if [[ "$not_ready" -gt 0 ]]; then
    log_pass "ratings pod not fully healthy during CPU stress"
    DEGRADED=1
  fi
fi

if [[ "$DEGRADED" -eq 0 ]]; then
  log_fail "no observable degradation during CPU stress"
  wait 2>/dev/null || true
  exit 1
fi

pause_or_skip "Degradation observed. Press Enter after stress ends..."

log_info "[4/7] WAIT for recovery"
sleep 30
wait 2>/dev/null || true

log_info "[5/7] RECOVER"
retry 10 5 assert_http "$(bookinfo_url)" 200 5000

log_pass "Experiment completed: 04-custom-cpu-stress"
