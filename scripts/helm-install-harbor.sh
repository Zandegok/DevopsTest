#!/usr/bin/env bash
set -euo pipefail

CHART_DIR="${1:?chart dir}"
VALUES="${2:?values file}"
NAMESPACE="${3:-harbor}"
TIMEOUT="${4:-1200}"

log() { echo "[harbor-install $(date +%H:%M:%S)] $*"; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/assert.sh
source "$ROOT_DIR/scripts/lib/assert.sh"

helm_args=(upgrade --install harbor "$CHART_DIR" --namespace "$NAMESPACE" --values "$VALUES" --timeout 10m)
if [[ -n "${HARBOR_NODEPORT:-}" ]]; then
  helm_args+=(--set-string "expose.nodePort.ports.http.nodePort=${HARBOR_NODEPORT}")
fi

log "Starting Helm release (NodePort ${HARBOR_NODEPORT:-auto})"
helm "${helm_args[@]}"

sync_harbor_external_url() {
  local ip port tries=0
  ip=$(vm_ip)
  while [[ "$tries" -lt 30 ]]; do
    port=$(harbor_nodeport || true)
    if [[ -n "$port" ]]; then
      log "Setting externalURL=http://${ip}:${port}"
      helm upgrade harbor "$CHART_DIR" \
        --namespace "$NAMESPACE" \
        --reuse-values \
        --set-string "externalURL=http://${ip}:${port}" \
        --timeout 5m
      return 0
    fi
    sleep 2
    tries=$((tries + 1))
  done
  log "Could not resolve Harbor NodePort for externalURL sync"
  return 1
}

sync_harbor_external_url || true

elapsed=0
interval=10
max=$TIMEOUT

while [[ "$elapsed" -lt "$max" ]]; do
  total=$(kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')
  running=$(kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null | awk '$3=="Running" && $2 ~ /^([0-9]+)\/\1$/ {c++} END{print c+0}')
  health=$(curl_code "$(harbor_url)/api/v2.0/health" 10)
  step=$((elapsed / interval + 1))
  max_steps=$((max / interval))
  log "progress ${step}/${max_steps}: pods ready ${running}/${total}, health HTTP ${health}, url $(harbor_url)"
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
