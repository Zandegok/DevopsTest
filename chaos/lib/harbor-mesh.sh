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

harbor_mesh_component_from_deploy() {
  case "$1" in
    harbor-core) echo core ;;
    harbor-registry) echo registry ;;
    *) echo "$1" ;;
  esac
}

harbor_mesh_short_grace() {
  local deploy="$1"
  kubectl -n harbor patch deployment "$deploy" --type=strategic \
    -p '{"spec":{"template":{"spec":{"terminationGracePeriodSeconds":30}}}}' >/dev/null
}

harbor_mesh_delete_stuck_pods() {
  local component="$1"
  local newest_rs pod rs
  newest_rs=$(kubectl -n harbor get rs -l "app=harbor,component=${component}" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pod=${line%% *}
    rs=${line#* }
    if [[ -n "$newest_rs" && "$rs" == "$newest_rs" ]]; then
      continue
    fi
    log_info "Removing old Harbor pod blocking rollout: $pod"
    kubectl -n harbor delete pod "$pod" --force --grace-period=0 >/dev/null 2>&1 || true
  done < <(kubectl -n harbor get pods -l "app=harbor,component=${component}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.ownerReferences[0].name}{"\n"}{end}' 2>/dev/null || true)
  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    log_info "Force deleting terminating Harbor pod: $pod"
    kubectl -n harbor delete pod "$pod" --force --grace-period=0 >/dev/null 2>&1 || true
  done < <(kubectl -n harbor get pods -l "app=harbor,component=${component}" --no-headers 2>/dev/null \
    | awk '$3 ~ /Terminating|Unknown/ {print $1}')
}

harbor_mesh_wait_rollout() {
  local deploy="$1"
  local timeout="${2:-420}"
  local component elapsed=0 interval=20 tried_reset=0
  component=$(harbor_mesh_component_from_deploy "$deploy")
  while (( elapsed < timeout )); do
    if kubectl -n harbor rollout status "deployment/$deploy" --timeout=20s >/dev/null 2>&1; then
      log_pass "Harbor rollout complete: $deploy"
      return 0
    fi
    log_info "Waiting for $deploy rollout (${elapsed}s/${timeout}s)"
    kubectl -n harbor get pods -l "app=harbor,component=${component}" --no-headers 2>/dev/null || true
    harbor_mesh_delete_stuck_pods "$component"
    if (( elapsed >= 120 && tried_reset == 0 )); then
      tried_reset=1
      log_info "Rollout still stuck on $deploy — trying scale-to-zero reset"
      harbor_mesh_scale_reset "$deploy"
    fi
    elapsed=$((elapsed + interval))
  done
  log_fail "Harbor rollout stuck: $deploy"
  kubectl -n harbor get pods -l "app=harbor,component=${component}" -o wide 2>/dev/null || true
  return 1
}

harbor_mesh_scale_reset() {
  local deploy="$1"
  log_info "Scale reset for $deploy"
  kubectl -n harbor scale deployment "$deploy" --replicas=0
  sleep 8
  kubectl -n harbor delete pods -l "app=harbor,component=$(harbor_mesh_component_from_deploy "$deploy")" \
    --force --grace-period=0 >/dev/null 2>&1 || true
  kubectl -n harbor scale deployment "$deploy" --replicas=1
}

harbor_mesh_emergency_reset() {
  log_info "Emergency Harbor reset: scale to 0, remove sidecars, scale back to 1"
  kubectl -n harbor scale deployment harbor-core harbor-registry --replicas=0
  sleep 10
  kubectl -n harbor delete pods -l 'app=harbor,component in (core,registry)' \
    --force --grace-period=0 >/dev/null 2>&1 || true
  harbor_mesh_remove_sidecar harbor-core
  harbor_mesh_remove_sidecar harbor-registry
  kubectl -n harbor scale deployment harbor-core harbor-registry --replicas=1
  harbor_mesh_wait_rollout harbor-core 600
  harbor_mesh_wait_rollout harbor-registry 600
  retry 30 10 check_harbor_health
  log_pass "Harbor emergency reset complete"
}

harbor_mesh_remove_sidecar() {
  local deploy="$1"
  local patch
  harbor_mesh_short_grace "$deploy"
  patch=$(cat <<'EOF'
{
  "spec": {
    "template": {
      "metadata": {
        "annotations": {
          "istio.io/rev": null,
          "kubectl.kubernetes.io/default-container": null,
          "kubectl.kubernetes.io/default-logs-container": null,
          "prometheus.io/path": null,
          "prometheus.io/port": null,
          "prometheus.io/scrape": null,
          "sidecar.istio.io/inject": "false",
          "sidecar.istio.io/status": null,
          "traffic.sidecar.istio.io/excludeOutboundPorts": null
        },
        "labels": {
          "security.istio.io/tlsMode": null,
          "service.istio.io/canonical-name": null,
          "service.istio.io/canonical-revision": null
        }
      },
      "spec": {
        "containers": [
          {
            "$patch": "delete",
            "name": "istio-proxy"
          }
        ],
        "initContainers": null,
        "volumes": [
          {
            "$patch": "delete",
            "name": "credential-socket"
          },
          {
            "$patch": "delete",
            "name": "istio-data"
          },
          {
            "$patch": "delete",
            "name": "istio-envoy"
          },
          {
            "$patch": "delete",
            "name": "istio-podinfo"
          },
          {
            "$patch": "delete",
            "name": "istio-token"
          },
          {
            "$patch": "delete",
            "name": "istiod-ca-cert"
          },
          {
            "$patch": "delete",
            "name": "workload-certs"
          },
          {
            "$patch": "delete",
            "name": "workload-socket"
          }
        ]
      }
    }
  }
}
EOF
)
  kubectl -n harbor patch deployment "$deploy" --type=strategic -p "$patch"
  kubectl -n harbor annotate deployment "$deploy" kubectl.kubernetes.io/last-applied-configuration- --overwrite 2>/dev/null || true
}

harbor_mesh_reset_current() {
  log_info "Resetting any leftover Harbor sidecars before backup"
  harbor_mesh_remove_sidecar harbor-core
  harbor_mesh_remove_sidecar harbor-registry
  harbor_mesh_wait_rollout harbor-core
  harbor_mesh_wait_rollout harbor-registry
  retry 30 10 check_harbor_health
}

harbor_mesh_has_sidecars() {
  local containers
  containers=$(kubectl -n harbor get pods -l 'app=harbor,component in (core,registry)' \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containers[*].name}{"\n"}{end}' 2>/dev/null || true)
  echo "$containers" | grep -q 'istio-proxy'
}

harbor_mesh_reset_if_needed() {
  if harbor_mesh_has_sidecars; then
    harbor_mesh_reset_current
  fi
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
  harbor_mesh_short_grace "$deploy"
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
  harbor_mesh_reset_if_needed
  harbor_mesh_backup
  harbor_mesh_inject_deployment harbor-core "6379,5432"
  harbor_mesh_inject_deployment harbor-registry ""
  harbor_mesh_wait_rollout harbor-core
  harbor_mesh_wait_rollout harbor-registry
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
  harbor_mesh_remove_sidecar harbor-core
  harbor_mesh_remove_sidecar harbor-registry
  harbor_mesh_wait_rollout harbor-core
  harbor_mesh_wait_rollout harbor-registry
  retry 30 10 check_harbor_health
}
