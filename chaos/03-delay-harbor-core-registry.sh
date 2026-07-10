#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/assert.sh
source "$ROOT_DIR/scripts/lib/assert.sh"
# shellcheck source=chaos/lib/run-experiment.sh
source "$ROOT_DIR/chaos/lib/run-experiment.sh"

MANIFEST="$ROOT_DIR/manifests/istio/faults/03-delay-harbor-core-registry.yaml"

fault_assert() {
  local ms
  local i
  local max=0
  for ((i = 1; i <= 5; i++)); do
    ms=$(kubectl exec -n harbor deploy/harbor-core -c core -- \
      sh -c 'curl -sS -o /dev/null -w "%{time_total}" --connect-timeout 5 --max-time 30 http://harbor-registry:5000/v2/ 2>/dev/null || wget -q -O /dev/null -T 30 http://harbor-registry:5000/v2/ && echo 6' 2>/dev/null \
      | awk '{printf "%.0f", $1 * 1000}')
    if [[ "$ms" -gt "$max" ]]; then
      max=$ms
    fi
    sleep 1
  done
  if [[ "$max" -gt 3000 ]]; then
    log_pass "harbor-core -> harbor-registry latency max=${max}ms > 3000ms"
    return 0
  fi
  log_fail "harbor-core -> harbor-registry latency max=${max}ms not > 3000ms"
  return 1
}

run_experiment "03-delay-harbor-core-registry" "$MANIFEST" fault_assert
