#!/usr/bin/env bash
# Safe git pull on VPS when local edits block merge (sync-ports.sh, prefetch-istio.sh, etc.)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

log() { echo "[update-repo $(date +%H:%M:%S)] $*"; }

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log "Not a git repository: $ROOT_DIR"
  exit 1
fi

log "Discarding local edits to tracked scripts (VPS should use repo versions)..."
git checkout -- scripts/ ansible/ manifests/ verify.sh setup.sh teardown.sh README.md 2>/dev/null || true

if ! git diff --quiet || [[ -n "$(git status --porcelain)" ]]; then
  log "Stashing any remaining local changes..."
  git stash push -u -m "vps-local-$(date +%Y%m%d-%H%M%S)" || true
fi

log "Pulling latest from origin..."
git pull --rebase origin main

chmod +x setup.sh verify.sh teardown.sh scripts/*.sh scripts/lib/*.sh chaos/*.sh chaos/lib/*.sh 2>/dev/null || true

log "Done. HEAD: $(git log -1 --oneline)"
log "Run: ./scripts/fix-bookinfo-ingress.sh && ./verify.sh"
