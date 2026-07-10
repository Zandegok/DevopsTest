#!/usr/bin/env bash
# Run a chaos experiment: baseline -> pause -> apply -> assert fault -> pause -> rollback -> recover

set -euo pipefail

run_experiment() {
  local name="$1"
  local manifest="$2"
  local assert_fn="$3"

  log_info "=== Experiment: $name ==="

  log_info "[1/5] BASELINE"
  if ! "$ROOT_DIR/chaos/lib/baseline-checks.sh" "$name"; then
    log_fail "Baseline failed for $name"
    return 1
  fi

  pause_or_skip "Baseline OK. Press Enter before applying fault (check Grafana if DEMO=1)..."

  log_info "[2/5] APPLY FAULT: $manifest"
  kubectl apply -f "$manifest"
  sleep 12

  log_info "[3/5] ASSERT FAULT"
  if ! "$assert_fn"; then
    log_fail "Fault assertion failed for $name"
    kubectl delete -f "$manifest" --ignore-not-found || true
    return 1
  fi

  pause_or_skip "Fault active. Press Enter before rollback..."

  log_info "[4/5] ROLLBACK"
  kubectl delete -f "$manifest" --ignore-not-found
  sleep 12

  log_info "[5/5] RECOVER"
  if ! "$ROOT_DIR/chaos/lib/baseline-checks.sh" "$name"; then
    log_fail "Recovery failed for $name"
    return 1
  fi

  log_pass "Experiment completed: $name"
  return 0
}
