#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "usage: $0 <log_path> <status_path> <command> [args...]" >&2
  exit 2
fi

LOG="$1"
STATUS="$2"
shift 2

on_int() {
  echo 130 > "$STATUS"
  exit 130
}

trap on_int INT TERM
set -o pipefail

# Preserve status capture even for non-zero command exits.
set +e
"$@" 2>&1 | tee -a "$LOG"
ec=${PIPESTATUS[0]}
set -e

echo "$ec" > "$STATUS"
exit "$ec"
