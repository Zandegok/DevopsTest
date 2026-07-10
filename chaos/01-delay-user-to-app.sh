#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/assert.sh
source "$ROOT_DIR/scripts/lib/assert.sh"
# shellcheck source=chaos/lib/run-experiment.sh
source "$ROOT_DIR/chaos/lib/run-experiment.sh"

MANIFEST="$ROOT_DIR/manifests/istio/faults/01-delay-user-to-app.yaml"
URL="$(bookinfo_url)"

fault_assert() {
  assert_latency_gt "$URL" 5000 3
}

run_experiment "01-delay-user-to-app" "$MANIFEST" fault_assert