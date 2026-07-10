#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/assert.sh
source "$ROOT_DIR/scripts/lib/assert.sh"

SCENARIO="${1:-default}"

case "$SCENARIO" in
  *harbor*)
    assert_http "$(harbor_url)/api/v2.0/health" 200 5000
    ;;
  *)
    assert_http "$(bookinfo_url)" 200 5000
    assert_sidecar_injection default 'app=productpage'
    ;;
esac
