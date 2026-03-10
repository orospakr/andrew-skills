---
name: obsidian-daily-note-finder
description: Find the current daily note in Andrew's Obsidian vault at ~/Obsidian/Andrew, including the exact note path to open. Use when the user asks to identify today's daily note, refers to a "daily note" or "deck", or wants the most recent daily markdown note in that vault.
---

# Obsidian Daily Note Finder

Use the helper script first for deterministic output.

## Workflow

1. Run:
   `scripts/find_daily_note.sh`
2. Treat the returned path as the active daily note.
3. If today's file exists, the script returns it.
4. If today's file does not exist, report it as missing and include the expected absolute path.
5. Never select a different date as a fallback.

## Paths

- Default vault: `~/Obsidian/Andrew`
- Default daily directory: `~/Obsidian/Andrew/daily`
- Override vault path by setting `OBSIDIAN_VAULT`.
- Override daily directory by setting `OBSIDIAN_DAILY_DIR`.

## Script

- `scripts/find_daily_note.sh`
  - Prints one absolute file path on success.
  - Exits non-zero with an error message if no daily note is found.
