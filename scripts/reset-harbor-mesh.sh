#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/assert.sh
source "$ROOT_DIR/scripts/lib/assert.sh"
# shellcheck source=chaos/lib/harbor-mesh.sh
source "$ROOT_DIR/chaos/lib/harbor-mesh.sh"

harbor_mesh_emergency_reset
