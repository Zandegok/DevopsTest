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

harbor_mesh_use_recreate_strategy() {
  local deploy="$1"
  kubectl -n harbor patch deployment "$deploy" --type=strategic \
    -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}' >/dev/null
}

harbor_mesh_cleanup_old_replicasets() {
  local component="$1"
  local rs
  while IFS= read -r rs; do
    [[ -z "$rs" ]] && continue
    log_info "Deleting old Harbor replicaset: $rs"
    kubectl -n harbor delete "$rs" --ignore-not-found >/dev/null 2>&1 || true
  done < <(kubectl -n harbor get rs -l "app=harbor,component=${component}" \
    --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | head -n -1)
}

harbor_mesh_drain_deploy() {
  local deploy="$1"
  local component
  component=$(harbor_mesh_component_from_deploy "$deploy")
  kubectl -n harbor scale deployment "$deploy" --replicas=0
  sleep 8
  kubectl -n harbor delete pods -l "app=harbor,component=${component}" \
    --force --grace-period=0 >/dev/null 2>&1 || true
}

harbor_mesh_scale_reset() {
  local deploy="$1"
  log_info "Scale reset for $deploy"
  harbor_mesh_drain_deploy "$deploy"
  harbor_mesh_use_recreate_strategy "$deploy"
  kubectl -n harbor scale deployment "$deploy" --replicas=1
}

harbor_mesh_emergency_reset() {
  log_info "Emergency Harbor reset: Recreate strategy, scale to 0, remove sidecars, scale back to 1"
  harbor_mesh_use_recreate_strategy harbor-core
  harbor_mesh_use_recreate_strategy harbor-registry
  harbor_mesh_drain_deploy harbor-core
  harbor_mesh_drain_deploy harbor-registry
  harbor_mesh_remove_sidecar harbor-core
  harbor_mesh_remove_sidecar harbor-registry
  kubectl -n harbor scale deployment harbor-core harbor-registry --replicas=1
  harbor_wait_healthy 72
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
  kubectl -n harbor annotate deployment "$deploy" \
    sidecar.istio.io/inject- \
    traffic.sidecar.istio.io/excludeOutboundPorts- \
    kubectl.kubernetes.io/last-applied-configuration- \
    --overwrite 2>/dev/null || true
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

harbor_mesh_apply_injected() {
  local deploy="$1"
  local tmpfile tries=0
  while [[ tries -lt 10 ]]; do
    tmpfile=$(mktemp)
    kubectl -n harbor get deployment "$deploy" -o yaml \
      | istioctl kube-inject -f - > "$tmpfile"
    if kubectl apply --server-side --force-conflicts --field-manager=chaos-k8s -f "$tmpfile" 2>/dev/null; then
      rm -f "$tmpfile"
      return 0
    fi
    rm -f "$tmpfile"
    tries=$((tries + 1))
    log_info "kube-inject apply conflict on $deploy, retry ${tries}/10"
    sleep 5
  done
  log_fail "Failed to apply kube-inject manifest for $deploy"
  return 1
}

harbor_mesh_inject_deployment() {
  local deploy="$1"
  local exclude_ports="${2:-}"
  harbor_mesh_use_recreate_strategy "$deploy"
  harbor_mesh_drain_deploy "$deploy"
  if [[ -n "$exclude_ports" ]]; then
    harbor_mesh_patch_template "$deploy" true "$exclude_ports"
  else
    harbor_mesh_patch_template "$deploy" true ""
  fi
  harbor_mesh_short_grace "$deploy"
  harbor_mesh_apply_injected "$deploy"
  kubectl -n harbor scale deployment "$deploy" --replicas=1
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

harbor_restart_dependencies() {
  log_info "Restarting Harbor nginx and backing services"
  kubectl -n harbor rollout restart deployment/harbor-nginx 2>/dev/null || true
  kubectl -n harbor rollout restart statefulset/harbor-redis 2>/dev/null || true
  kubectl -n harbor rollout restart statefulset/harbor-database 2>/dev/null || true
  kubectl -n harbor rollout restart deployment/harbor-jobservice 2>/dev/null || true
}

harbor_wait_healthy() {
  local attempts="${1:-72}"
  local i code ready
  log_info "Waiting for Harbor /api/v2.0/health (up to $((attempts * 10))s; slow on 4 GB VM)"
  for ((i = 1; i <= attempts; i++)); do
    code=$(curl_code "$(harbor_url)/api/v2.0/health" 20)
    ready=$(kubectl -n harbor get pods -l app=harbor,component=core \
      -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="core")].ready}' 2>/dev/null || echo false)
    log_info "Harbor health HTTP ${code:-000}, core ready=${ready:-?} (${i}/${attempts})"
    if [[ "$code" == "200" ]]; then
      log_pass "Harbor health OK"
      return 0
    fi
    if (( i == 12 || i == 24 || i == 36 )); then
      kubectl -n harbor get pods -l 'app=harbor,component in (core,registry,nginx)' --no-headers 2>/dev/null || true
      kubectl -n harbor logs deploy/harbor-core -c core --tail=5 2>/dev/null || true
    fi
    sleep 10
  done
  log_fail "Harbor did not become healthy in time"
  kubectl -n harbor get pods -l 'app=harbor' --no-headers 2>/dev/null || true
  kubectl -n harbor describe pod -l app=harbor,component=core 2>/dev/null | tail -40 || true
  return 1
}

check_harbor_health() {
  assert_http "$(harbor_url)/api/v2.0/health" 200 15000
}

harbor_mesh_disable() {
  log_info "Removing temporary Istio sidecars from Harbor deployments"
  harbor_mesh_remove_sidecar harbor-core
  harbor_mesh_remove_sidecar harbor-registry
  harbor_wait_healthy 48
}
