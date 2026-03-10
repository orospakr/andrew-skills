#!/usr/bin/env bash
set -euo pipefail

vault_dir="${OBSIDIAN_VAULT:-$HOME/Obsidian/Andrew}"
daily_dir="${OBSIDIAN_DAILY_DIR:-$vault_dir/daily}"
today="$(date +%F)"
today_file="$daily_dir/$today.md"

if [[ -f "$today_file" ]]; then
  realpath "$today_file"
  exit 0
fi

echo "Today's daily note does not exist yet: $today_file" >&2
exit 1
