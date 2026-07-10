#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/assert.sh
source "$ROOT_DIR/scripts/lib/assert.sh"
# shellcheck source=chaos/lib/run-experiment.sh
source "$ROOT_DIR/chaos/lib/run-experiment.sh"

MANIFEST="$ROOT_DIR/manifests/istio/faults/02-abort-reviews-to-ratings.yaml"

ratings_code() {
  kubectl exec deploy/reviews-v2 -c reviews -- \
    curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 15 \
    http://ratings:9080/ratings/0 2>/dev/null || echo "000"
}

fault_assert() {
  local code
  local i
  for ((i = 1; i <= 5; i++)); do
    code=$(ratings_code)
    if [[ "$code" == "500" ]]; then
      log_pass "ratings returned 500 during fault (attempt $i)"
      return 0
    fi
    sleep 2
  done
  log_fail "ratings did not return 500 (last code=$code)"
  return 1
}

run_experiment "02-abort-reviews-to-ratings" "$MANIFEST" fault_assert
