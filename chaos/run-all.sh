#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

FAIL=0
PASSED=0
TOTAL=0

for script in chaos/0*.sh; do
  [[ -f "$script" ]] || continue
  TOTAL=$((TOTAL + 1))
  echo ""
  echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
  echo "Running $script"
  echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
  if bash "$script"; then
    PASSED=$((PASSED + 1))
  else
    FAIL=1
    echo "[FAIL] $script"
  fi
done

echo ""
echo "=== CHAOS SUMMARY ==="
echo "Passed: $PASSED / $TOTAL"
if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL CHAOS EXPERIMENTS PASSED"
  exit 0
fi
echo "SOME CHAOS EXPERIMENTS FAILED"
exit 1
