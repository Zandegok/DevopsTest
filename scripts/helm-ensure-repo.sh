#!/usr/bin/env bash
# Usage: helm-ensure-repo.sh <name> <url> [chart-path-if-url-fails]
set -euo pipefail

name="${1:?repo name required}"
url="${2:?repo url required}"
fallback_chart="${3:-}"

add_once() {
  helm repo add "$name" "$url" 2>&1
}

for attempt in 1 2 3 4 5 6; do
  if out=$(add_once); then
    echo "$out"
    if helm repo update "$name" 2>&1; then
      exit 0
    fi
  else
    echo "$out"
    if echo "$out" | grep -qi 'already exists'; then
      helm repo add "$name" "$url" --force-update || true
      if helm repo update "$name" 2>&1; then
        exit 0
      fi
    fi
  fi
  sleep $((attempt * 5))
done

if [[ -n "$fallback_chart" && -f "$fallback_chart/Chart.yaml" ]]; then
  echo "[helm] repo unreachable, using local chart: $fallback_chart"
  exit 0
fi

echo "[helm] FAILED: cannot add/update repo $name ($url)" >&2
exit 1
