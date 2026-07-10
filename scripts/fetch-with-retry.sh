#!/usr/bin/env bash
# Usage: fetch-with-retry.sh <output-file> <url> [more-urls...]
set -euo pipefail

dest="${1:?destination required}"
shift

if [[ $# -eq 0 ]]; then
  echo "At least one URL required" >&2
  exit 1
fi

if [[ -s "$dest" ]]; then
  exit 0
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
part="$tmpdir/part"

for url in "$@"; do
  for attempt in 1 2 3 4 5 6; do
    echo "[fetch] $url (attempt $attempt/6)"
    if curl -fSL \
      --connect-timeout 60 \
      --max-time 900 \
      --retry 2 \
      --retry-delay 5 \
      --retry-all-errors \
      -o "$part" \
      "$url" && [[ -s "$part" ]]; then
      mv "$part" "$dest"
      echo "[fetch] OK -> $dest"
      exit 0
    fi
    rm -f "$part"
    sleep $((attempt * 5))
  done
done

echo "[fetch] FAILED all URLs for $dest" >&2
exit 1
