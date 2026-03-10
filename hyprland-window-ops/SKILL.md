---
name: hyprland-window-ops
description: Operate Hyprland windows and workspaces reliably through MCP. Use when the user asks to enumerate windows, move windows by class/title/workspace, retile or regroup windows, or verify final window placement after dispatch commands.
---

# Hyprland Window Ops

Use this workflow for deterministic Hyprland MCP window operations.

## Core Workflow

1. Query clients with `mcp__hyprland__clients`.
2. Parse the output into records with `address`, `class`, `title`, `workspace`, `floating`, and `pinned`.
3. Select target windows using exact `class` match first, then title substring when needed.
4. Normalize window addresses before dispatch:
   - If address is like `55eb04ad0600`, convert to `0x55eb04ad0600`.
   - Use selector form `address:0x...` in dispatch args.
5. Dispatch operations (`movetoworkspacesilent`, `focuswindow`, `pin`, etc.).
6. Re-run `mcp__hyprland__clients` and verify postconditions.
7. Report final state with exact counts and affected windows.

## Known MCP Friction + Mitigations

- Raw-text client payloads are brittle to parse.
  - Mitigate by using `scripts/parse_hypr_clients.py` for deterministic parsing.
- Window selector formatting is easy to get wrong.
  - Always normalize to `address:0x...`.
- Dispatch failures are low-context (`Window not found`).
  - Retry once after address normalization, then re-enumerate and re-resolve targets.
- State can change during operations.
  - Re-enumerate immediately before mutation and again after mutation.

## Selection Rules

- Prefer class-based targeting for bulk operations.
- Exclude non-target utility windows unless user requests them (e.g., PiP with empty class).
- If multiple windows share same title/class, identify each by address.

## Safety Rules

- Never assume previous addresses are still valid after time has passed.
- For bulk moves, enumerate targets first and echo planned commands before dispatch when risk is non-trivial.
- Always verify and report `already compliant` vs `changed` windows.

## Script Helpers

- `scripts/parse_hypr_clients.py`
  - Parse raw `mcp__hyprland__clients` text to JSON.
- `scripts/plan_move_by_class.py`
  - Build `movetoworkspacesilent` dispatch args for windows matching a class.
  - Supports `--execute` to call `mcp__hyprland__dispatch` via `hyprctl dispatch` fallback when available.

## Quick Commands

Parse client text copied to a file:

```bash
python3 scripts/parse_hypr_clients.py --input /tmp/clients.txt
```

Generate move commands for all Alacritty windows to workspace 3:

```bash
python3 scripts/plan_move_by_class.py --input /tmp/clients.txt --class Alacritty --workspace 3
```

Output commands can be run as MCP dispatch args:

```text
movetoworkspacesilent 3,address:0x55eb04ad0600
```

## Environment Note

Codex may run with a stripped environment; use the MCP server wrapper at `/home/andrew/.local/bin/hyprland-mcp-codex` to ensure Hyprland socket/env setup is applied.
