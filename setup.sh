#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

chmod +x setup.sh verify.sh teardown.sh scripts/*.sh scripts/lib/*.sh chaos/*.sh chaos/lib/*.sh 2>/dev/null || true

log() { echo "[setup $(date +%H:%M:%S)] $*"; }

if [[ -z "${SKIP_MONITORING:-}" ]]; then
  mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
  if [[ "$mem_mb" -gt 0 && "$mem_mb" -lt 7000 ]]; then
    export SKIP_MONITORING=1
    log "RAM ${mem_mb}MB — auto SKIP_MONITORING=1 (Grafana skipped below 7 GB)"
  fi
fi

if [[ "$(id -u)" -eq 0 ]]; then
  log "Running as root (supported)"
  APT="apt-get"
else
  APT="sudo apt-get"
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
  log "Installing Ansible and dependencies..."
  $APT update -qq
  DEBIAN_FRONTEND=noninteractive $APT install -y -qq \
    ansible curl ca-certificates jq
fi

for bin in curl kubectl helm; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    log "Note: $bin will be installed by Ansible roles"
  fi
done

log "Running Ansible playbook (each TASK line = progress; Harbor prints [harbor-install] steps)..."
export ANSIBLE_FORCE_COLOR=1
ansible-playbook ansible/site.yml

log "Waiting for workloads..."
"$ROOT_DIR/scripts/wait-ready.sh"

log "Running verification..."
if ! "$ROOT_DIR/verify.sh"; then
  log "Setup completed but verification failed. Check output above."
  exit 1
fi

log "Setup complete."
"$ROOT_DIR/scripts/print-access.sh"
