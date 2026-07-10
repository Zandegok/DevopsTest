#!/usr/bin/env bash
# Remove temporary Istio sidecars from Harbor after chaos 03. Skips if Harbor has no sidecars.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/assert.sh
source "$ROOT_DIR/scripts/lib/assert.sh"
# shellcheck source=chaos/lib/harbor-mesh.sh
source "$ROOT_DIR/chaos/lib/harbor-mesh.sh"

if ! harbor_mesh_has_sidecars; then
  health=$(curl_code "$(harbor_url)/api/v2.0/health" 15)
  if [[ "$health" == "200" ]]; then
    log_info "No Harbor sidecars and health OK — nothing to reset"
    exit 0
  fi
  log_fail "No sidecars but Harbor health HTTP ${health}. Do not reset — reinstall Harbor instead:"
  echo "  ./scripts/reinstall-harbor.sh"
  exit 1
fi

harbor_mesh_disable
