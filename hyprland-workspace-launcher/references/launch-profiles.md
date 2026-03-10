# Launch Profiles

Define reusable launch profiles here so terminal/app/agent launches share one pattern.

## Profile format

- `name`: Stable profile id.
- `workspace`: Default workspace number.
- `command`: Raw launch command (without `exec [workspace N]`).
- `verify_hint`: Optional class/title hint used after launch.

## Suggested starter profiles

- `terminal-default`
  - `workspace`: `2`
  - `command`: `uwsm app -- xdg-terminal-exec --dir="$(omarchy-cmd-terminal-cwd)"`
  - `verify_hint`: `class=Alacritty`
- `codex-agent`
  - `workspace`: `3`
  - `command`: `uwsm app -- xdg-terminal-exec --dir="$HOME"`
  - `verify_hint`: `class=Alacritty`

## Expansion pattern

When adding a new tool launcher:

1. Add profile entry.
2. Build dispatch string with `scripts/build_workspace_exec.py`.
3. Dispatch through MCP.
4. Verify matching window appears on target workspace.
