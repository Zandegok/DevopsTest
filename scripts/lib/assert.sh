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
  local code
  local ms
  code=$(curl_code "$url" 60)
  ms=$(measure_latency_ms "$url" 60)
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
  # Istio docs: Service port name "http2" is HTTP on port 80
  port=$(k8s_nodeport istio-system istio-ingressgateway '@.name=="http2"')
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
  if [[ -n "${GRAFANA_NODEPORT:-}" ]]; then
    echo "$GRAFANA_NODEPORT"
    return 0
  fi
  port=$(kubectl -n monitoring get svc -l app.kubernetes.io/name=grafana \
    -o jsonpath='{.items[0].spec.ports[?(@.port==80)].nodePort}' 2>/dev/null | tr -d '[:space:]')
  if [[ -z "$port" ]]; then
    port=$(kubectl -n monitoring get svc -l app.kubernetes.io/name=grafana \
      -o jsonpath='{.items[0].spec.ports[0].nodePort}' 2>/dev/null | tr -d '[:space:]')
  fi
  if [[ -n "$port" ]]; then
    echo "$port"
  fi
}

grafana_url() {
  local ip port
  ip=$(vm_ip)
  port=$(grafana_nodeport || true)
  echo "http://${ip:-127.0.0.1}:${port:-30300}"
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
  local manifest="$1"
  kubectl apply -f "$manifest"
  kubectl apply -f "$ROOT_DIR/manifests/bookinfo/destination-rules.yaml" >/dev/null 2>&1 || true
}

clear_bookinfo_faults() {
  kubectl delete -f "$ROOT_DIR/manifests/istio/faults/" --ignore-not-found 2>/dev/null || true
}

bookinfo_gateway_manifest() {
  local typ lb
  typ=$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.type}' 2>/dev/null || true)
  lb=$(kubectl -n istio-system get svc istio-ingressgateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ "$typ" == "NodePort" || -z "$lb" ]]; then
    echo "$ROOT_DIR/manifests/bookinfo/gateway-port80.yaml"
  else
    echo "$ROOT_DIR/manifests/bookinfo/gateway.yaml"
  fi
}

gateway_manifest_port() {
  local manifest="$1"
  if [[ "$manifest" == *gateway-port80* ]]; then
    echo "80"
  else
    echo "8080"
  fi
}

restart_istio_ingress() {
  kubectl -n istio-system rollout restart deployment/istiod deployment/istio-ingressgateway
  kubectl -n istio-system rollout status deployment/istiod --timeout=180s
  kubectl -n istio-system rollout status deployment/istio-ingressgateway --timeout=180s
  sleep 10
}

bookinfo_external_check() {
  local code
  code=$(curl_code "$(bookinfo_url)" 15)
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

wait_bookinfo_endpoints() {
  kubectl wait --for=condition=ready endpoints/productpage --timeout=120s >/dev/null 2>&1 || true
}

ensure_bookinfo_gateway() {
  ensure_bookinfo_ingress
}

ensure_bookinfo_ingress() {
  local official="$ROOT_DIR/manifests/bookinfo/gateway.yaml"
  local fallback="$ROOT_DIR/manifests/bookinfo/gateway-port80.yaml"
  local primary alt manifest_port gw_port tries=0 code inpod

  if [[ ! -f "$official" || ! -f "$fallback" ]]; then
    log_fail "missing Bookinfo gateway manifests under manifests/bookinfo/"
    return 1
  fi

  ensure_istio_ingress_nodeport
  clear_bookinfo_faults
  wait_bookinfo_endpoints

  primary=$(bookinfo_gateway_manifest)
  if [[ "$primary" == "$fallback" ]]; then
    alt="$official"
  else
    alt="$fallback"
  fi
  manifest_port=$(gateway_manifest_port "$primary")

  gw_port=$(kubectl -n default get gateway bookinfo-gateway \
    -o jsonpath='{.spec.servers[0].port.number}' 2>/dev/null || true)

  if [[ "$gw_port" != "$manifest_port" ]] || ! kubectl -n default get virtualservice bookinfo >/dev/null 2>&1; then
    log_info "Bookinfo routing: applying Gateway port ${manifest_port} ($(basename "$primary"))"
    apply_bookinfo_routing "$primary"
  else
    kubectl apply -f "$primary" >/dev/null
    kubectl apply -f "$ROOT_DIR/manifests/bookinfo/destination-rules.yaml" >/dev/null 2>&1 || true
  fi

  if bookinfo_external_check; then
    log_pass "Bookinfo ingress OK (external HTTP 200, Gateway port ${manifest_port})"
    return 0
  fi

  code=$(curl_code "$(bookinfo_url)" 15)
  log_info "external Bookinfo HTTP ${code:-000}, recreating routing and restarting Istio"

  kubectl -n default delete gateway bookinfo-gateway virtualservice bookinfo --ignore-not-found
  sleep 3
  apply_bookinfo_routing "$primary"
  restart_istio_ingress

  tries=0
  while [[ "$tries" -lt 18 ]]; do
    if bookinfo_external_check; then
      log_pass "Bookinfo ingress OK after restart (external HTTP 200, Gateway port ${manifest_port})"
      return 0
    fi
    sleep 5
    tries=$((tries + 1))
  done

  log_info "primary Gateway port ${manifest_port} failed, trying alternate manifest"
  kubectl -n default delete gateway bookinfo-gateway virtualservice bookinfo --ignore-not-found
  sleep 3
  apply_bookinfo_routing "$alt"
  restart_istio_ingress

  tries=0
  while [[ "$tries" -lt 18 ]]; do
    if bookinfo_external_check; then
      log_pass "Bookinfo ingress OK (alternate Gateway, external HTTP 200)"
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
