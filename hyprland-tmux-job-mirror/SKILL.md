---
name: hyprland-tmux-job-mirror
description: Run long-running commands inside tmux and mirror output to both Codex and a visible terminal on the current Hyprland workspace. Use for big builds, long test suites, servers, polling scripts, and batch jobs where the user should watch/interact in a side-by-side terminal while Codex continues monitoring. Do not use for short, routine command execution where normal exec tooling is simpler.
---

# Hyprland Tmux Job Mirror

## Use Criteria

Use this skill when at least one is true:

- Job is expected to run longer than about 30-60 seconds.
- User explicitly wants a visible terminal monitor alongside Codex.
- Job is interactive or may need `Ctrl-C` from either user terminal or agent.

Do not use this skill for quick one-off commands, short file checks, or small scripts. Use normal command execution for those.

## Core Workflow

1. Capture active workspace via Hyprland MCP (`activeworkspace`).
2. Create job paths:
   - `JOB_ID` (timestamp slug)
   - `SESSION=codex-$JOB_ID`
   - `LOG=/tmp/codex-jobs/$JOB_ID.log`
   - `STATUS=/tmp/codex-jobs/$JOB_ID.status`
3. Create a command script file for the target job (preferred for quoting reliability).
4. Start tmux session with `scripts/tmux_job_wrapper.sh`.
5. Launch attached terminal on current workspace:
   - `exec [workspace N] alacritty -e tmux attach -t $SESSION`
6. Mirror to Codex by tailing `LOG`.
7. For interrupts:
   - Agent: `tmux send-keys -t <pane_id> C-c`
   - User: press `Ctrl-C` in attached terminal
8. Verify completion with `STATUS` and session existence.

## Required Commands

Create wrapper once:

```bash
chmod +x scripts/tmux_job_wrapper.sh
```

Start session:

```bash
mkdir -p /tmp/codex-jobs
JOB_ID="job-$(date +%s)"
SESSION="codex-$JOB_ID"
LOG="/tmp/codex-jobs/$JOB_ID.log"
STATUS="/tmp/codex-jobs/$JOB_ID.status"

cat > /tmp/codex-job-cmd-$JOB_ID.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Replace with the real long-running command:
exec bash -lc 'echo starting; sleep 9999'
EOF
chmod +x /tmp/codex-job-cmd-$JOB_ID.sh

tmux new-session -d -s "$SESSION" \
  "$(pwd)/scripts/tmux_job_wrapper.sh '$LOG' '$STATUS' /tmp/codex-job-cmd-$JOB_ID.sh"
PANE_ID="$(tmux list-panes -t "$SESSION" -F '#{pane_id}' | head -n1)"
```

Launch visible monitor terminal on active workspace `N`:

```text
exec [workspace N] alacritty -e tmux attach -t <SESSION>
```

Mirror for Codex:

```bash
tail -n +1 -F "$LOG"
```

Interrupt and cleanup:

```bash
# Graceful interrupt:
tmux send-keys -t "$PANE_ID" C-c

# Hard stop fallback:
tmux kill-session -t "$SESSION"
```

## Validation Checklist

- New Alacritty window appears on target workspace.
- `tail -F "$LOG"` advances while job runs.
- `tmux send-keys ... C-c` exits the session.
- `STATUS` contains `130` on interrupt or the command exit code otherwise.

## Notes

- Use pane IDs (`%N`) rather than `:0.0`; tmux base index may not be 0.
- Do not combine `tee` and `tmux pipe-pane` into the same log file.
- See `references/command-patterns.md` for compact runbooks.
