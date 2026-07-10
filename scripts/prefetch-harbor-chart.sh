#!/usr/bin/env bash
# Fetch Harbor Helm chart when helm.goharbor.io is unreachable.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_VERSION="${HARBOR_CHART_VERSION:-v1.16.0}"
DEST="${HARBOR_CHART_DIR:-/tmp/harbor-helm}"

if [[ -f "$DEST/Chart.yaml" ]]; then
  echo "Harbor chart already at $DEST"
  exit 0
fi

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"

clone_repo() {
  git clone --depth 1 --branch "$CHART_VERSION" "$1" "$DEST"
}

for url in \
  "https://github.com/goharbor/harbor-helm" \
  "https://mirror.ghproxy.com/https://github.com/goharbor/harbor-helm"; do
  echo "[harbor-chart] trying git clone $url"
  if clone_repo "$url" 2>/dev/null; then
    echo "[harbor-chart] OK -> $DEST"
    exit 0
  fi
  rm -rf "$DEST"
done

TARBALL="/tmp/harbor-helm.tgz"
"$ROOT_DIR/scripts/fetch-with-retry.sh" "$TARBALL" \
  "https://github.com/goharbor/harbor-helm/archive/refs/tags/${CHART_VERSION}.tar.gz" \
  "https://mirror.ghproxy.com/https://github.com/goharbor/harbor-helm/archive/refs/tags/${CHART_VERSION}.tar.gz"

rm -rf "$DEST"
tar -xzf "$TARBALL" -C /tmp
mv "/tmp/harbor-helm-${CHART_VERSION#v}" "$DEST"
echo "[harbor-chart] OK from tarball -> $DEST"
