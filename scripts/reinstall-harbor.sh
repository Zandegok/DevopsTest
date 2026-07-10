#!/usr/bin/env bash
# Reinstall Harbor only (keeps k3s, Istio, Bookinfo). Use when Harbor is broken after chaos 03.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/assert.sh
source "$ROOT_DIR/scripts/lib/assert.sh"

export VM_IP="${VM_IP:-$(vm_ip)}"
export HARBOR_NODEPORT="${HARBOR_NODEPORT:-$(harbor_nodeport 2>/dev/null || echo 30002)}"

log_info "Reinstalling Harbor only (VM_IP=${VM_IP}, NodePort=${HARBOR_NODEPORT})"

helm uninstall harbor -n harbor 2>/dev/null || true
if kubectl get namespace harbor >/dev/null 2>&1; then
  "$ROOT_DIR/scripts/force-delete-harbor-ns.sh" || true
fi

"$ROOT_DIR/scripts/prefetch-harbor-chart.sh"
"$ROOT_DIR/scripts/helm-install-harbor.sh" /tmp/harbor-helm \
  "$ROOT_DIR/manifests/harbor/values-low.yaml" harbor 900

log_pass "Harbor reinstall finished"
