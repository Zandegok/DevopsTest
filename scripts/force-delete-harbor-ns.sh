#!/usr/bin/env bash
# Unblock harbor namespace stuck in Terminating (PVC/finalizer leftovers).
set -euo pipefail

NS=harbor

if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
  echo "[force-delete-harbor-ns] namespace $NS already gone"
  exit 0
fi

phase=$(kubectl get namespace "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
if [[ "$phase" != "Terminating" ]]; then
  echo "[force-delete-harbor-ns] namespace phase=$phase (not Terminating); deleting normally"
  kubectl delete namespace "$NS" --timeout=60s 2>/dev/null || true
  if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
    echo "[force-delete-harbor-ns] OK — namespace $NS removed"
    exit 0
  fi
  echo "[force-delete-harbor-ns] namespace still present after normal delete; forcing finalizers"
fi

echo "[force-delete-harbor-ns] clearing finalizers on PVCs in $NS"
for pvc in $(kubectl get pvc -n "$NS" -o name 2>/dev/null || true); do
  kubectl patch -n "$NS" "$pvc" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
done

echo "[force-delete-harbor-ns] clearing finalizers on remaining namespaced objects"
for kind in $(kubectl api-resources --verbs=list --namespaced -o name 2>/dev/null); do
  for obj in $(kubectl get "$kind" -n "$NS" -o name 2>/dev/null || true); do
    kubectl patch -n "$NS" "$obj" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
  done
done

echo "[force-delete-harbor-ns] finalizing namespace $NS"
kubectl get namespace "$NS" -o json \
  | sed 's/"kubernetes"//g' \
  | kubectl replace --raw "/api/v1/namespaces/${NS}/finalize" -f - >/dev/null 2>&1 \
  || kubectl patch namespace "$NS" -p '{"spec":{"finalizers":[]}}' --type=merge

for i in $(seq 1 30); do
  if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
    echo "[force-delete-harbor-ns] OK — namespace $NS removed"
    exit 0
  fi
  sleep 2
done

echo "[force-delete-harbor-ns] namespace still present; check: kubectl get ns $NS -o yaml"
exit 1
