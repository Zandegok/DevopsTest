#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

chmod +x setup.sh verify.sh teardown.sh scripts/*.sh scripts/lib/*.sh chaos/*.sh chaos/lib/*.sh 2>/dev/null || true

log() { echo "[setup] $*"; }

if [[ "$(id -u)" -eq 0 ]]; then
  echo "Run as a sudo-capable user, not root." >&2
  exit 1
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
  log "Installing Ansible and dependencies..."
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    ansible curl ca-certificates jq
fi

for bin in curl kubectl helm; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    log "Note: $bin will be installed by Ansible roles"
  fi
done

log "Running Ansible playbook..."
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
