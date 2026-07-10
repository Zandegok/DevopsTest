#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${ISTIO_VERSION:-1.23.2}"
ARCHIVE="/tmp/istio.tar.gz"
DIR="/tmp/istio-${VERSION}"

if [[ -x /usr/local/bin/istioctl ]]; then
  echo "istioctl already installed: $(istioctl version --remote=false 2>/dev/null || true)"
  exit 0
fi

"$ROOT_DIR/scripts/fetch-with-retry.sh" "$ARCHIVE" \
  "https://github.com/istio/istio/releases/download/${VERSION}/istio-${VERSION}-linux-amd64.tar.gz" \
  "https://mirror.ghproxy.com/https://github.com/istio/istio/releases/download/${VERSION}/istio-${VERSION}-linux-amd64.tar.gz"

rm -rf "$DIR"
tar -xzf "$ARCHIVE" -C /tmp
install -m 0755 "${DIR}/bin/istioctl" /usr/local/bin/istioctl
echo "Installed: $(istioctl version --remote=false)"
