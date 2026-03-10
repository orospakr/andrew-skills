---
name: hyprland-workspace-launcher
description: Launch applications on specific Hyprland workspaces through MCP, with reliable command construction and verification. Use when the user asks to open a terminal, agent, browser, or other tool on a target workspace, or to define reusable workspace launch profiles for future agent/tool launch tasks.
---

# Hyprland Workspace Launcher

Use this skill to launch commands onto explicit Hyprland workspaces and verify placement.

## Core Workflow

1. Identify launch intent:
   - Explicit command from user, or
   - Default terminal from binds (`description: Terminal`).
2. Build dispatch command in this form:
   - `exec [workspace N] <command>`
3. Dispatch with `mcp__hyprland__dispatch`.
4. Re-enumerate windows (`mcp__hyprland__clients`) and verify a matching new window is on workspace `N`.
5. Report verification using class/title/workspace.

## Browser Window Workflow (Chromium)

Chromium commonly runs in single-instance mode. When already running, `exec [workspace N] chromium --new-window ...` may open the new window on the currently active workspace instead of `N`.

Use this browser-specific workflow:

1. Capture baseline clients with `mcp__hyprland__clients`.
2. Launch Chromium normally (no separate profile/`--user-data-dir`):
   - `exec chromium --new-window about:blank`
3. Capture clients again and diff Chromium windows to find the newly created client.
4. Move that exact window to the target workspace:
   - `movetoworkspacesilent N,address:0x<window_address>`
5. Re-enumerate clients and verify class/title/workspace.

Disambiguation guidance:

- Compare Chromium `address` values before/after launch; `after - before` is the new window.
- Include the `0x` prefix in the move selector (`address:0x...`), or Hyprland may return `Window not found`.
- If multiple new Chromium windows appear, prefer the newest by `stableID` (or `focusHistoryID`) and move all new candidates when deterministic placement is required.

## Omarchy Terminal Pattern

For Omarchy setups, the default terminal bind command typically resolves to:

```text
uwsm app -- xdg-terminal-exec --dir="$(omarchy-cmd-terminal-cwd)"
```

Launch it on workspace 2:

```text
exec [workspace 2] uwsm app -- xdg-terminal-exec --dir="$(omarchy-cmd-terminal-cwd)"
```

## Future-Proofing For Agents/Tools

Maintain reusable launch profiles in `references/launch-profiles.md`.

- Add a profile name (for example: `terminal-default`, `codex-agent`, `monitoring-tui`).
- Store the launch command and default workspace.
- Resolve profile -> command -> dispatch string at execution time.

This allows extending from terminal launches to agent/tool launches without changing workflow.

## Script Helpers

- `scripts/extract_terminal_bind.py`
  - Parse `hyprland binds` output and return the command for `description: Terminal`.
- `scripts/build_workspace_exec.py`
  - Build the exact Hyprland dispatch arg for workspace-targeted launch.

## Quick Commands

Extract terminal command from saved binds output:

```bash
python3 scripts/extract_terminal_bind.py --input /tmp/hypr_binds.txt
```

Build dispatch arg for workspace 2:

```bash
python3 scripts/build_workspace_exec.py --workspace 2 --cmd 'uwsm app -- xdg-terminal-exec --dir="$(omarchy-cmd-terminal-cwd)"'
```

## Environment Note

Codex may run with a stripped environment; use the MCP server wrapper at `/home/andrew/.local/bin/hyprland-mcp-codex` so Hyprland socket/env variables are set correctly.
