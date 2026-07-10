#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/assert.sh
source "$ROOT_DIR/scripts/lib/assert.sh"
# shellcheck source=chaos/lib/run-experiment.sh
source "$ROOT_DIR/chaos/lib/run-experiment.sh"
# shellcheck source=chaos/lib/harbor-mesh.sh
source "$ROOT_DIR/chaos/lib/harbor-mesh.sh"

MANIFEST="$ROOT_DIR/manifests/istio/faults/03-delay-harbor-core-registry.yaml"

log_info "=== Experiment: 03-delay-harbor-core-registry ==="

harbor_mesh_reset_if_needed

log_info "[1/9] BASELINE"
retry 30 10 "$ROOT_DIR/chaos/lib/baseline-checks.sh" harbor

pause_or_skip "Baseline OK. Press Enter to enable temporary Harbor mesh for fault demo..."

log_info "[2/9] ENABLE selective Harbor sidecars (Redis/DB ports excluded)"
harbor_mesh_enable

pause_or_skip "Sidecars enabled. Press Enter to apply fault..."

log_info "[3/9] APPLY FAULT"
kubectl apply -f "$MANIFEST"
sleep 20

log_info "[4/9] ASSERT FAULT"
if ! assert_mesh_harbor_registry_latency_gt 3000 8; then
  kubectl delete -f "$MANIFEST" --ignore-not-found || true
  harbor_mesh_disable || true
  exit 1
fi

pause_or_skip "Fault active. Press Enter to rollback..."

log_info "[5/9] ROLLBACK FAULT"
kubectl delete -f "$MANIFEST" --ignore-not-found
sleep 12

log_info "[6/9] DISABLE temporary Harbor sidecars"
harbor_mesh_disable

log_info "[7/9] RECOVER"
retry 30 10 "$ROOT_DIR/chaos/lib/baseline-checks.sh" harbor

log_pass "Experiment completed: 03-delay-harbor-core-registry"
