#!/usr/bin/env bash
# Shared assertion helpers for verify.sh and chaos experiments.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ROOT_DIR

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

bookinfo_url() {
  local ip
  ip=$(vm_ip)
  local port
  port=$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}' 2>/dev/null || echo "30080")
  echo "http://${ip}:${port}/productpage"
}

harbor_url() {
  local ip
  ip=$(vm_ip)
  echo "http://${ip}:30002"
}

grafana_url() {
  local ip
  ip=$(vm_ip)
  echo "http://${ip}:30300"
}

wait_for_url() {
  local url="$1"
  local expect_code="${2:-200}"
  local timeout="${3:-300}"
  local elapsed=0
  while [[ "$elapsed" -lt "$timeout" ]]; do
    local code
    code=$(curl_code "$url" 10)
    if [[ "$code" == "$expect_code" ]]; then
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 1
}
