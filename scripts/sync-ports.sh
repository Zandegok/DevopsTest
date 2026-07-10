#!/usr/bin/env bash
# Re-sync Harbor externalURL and Bookinfo gateway on an existing cluster.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/assert.sh
source "$ROOT_DIR/scripts/lib/assert.sh"

log_info "Fixing Bookinfo ingress (Gateway port 80 + VirtualService)..."
ensure_bookinfo_ingress || true

if kubectl -n harbor get svc harbor >/dev/null 2>&1; then
  ip=$(vm_ip)
  port=$(harbor_nodeport || true)
  if [[ -n "$port" ]]; then
    log_info "Harbor externalURL -> http://${ip}:${port}"
    chart_dir="${HARBOR_CHART_DIR:-/tmp/harbor-helm}"
    if [[ -d "$chart_dir" ]]; then
      helm upgrade harbor "$chart_dir" -n harbor --reuse-values \
        --set-string "externalURL=http://${ip}:${port}" --timeout 5m
    else
      log_info "HARBOR_CHART_DIR not found — skip helm externalURL sync (health via NodePort still works)"
    fi
  fi
fi

"$ROOT_DIR/scripts/print-access.sh"
