#!/usr/bin/env bash
# Usage: helm-ensure-repo.sh <name> <url>
set -euo pipefail

name="${1:?repo name required}"
url="${2:?repo url required}"

add_once() {
  helm repo add "$name" "$url" 2>&1
}

for attempt in 1 2 3 4 5 6; do
  if out=$(add_once); then
    echo "$out"
    break
  fi
  echo "$out"
  if echo "$out" | grep -qi 'already exists'; then
    helm repo add "$name" "$url" --force-update
    break
  fi
  sleep $((attempt * 5))
done

helm repo list | grep -q "^${name}[[:space:]]"
helm repo update "$name"
