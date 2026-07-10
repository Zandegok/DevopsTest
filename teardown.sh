#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[teardown] Removing chaos fault manifests..."
kubectl delete -f "$ROOT_DIR/manifests/istio/faults/" --ignore-not-found 2>/dev/null || true

echo "[teardown] Uninstalling Helm releases..."
helm uninstall monitoring -n monitoring 2>/dev/null || true
helm uninstall harbor -n harbor 2>/dev/null || true

echo "[teardown] Removing Bookinfo..."
kubectl delete -f https://raw.githubusercontent.com/istio/istio/release-1.23/samples/bookinfo/platform/kube/bookinfo.yaml --ignore-not-found 2>/dev/null || true
kubectl delete -f "$ROOT_DIR/manifests/bookinfo/gateway.yaml" --ignore-not-found 2>/dev/null || true
kubectl delete -f "$ROOT_DIR/manifests/bookinfo/gateway-port80.yaml" --ignore-not-found 2>/dev/null || true
kubectl delete -f "$ROOT_DIR/manifests/bookinfo/destination-rules.yaml" --ignore-not-found 2>/dev/null || true

echo "[teardown] Uninstalling Istio..."
if command -v istioctl >/dev/null 2>&1; then
  istioctl uninstall --purge -y || true
fi

echo "[teardown] Uninstalling k3s..."
if command -v k3s-uninstall.sh >/dev/null 2>&1; then
  sudo k3s-uninstall.sh || true
fi

echo "[teardown] Done."
