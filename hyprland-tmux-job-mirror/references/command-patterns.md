# Command Patterns

## Build/Test Job

```bash
cat > /tmp/codex-job-cmd-$JOB_ID.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec bash -lc 'make -j$(nproc)'
EOF
chmod +x /tmp/codex-job-cmd-$JOB_ID.sh
```

## Server Job

```bash
cat > /tmp/codex-job-cmd-$JOB_ID.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec bash -lc 'npm run dev'
EOF
chmod +x /tmp/codex-job-cmd-$JOB_ID.sh
```

## Polling Job

```bash
cat > /tmp/codex-job-cmd-$JOB_ID.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec bash -lc 'while true; do ./scripts/poll_once.sh; sleep 30; done'
EOF
chmod +x /tmp/codex-job-cmd-$JOB_ID.sh
```

## Session State Checks

```bash
tmux has-session -t "$SESSION" 2>/dev/null && echo running || echo exited
test -f "$STATUS" && cat "$STATUS"
tail -n 50 "$LOG"
```

## Reattach

```bash
tmux attach -t "$SESSION"
```
