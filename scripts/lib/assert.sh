#!/usr/bin/env bash
# Shared assertion helpers for verify.sh and chaos experiments.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ROOT_DIR

if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -f "$HOME/.kube/config" ]]; then
    export KUBECONFIG="$HOME/.kube/config"
  elif [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  fi
fi

log_pass() { echo "[PASS] $*"; }
log_fail() { echo "[FAIL] $*" >&2; }
log_info() { echo "[INFO] $*"; }

pause_or_skip() {
  local msg="${1:-Press Enter to continue...}"
  if [[ "${DEMO:-0}" == "1" ]]; then
    read -r -p "$msg "
  else
    sleep 2
  fi
}

vm_ip() {
  if [[ -n "${VM_IP:-}" ]]; then
    echo "$VM_IP"
    return 0
  fi
  hostname -I 2>/dev/null | awk '{print $1}'
}

retry() {
  local attempts="${1:?attempts required}"
  shift
  local delay="${1:?delay required}"
  shift
  local i
  for ((i = 1; i <= attempts; i++)); do
    if "$@"; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

curl_code() {
  local url="$1"
  curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time "${2:-30}" "$url" 2>/dev/null || echo "000"
}

curl_body() {
  local url="$1"
  curl -sS --connect-timeout 5 --max-time "${2:-15}" "$url" 2>/dev/null || true
}

measure_latency_ms() {
  local url="$1"
  local timeout="${2:-30}"
  curl -sS -o /dev/null -w "%{time_total}" --connect-timeout 5 --max-time "$timeout" "$url" 2>/dev/null \
    | awk '{printf "%.0f", $1 * 1000}'
}

assert_pods_ready() {
  local namespace="${1:-default}"
  local selector="${2:-}"
  local cmd=(kubectl get pods -n "$namespace" --no-headers)
  if [[ -n "$selector" ]]; then
    cmd+=(-l "$selector")
  fi
  local not_ready
  not_ready=$("${cmd[@]}" 2>/dev/null | awk '$2 !~ /^[0-9]+\/[0-9]+$/ || $3 != "Running" {print}' | wc -l)
  if [[ "$not_ready" -eq 0 ]] && [[ -n $("${cmd[@]}" 2>/dev/null) ]]; then
    log_pass "pods ready in namespace=$namespace selector=${selector:-all}"
    return 0
  fi
  log_fail "pods not ready in namespace=$namespace selector=${selector:-all}"
  kubectl get pods -n "$namespace" 2>/dev/null || true
  return 1
}

assert_http() {
  local url="$1"
  local expect_code="$2"
  local max_ms="${3:-5000}"
  local code ms out
  out=$(curl -sS -o /dev/null -w "%{http_code} %{time_total}" --connect-timeout 5 --max-time 60 "$url" 2>/dev/null || echo "000 999")
  code=$(echo "$out" | awk '{print $1}')
  ms=$(echo "$out" | awk '{printf "%.0f", $2 * 1000}')
  if [[ "$code" == "$expect_code" ]] && [[ "$ms" -le "$max_ms" ]]; then
    log_pass "http $url code=$code latency=${ms}ms (max ${max_ms}ms)"
    return 0
  fi
  log_fail "http $url code=$code (expected $expect_code) latency=${ms}ms (max ${max_ms}ms)"
  return 1
}

assert_http_any_of() {
  local url="$1"
  shift
  local codes=("$@")
  local code
  code=$(curl_code "$url" 60)
  local c
  for c in "${codes[@]}"; do
    if [[ "$code" == "$c" ]]; then
      log_pass "http $url code=$code matches one of: ${codes[*]}"
      return 0
    fi
  done
  log_fail "http $url code=$code not in: ${codes[*]}"
  return 1
}

assert_latency_gt() {
  local url="$1"
  local min_ms="$2"
  local samples="${3:-5}"
  local i
  local max_seen=0
  for ((i = 1; i <= samples; i++)); do
    local ms
    ms=$(measure_latency_ms "$url" 120)
    if [[ "$ms" -gt "$max_seen" ]]; then
      max_seen=$ms
    fi
    sleep 1
  done
  if [[ "$max_seen" -gt "$min_ms" ]]; then
    log_pass "latency $url max=${max_seen}ms > ${min_ms}ms (${samples} samples)"
    return 0
  fi
  log_fail "latency $url max=${max_seen}ms not > ${min_ms}ms (${samples} samples)"
  return 1
}

measure_mesh_bookinfo_latency_ms() {
  kubectl exec deploy/ratings-v1 -c ratings -- \
    curl -sS -o /dev/null -w "%{time_total}" --connect-timeout 5 --max-time 120 \
    http://productpage:9080/productpage 2>/dev/null \
    | awk '{printf "%.0f", $1 * 1000}'
}

assert_mesh_bookinfo_latency_gt() {
  local min_ms="$1"
  local samples="${2:-5}"
  local i
  local max_seen=0
  for ((i = 1; i <= samples; i++)); do
    local ms
    ms=$(measure_mesh_bookinfo_latency_ms)
    if [[ "$ms" -gt "$max_seen" ]]; then
      max_seen=$ms
    fi
    sleep 1
  done
  if [[ "$max_seen" -gt "$min_ms" ]]; then
    log_pass "mesh productpage latency max=${max_seen}ms > ${min_ms}ms (${samples} samples)"
    return 0
  fi
  log_fail "mesh productpage latency max=${max_seen}ms not > ${min_ms}ms (${samples} samples)"
  return 1
}

assert_body_contains() {
  local url="$1"
  local needle="$2"
  local body
  body=$(curl -sS --connect-timeout 5 --max-time 60 "$url" 2>/dev/null || true)
  if echo "$body" | grep -q "$needle"; then
    log_pass "body of $url contains '$needle'"
    return 0
  fi
  log_fail "body of $url does not contain '$needle'"
  return 1
}

assert_body_not_contains() {
  local url="$1"
  local needle="$2"
  local body
  body=$(curl -sS --connect-timeout 5 --max-time 60 "$url" 2>/dev/null || true)
  if ! echo "$body" | grep -q "$needle"; then
    log_pass "body of $url does not contain '$needle'"
    return 0
  fi
  log_fail "body of $url still contains '$needle'"
  return 1
}

assert_sidecar_injection() {
  local namespace="${1:-default}"
  local label="${2:-app=productpage}"
  local pods
  pods=$(kubectl get pods -n "$namespace" -l "$label" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containers[*].name}{"\n"}{end}' 2>/dev/null || true)
  if echo "$pods" | grep -q istio-proxy; then
    log_pass "sidecar injection present for $label in $namespace"
    return 0
  fi
  log_fail "sidecar injection missing for $label in $namespace"
  echo "$pods"
  return 1
}

k8s_nodeport() {
  local ns="$1"
  local svc="$2"
  local filter="$3"
  kubectl -n "$ns" get svc "$svc" -o "jsonpath={.spec.ports[?(${filter})].nodePort}" 2>/dev/null \
    | tr -d '[:space:]'
}

bookinfo_nodeport() {
  local port=""
  if [[ -n "${BOOKINFO_NODEPORT:-}" ]]; then
    echo "$BOOKINFO_NODEPORT"
    return 0
  fi
  port=$(k8s_nodeport default productpage-nodeport '@.name=="http"')
  if [[ -z "$port" ]]; then
    # Compatibility with older installs before productpage-nodeport existed.
    port=$(k8s_nodeport istio-system istio-ingressgateway '@.name=="http2"')
  fi
  if [[ -z "$port" ]]; then
    port=$(k8s_nodeport istio-system istio-ingressgateway '@.port==80')
  fi
  if [[ -n "$port" ]]; then
    echo "$port"
  fi
}

bookinfo_url() {
  local ip port
  ip=$(vm_ip)
  port=$(bookinfo_nodeport || true)
  echo "http://${ip:-127.0.0.1}:${port:-30080}/productpage"
}

bookinfo_ingress_url() {
  local ip port
  ip=$(vm_ip)
  port=$(k8s_nodeport istio-system istio-ingressgateway '@.name=="http2"')
  if [[ -z "$port" ]]; then
    port=$(k8s_nodeport istio-system istio-ingressgateway '@.port==80')
  fi
  echo "http://${ip:-127.0.0.1}:${port:-30080}/productpage"
}

harbor_nodeport() {
  local port=""
  if [[ -n "${HARBOR_NODEPORT:-}" ]]; then
    echo "$HARBOR_NODEPORT"
    return 0
  fi
  port=$(k8s_nodeport harbor harbor '@.name=="http"')
  if [[ -z "$port" ]]; then
    port=$(k8s_nodeport harbor harbor '@.port==80')
  fi
  if [[ -n "$port" ]]; then
    echo "$port"
  fi
}

harbor_url() {
  local ip port
  ip=$(vm_ip)
  port=$(harbor_nodeport || true)
  echo "http://${ip:-127.0.0.1}:${port:-30002}"
}

grafana_nodeport() {
  local port=""
  port=$(kubectl -n monitoring get svc -l app.kubernetes.io/name=grafana \
    -o jsonpath='{.items[0].spec.ports[?(@.port==80)].nodePort}' 2>/dev/null | tr -d '[:space:]')
  if [[ -z "$port" ]]; then
    port=$(kubectl -n monitoring get svc -l app.kubernetes.io/name=grafana \
      -o jsonpath='{.items[0].spec.ports[0].nodePort}' 2>/dev/null | tr -d '[:space:]')
  fi
  if [[ -z "$port" ]]; then
    return 1
  fi
  if [[ -n "${GRAFANA_NODEPORT:-}" ]]; then
    echo "$GRAFANA_NODEPORT"
  else
    echo "$port"
  fi
}

grafana_installed() {
  kubectl -n monitoring get svc -l app.kubernetes.io/name=grafana -o name >/dev/null 2>&1
}

grafana_url() {
  local ip port
  ip=$(vm_ip)
  port=$(grafana_nodeport || true)
  [[ -n "$port" ]] || return 1
  echo "http://${ip:-127.0.0.1}:${port}"
}

ensure_istio_ingress_nodeport() {
  local typ np
  typ=$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.type}' 2>/dev/null || true)
  np=$(k8s_nodeport istio-system istio-ingressgateway '@.name=="http2"')
  if [[ -z "$np" ]] && [[ "$typ" != "NodePort" ]]; then
    log_info "istio-ingressgateway: switching Service type to NodePort (bare-metal/k3s)"
    kubectl -n istio-system patch svc istio-ingressgateway -p '{"spec":{"type":"NodePort"}}'
  fi
}

apply_bookinfo_routing() {
  kubectl apply -f "$ROOT_DIR/manifests/bookinfo/gateway.yaml"
  kubectl apply -f "$ROOT_DIR/manifests/bookinfo/productpage-nodeport.yaml"
  kubectl apply -f "$ROOT_DIR/manifests/bookinfo/destination-rules.yaml" >/dev/null 2>&1 || true
}

delete_bookinfo_routing() {
  kubectl -n default delete gateway/bookinfo-gateway virtualservice/bookinfo --ignore-not-found
}

restart_istio_ingress() {
  log_info "restarting istio-ingressgateway..."
  kubectl -n istio-system rollout restart deployment/istio-ingressgateway
  if ! kubectl -n istio-system rollout status deployment/istio-ingressgateway --timeout=120s; then
    log_info "ingress rollout still in progress (continuing)"
    kubectl -n istio-system get pods -l app=istio-ingressgateway 2>/dev/null || true
  fi
  if [[ "${BOOKINFO_RESTART_ISTIOD:-0}" == "1" ]]; then
    log_info "restarting istiod (BOOKINFO_RESTART_ISTIOD=1)..."
    kubectl -n istio-system rollout restart deployment/istiod
    kubectl -n istio-system rollout status deployment/istiod --timeout=120s || true
  fi
  sleep 5
}

wait_bookinfo_endpoints() {
  local i eps
  for ((i = 1; i <= 12; i++)); do
    eps=$(kubectl get endpoints productpage -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
    if [[ -n "$eps" ]]; then
      log_info "productpage endpoint ready ($eps)"
      return 0
    fi
    log_info "waiting for productpage endpoints (${i}/12)..."
    sleep 5
  done
  log_info "productpage endpoints not found (continuing)"
}

bookinfo_external_check() {
  local code
  code=$(curl_code "$(bookinfo_url)" 15)
  [[ "$code" == "200" ]]
}

bookinfo_ingress_check() {
  local code
  code=$(curl_code "$(bookinfo_ingress_url)" 15)
  [[ "$code" == "200" ]]
}

ingress_self_check() {
  local gw_pod code
  gw_pod=$(kubectl -n istio-system get pod -l app=istio-ingressgateway \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "$gw_pod" ]]; then
    echo "000"
    return 1
  fi
  code=$(kubectl -n istio-system exec "$gw_pod" -- \
    curl -sS -o /dev/null -w "%{http_code}" --max-time 10 http://127.0.0.1:8080/productpage 2>/dev/null || echo "000")
  echo "$code"
  [[ "$code" == "200" ]]
}

dump_bookinfo_ingress_debug() {
  local url body gw_pod
  url="$(bookinfo_url)"
  body=$(curl_body "$url" 10 | tr '\n' ' ' | cut -c1-240)
  log_info "external body: ${body:-<empty>}"

  gw_pod=$(kubectl -n istio-system get pod -l app=istio-ingressgateway \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "$gw_pod" ]]; then
    body=$(kubectl -n istio-system exec "$gw_pod" -- \
      curl -sS --max-time 10 http://127.0.0.1:8080/productpage 2>/dev/null | tr '\n' ' ' | cut -c1-240 || true)
    log_info "in-gateway body: ${body:-<empty>}"
  fi

  kubectl -n default get gateway/bookinfo-gateway virtualservice/bookinfo -o yaml 2>/dev/null | sed -n '1,120p' || true
  if command -v istioctl >/dev/null 2>&1; then
    istioctl proxy-config routes -n istio-system deploy/istio-ingressgateway 2>/dev/null | sed -n '1,80p' || true
  fi
}

ensure_bookinfo_gateway() {
  ensure_bookinfo_ingress
}

ensure_bookinfo_ingress() {
  local gw_port tries code inpod

  log_info "Bookinfo ingress: applying k3s/NodePort routing"

  if [[ ! -f "$ROOT_DIR/manifests/bookinfo/gateway.yaml" ]]; then
    log_fail "missing Bookinfo gateway manifests under manifests/bookinfo/"
    return 1
  fi

  ensure_istio_ingress_nodeport
  wait_bookinfo_endpoints

  gw_port=$(kubectl -n default get gateway bookinfo-gateway \
    -o jsonpath='{.spec.servers[0].port.number}' 2>/dev/null || true)

  if [[ "$gw_port" != "80" ]] || ! kubectl -n default get virtualservice bookinfo >/dev/null 2>&1; then
    log_info "Bookinfo routing: applying Gateway port 80"
    apply_bookinfo_routing
  else
    kubectl apply -f "$ROOT_DIR/manifests/bookinfo/gateway.yaml" >/dev/null
    kubectl apply -f "$ROOT_DIR/manifests/bookinfo/productpage-nodeport.yaml" >/dev/null
    kubectl apply -f "$ROOT_DIR/manifests/bookinfo/destination-rules.yaml" >/dev/null 2>&1 || true
  fi

  if bookinfo_external_check; then
    log_pass "Bookinfo external access OK (productpage NodePort HTTP 200)"
    if ! bookinfo_ingress_check; then
      log_info "Istio ingress still returns HTTP $(curl_code "$(bookinfo_ingress_url)" 10); using direct productpage NodePort on this VPS"
    fi
    return 0
  fi

  code=$(curl_code "$(bookinfo_url)" 15)
  log_info "productpage NodePort HTTP ${code:-000}; recreating Bookinfo services"

  kubectl -n default delete service/productpage-nodeport --ignore-not-found
  delete_bookinfo_routing
  sleep 3
  apply_bookinfo_routing
  sleep 10

  tries=0
  while [[ "$tries" -lt 6 ]]; do
    code=$(curl_code "$(bookinfo_url)" 15)
    log_info "retry $((tries + 1))/6 external Bookinfo HTTP ${code:-000}"
    if [[ "$code" == "200" ]]; then
      log_pass "Bookinfo external access OK after service recreate (productpage NodePort HTTP 200)"
      return 0
    fi
    sleep 5
    tries=$((tries + 1))
  done

  code=$(curl_code "$(bookinfo_url)" 15)
  inpod=$(ingress_self_check || true)
  log_fail "Bookinfo still external HTTP ${code:-000}, in-gateway HTTP ${inpod:-000}"
  log_info "URL=$(bookinfo_url) Gateway port=$(kubectl -n default get gateway bookinfo-gateway -o jsonpath='{.spec.servers[0].port.number}' 2>/dev/null || echo '?')"
  kubectl -n istio-system get svc istio-ingressgateway 2>/dev/null || true
  kubectl -n default get gateway,virtualservice 2>/dev/null || true
  kubectl get endpoints productpage 2>/dev/null || true
  dump_bookinfo_ingress_debug
  return 1
}

wait_for_url() {
  local url="$1"
  local expect_code="${2:-200}"
  local timeout="${3:-300}"
  local label="${4:-$url}"
  local elapsed=0
  local interval=5
  while [[ "$elapsed" -lt "$timeout" ]]; do
    local code
    code=$(curl_code "$url" 10)
    log_info "wait ${label}: HTTP ${code} (want ${expect_code}) ${elapsed}s/${timeout}s"
    if [[ "$code" == "$expect_code" ]]; then
      log_pass "ready ${label} at ${url}"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  log_fail "timeout ${label} at ${url} (last HTTP ${code:-000})"
  return 1
}
