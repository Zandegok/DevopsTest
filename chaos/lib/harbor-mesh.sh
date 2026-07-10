#!/usr/bin/env bash
# Temporarily enable Istio sidecars on Harbor core/registry for chaos scenario 03.
# Harbor namespace must NOT have istio-injection=enabled (breaks Redis TCP).
set -euo pipefail

CHAOS_HARBOR_BACKUP_DIR="${CHAOS_HARBOR_BACKUP_DIR:-/tmp/chaos-k8s-harbor-backup}"

harbor_mesh_backup() {
  mkdir -p "$CHAOS_HARBOR_BACKUP_DIR"
  kubectl -n harbor get deployment harbor-core -o yaml > "$CHAOS_HARBOR_BACKUP_DIR/harbor-core.yaml"
  kubectl -n harbor get deployment harbor-registry -o yaml > "$CHAOS_HARBOR_BACKUP_DIR/harbor-registry.yaml"
}

harbor_mesh_patch_template() {
  local deploy="$1"
  local inject="$2"
  local exclude_ports="${3:-}"
  local patch
  if [[ "$inject" == "true" ]]; then
    if [[ -n "$exclude_ports" ]]; then
      patch=$(cat <<EOF
{
  "spec": {
    "template": {
      "metadata": {
        "annotations": {
          "sidecar.istio.io/inject": "true",
          "traffic.sidecar.istio.io/excludeOutboundPorts": "${exclude_ports}"
        }
      }
    }
  }
}
EOF
)
    else
      patch='{"spec":{"template":{"metadata":{"annotations":{"sidecar.istio.io/inject":"true"}}}}}'
    fi
  else
    patch='{"spec":{"template":{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}}}'
  fi
  kubectl -n harbor patch deployment "$deploy" --type=strategic -p "$patch"
}

harbor_mesh_inject_deployment() {
  local deploy="$1"
  local exclude_ports="${2:-}"
  if [[ -n "$exclude_ports" ]]; then
    harbor_mesh_patch_template "$deploy" true "$exclude_ports"
  else
    harbor_mesh_patch_template "$deploy" true ""
  fi
  kubectl -n harbor get deployment "$deploy" -o yaml \
    | istioctl kube-inject -f - \
    | kubectl apply -f -
}

harbor_mesh_sidecars_ready() {
  assert_sidecar_injection harbor 'app=harbor,component=core'
  assert_sidecar_injection harbor 'app=harbor,component=registry'
}

harbor_mesh_enable() {
  if ! command -v istioctl >/dev/null 2>&1; then
    log_fail "istioctl not found — required for Harbor mesh chaos demo"
    return 1
  fi

  log_info "Enabling selective Istio sidecars on harbor-core and harbor-registry (istioctl kube-inject)"
  kubectl label namespace harbor istio-injection- --overwrite 2>/dev/null || true
  harbor_mesh_backup
  harbor_mesh_inject_deployment harbor-core "6379,5432"
  harbor_mesh_inject_deployment harbor-registry ""
  kubectl -n harbor rollout status deployment/harbor-core --timeout=300s
  kubectl -n harbor rollout status deployment/harbor-registry --timeout=300s
  harbor_registry_mark_http_protocol
  retry 30 10 check_harbor_health
  retry 18 10 harbor_mesh_sidecars_ready
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
  assert_http "$(harbor_url)/api/v2.0/health" 200 15000
}

harbor_mesh_disable() {
  log_info "Removing temporary Istio sidecars from Harbor deployments"
  if [[ -f "$CHAOS_HARBOR_BACKUP_DIR/harbor-core.yaml" ]] \
    && [[ -f "$CHAOS_HARBOR_BACKUP_DIR/harbor-registry.yaml" ]]; then
    kubectl apply -f "$CHAOS_HARBOR_BACKUP_DIR/harbor-core.yaml"
    kubectl apply -f "$CHAOS_HARBOR_BACKUP_DIR/harbor-registry.yaml"
  else
    log_info "Harbor backup missing — patching deployments to disable injection"
    harbor_mesh_patch_template harbor-core false
    harbor_mesh_patch_template harbor-registry false
  fi
  kubectl -n harbor rollout restart deployment/harbor-jobservice deployment/harbor-nginx 2>/dev/null || true
  kubectl -n harbor rollout status deployment/harbor-core --timeout=300s
  kubectl -n harbor rollout status deployment/harbor-registry --timeout=300s
  retry 30 10 check_harbor_health
}
