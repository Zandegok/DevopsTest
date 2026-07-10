#!/usr/bin/env bash
set -euo pipefail

CHART_DIR="${1:?chart dir}"
VALUES="${2:?values file}"
NAMESPACE="${3:-harbor}"
TIMEOUT="${4:-1200}"

log() { echo "[harbor-install $(date +%H:%M:%S)] $*"; }

log "Starting Helm release (no --wait, progress below)"
helm upgrade --install harbor "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --values "$VALUES" \
  --timeout 10m

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/assert.sh
source "$ROOT_DIR/scripts/lib/assert.sh"

elapsed=0
interval=10
max=$TIMEOUT

while [[ "$elapsed" -lt "$max" ]]; do
  total=$(kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')
  running=$(kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null | awk '$3=="Running" && $2 ~ /^([0-9]+)\/\1$/ {c++} END{print c+0}')
  health=$(curl_code "$(harbor_url)/api/v2.0/health" 10)
  step=$((elapsed / interval + 1))
  max_steps=$((max / interval))
  log "progress ${step}/${max_steps}: pods ready ${running}/${total}, health HTTP ${health}"
  if [[ "$total" -gt 0 ]] && [[ "$running" -eq "$total" ]] && [[ "$health" == "200" ]]; then
    log "Harbor is ready"
    exit 0
  fi
  sleep "$interval"
  elapsed=$((elapsed + interval))
done

log "Harbor install timed out after ${max}s"
kubectl -n "$NAMESPACE" get pods
exit 1
