#!/usr/bin/env bash
# Temporarily enable Istio sidecars on Harbor core/registry for chaos scenario 03.
# Harbor namespace must NOT have istio-injection=enabled (breaks Redis TCP).
set -euo pipefail

harbor_mesh_enable() {
  log_info "Enabling selective Istio sidecars on harbor-core and harbor-registry"
  kubectl -n harbor annotate deployment harbor-core \
    sidecar.istio.io/inject=true \
    traffic.sidecar.istio.io/excludeOutboundPorts=6379,5432 \
    --overwrite
  kubectl -n harbor annotate deployment harbor-registry \
    sidecar.istio.io/inject=true \
    --overwrite
  kubectl -n harbor rollout restart deployment/harbor-core deployment/harbor-registry
  kubectl -n harbor rollout status deployment/harbor-core --timeout=300s
  kubectl -n harbor rollout status deployment/harbor-registry --timeout=300s
  harbor_registry_mark_http_protocol
  retry 12 10 check_harbor_health
}

harbor_registry_mark_http_protocol() {
  local port_name
  port_name=$(kubectl -n harbor get svc harbor-registry -o jsonpath='{.spec.ports[0].name}' 2>/dev/null || true)
  if [[ "$port_name" == http-* ]]; then
    return 0
  fi
  log_info "Marking harbor-registry:5000 as HTTP for Istio fault injection"
  kubectl -n harbor patch svc harbor-registry --type=json \
    -p='[{"op":"replace","path":"/spec/ports/0/name","value":"http-registry"},{"op":"add","path":"/spec/ports/0/appProtocol","value":"http"}]' \
    2>/dev/null || true
}

check_harbor_health() {
  assert_http "$(harbor_url)/api/v2.0/health" 200 5000
}

harbor_mesh_disable() {
  log_info "Removing temporary Istio sidecars from Harbor deployments"
  kubectl -n harbor annotate deployment harbor-core \
    sidecar.istio.io/inject- \
    traffic.sidecar.istio.io/excludeOutboundPorts- \
    --overwrite 2>/dev/null || true
  kubectl -n harbor annotate deployment harbor-registry \
    sidecar.istio.io/inject- \
    --overwrite 2>/dev/null || true
  kubectl -n harbor rollout restart deployment/harbor-core deployment/harbor-registry \
    deployment/harbor-jobservice deployment/harbor-nginx 2>/dev/null || true
  kubectl -n harbor rollout status deployment/harbor-core --timeout=300s
  retry 12 10 check_harbor_health
}
