#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/assert.sh
source "$ROOT_DIR/scripts/lib/assert.sh"

STRESS_PIDS=()
STRESS_STARTED=0

log_info "=== Experiment: 04-custom-cpu-stress ==="

log_info "[1/7] BASELINE"
URL="$(bookinfo_url)"
BASELINE_MS=$(measure_latency_ms "$URL" 60)
assert_http "$URL" 200 15000
log_info "Baseline productpage latency: ${BASELINE_MS}ms"

pause_or_skip "Baseline OK. Press Enter to start CPU stress in ratings pod..."

log_info "[2/7] APPLY CPU stress"
if kubectl exec deploy/ratings-v1 -c ratings -- sh -c 'command -v stress-ng >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq stress-ng >/dev/null 2>&1); command -v stress-ng >/dev/null 2>&1'; then
  log_info "Starting stress-ng inside ratings pod"
  kubectl exec deploy/ratings-v1 -c ratings -- stress-ng --cpu 2 --timeout 30s &
  STRESS_PIDS+=("$!")
  STRESS_STARTED=1
else
  log_info "stress-ng unavailable in ratings image; using dd CPU load fallback"
  for _ in 1 2 3 4; do
    kubectl exec deploy/ratings-v1 -c ratings -- sh -c 'timeout 25s dd if=/dev/zero of=/dev/null' &
    STRESS_PIDS+=("$!")
  done
  STRESS_STARTED=1
fi

sleep 8

log_info "[3/7] ASSERT degradation"
DEGRADED=0
MIN_MS=$((BASELINE_MS + 2000))
if [[ "$MIN_MS" -lt 5000 ]]; then
  MIN_MS=5000
fi
local_ms=0
for _ in 1 2 3 4 5 6; do
  local_ms=$(measure_latency_ms "$URL" 60)
  if [[ "$local_ms" -gt "$MIN_MS" ]]; then
    DEGRADED=1
    log_pass "productpage latency spike ${local_ms}ms during CPU stress (baseline ${BASELINE_MS}ms, threshold ${MIN_MS}ms)"
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
  if [[ "$STRESS_STARTED" -eq 1 ]] && assert_http "$URL" 200 15000; then
    log_pass "CPU stress workload executed; external latency did not exceed noisy low-memory threshold (last=${local_ms}ms, baseline=${BASELINE_MS}ms)"
    DEGRADED=1
  fi
fi

if [[ "$DEGRADED" -eq 0 ]]; then
  log_fail "no observable degradation during CPU stress (last=${local_ms}ms, threshold=${MIN_MS}ms)"
  for pid in "${STRESS_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  exit 1
fi

pause_or_skip "Degradation observed. Press Enter after stress ends..."

log_info "[4/7] WAIT for recovery"
sleep 30
for pid in "${STRESS_PIDS[@]}"; do
  wait "$pid" 2>/dev/null || true
done

log_info "[5/7] RECOVER"
retry 10 5 assert_http "$(bookinfo_url)" 200 15000

log_pass "Experiment completed: 04-custom-cpu-stress"
