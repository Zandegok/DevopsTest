#!/usr/bin/env bash
set -euo pipefail

echo "[fix-bookinfo $(date +%H:%M:%S)] starting..."

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/assert.sh
source "$ROOT_DIR/scripts/lib/assert.sh"

log_info "kubectl: $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1 || echo 'not found')"
log_info "target URL: $(bookinfo_url)"

ensure_bookinfo_ingress
exit_code=$?

if [[ "$exit_code" -eq 0 ]]; then
  log_pass "fix-bookinfo-ingress completed successfully"
else
  log_fail "fix-bookinfo-ingress failed (exit $exit_code)"
fi
exit "$exit_code"
