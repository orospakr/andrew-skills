#!/usr/bin/env bash
# env.sh -- shared configuration and helpers for the headless Wayland E2E
# harness.  This file is *sourced*, never executed:
#
#     source "$(dirname -- "${BASH_SOURCE[0]}")/env.sh"
#
# Callers are expected to have already run `set -euo pipefail`.
#
# Nothing here is application-specific: point E2E_APP_CMD / E2E_APP_ID at
# whatever you want to drive.
#
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Locations (derived from this file, so every script works from any cwd)
# ---------------------------------------------------------------------------

E2E_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Knobs (all overridable from the environment)
# ---------------------------------------------------------------------------

# Stable name for the E2E compositor's Wayland socket.  sway itself picks
# wayland-1..wayland-32 and ignores $WAYLAND_DISPLAY, so compositor.sh symlinks
# this name onto whatever sway actually chose.  Everything else in the harness
# only ever talks about this name.
E2E_WAYLAND_DISPLAY="${E2E_WAYLAND_DISPLAY:-wayland-e2e}"

# The single headless output created by the wlroots headless backend.
E2E_OUTPUT="${E2E_OUTPUT:-HEADLESS-1}"
E2E_WIDTH="${E2E_WIDTH:-1280}"
E2E_HEIGHT="${E2E_HEIGHT:-800}"

# xdg-shell app_id of the window under test.  Empty means "any window": app.sh
# then waits for the first window to appear, and every window is fullscreened.
E2E_APP_ID="${E2E_APP_ID:-}"

# sway's default seat.
E2E_SEAT="${E2E_SEAT:-seat0}"

# The command app.sh launches.  Either set this (a shell command line, run
# through `bash -c`) or pass the command after `--`:
#
#     E2E_APP_CMD='myapp --flag' app.sh start
#     app.sh start -- myapp --flag
E2E_APP_CMD="${E2E_APP_CMD:-}"

# Working directory for that command (default: wherever app.sh was invoked).
E2E_APP_CWD="${E2E_APP_CWD:-$PWD}"

# Optional TCP port singleton guard: when set, `app.sh start` refuses to run if
# something already listens on it, and `app.sh stop` waits for it to clear.
# Useful for dev servers with strictPort-style behaviour.  Unset = no guard.
E2E_APP_PORT="${E2E_APP_PORT:-}"

# Extra environment variable names to forward into the app, on top of the
# built-in list (see app.sh).  Space separated.
E2E_APP_ENV_PASS="${E2E_APP_ENV_PASS:-}"

# How long to wait for the app to put a window on screen.  A cold build of a
# compiled app can take minutes.
E2E_APP_TIMEOUT="${E2E_APP_TIMEOUT:-120}"
E2E_COMPOSITOR_TIMEOUT="${E2E_COMPOSITOR_TIMEOUT:-10}"

# VNC listen address/port used by `compositor.sh start --vnc`.
E2E_VNC_HOST="${E2E_VNC_HOST:-localhost}"
E2E_VNC_PORT="${E2E_VNC_PORT:-5910}"

# Pidfiles, logs, the rendered sway config and recorded socket paths live here.
E2E_RUNTIME_DIR="${E2E_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/headless-e2e}"
mkdir -p -- "$E2E_RUNTIME_DIR"

# Wayland/sway sockets live in the user runtime dir, not in E2E_RUNTIME_DIR.
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export XDG_RUNTIME_DIR

# sway configs cannot expand environment variables, so the shipped config is a
# template with @OUTPUT@/@WIDTH@/@HEIGHT@/@APP_ID@ placeholders that
# compositor.sh renders into E2E_RUNTIME_DIR.  Set E2E_SWAY_CONFIG to a file of
# your own to bypass templating entirely (it is then used verbatim).
E2E_SWAY_CONFIG_TEMPLATE="${E2E_SWAY_CONFIG_TEMPLATE:-$E2E_DIR/sway-e2e.config}"
E2E_SWAY_CONFIG_RENDERED="$E2E_RUNTIME_DIR/sway.rendered.config"
E2E_SWAY_CONFIG="${E2E_SWAY_CONFIG:-}"

E2E_SWAY_PIDFILE="$E2E_RUNTIME_DIR/sway.pid"
E2E_SWAY_SOCKFILE="$E2E_RUNTIME_DIR/sway.sock.path"
E2E_SWAY_DISPLAYFILE="$E2E_RUNTIME_DIR/sway.wayland-display"
E2E_SWAY_LOG="$E2E_RUNTIME_DIR/sway.log"

E2E_VNC_PIDFILE="$E2E_RUNTIME_DIR/wayvnc.pid"
E2E_VNC_LOG="$E2E_RUNTIME_DIR/wayvnc.log"

# The idle RFB client that keeps wayvnc's virtual pointer/keyboard registered on
# the seat (see vnc-hold.py -- wayvnc only creates them per connected client).
E2E_VNC_HOLD="${E2E_VNC_HOLD:-$E2E_DIR/vnc-hold.py}"
E2E_VNC_HOLD_PIDFILE="$E2E_RUNTIME_DIR/vnc-hold.pid"
E2E_VNC_HOLD_LOG="$E2E_RUNTIME_DIR/vnc-hold.log"

# Wheel events and drags also go through wayvnc's virtual pointer, because sway
# IPC cannot produce either: `cursor press button4/5` maps to the SWAY_SCROLL_*
# pseudo-buttons that only `bindsym` understands, and `cursor set`/`cursor move`
# deliver no motion at all while a button is held (seatop_down has no rebase
# handler).  See vnc-pointer.py.
E2E_VNC_POINTER="${E2E_VNC_POINTER:-$E2E_DIR/vnc-pointer.py}"

E2E_APP_PIDFILE="$E2E_RUNTIME_DIR/app.pid"
E2E_APP_LOG="$E2E_RUNTIME_DIR/app.log"

# ui.sh remembers where it last put the cursor (sway's IPC cannot report it).
E2E_CURSOR_FILE="$E2E_RUNTIME_DIR/cursor.pos"

# ---------------------------------------------------------------------------
# Tiny output helpers
# ---------------------------------------------------------------------------

e2e_say() { printf 'e2e: %s\n' "$*" >&2; }
e2e_warn() { printf 'e2e: warning: %s\n' "$*" >&2; }
e2e_die() { printf 'e2e: error: %s\n' "$*" >&2; exit 1; }

# e2e_need CMD...  -- die unless every command exists.
e2e_need() {
	local missing=() cmd
	for cmd in "$@"; do
		command -v -- "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
	done
	if ((${#missing[@]})); then
		e2e_die "missing required command(s): ${missing[*]}"
	fi
}

# e2e_tail FILE [N] -- print the last N lines of a log, if it exists.
e2e_tail() {
	local file="$1" n="${2:-30}"
	if [[ -f $file ]]; then
		printf -- '--- last %s lines of %s ---\n' "$n" "$file" >&2
		tail -n "$n" -- "$file" >&2 || true
		printf -- '--- end of %s ---\n' "$file" >&2
	else
		printf 'e2e: (no log at %s)\n' "$file" >&2
	fi
}

# ---------------------------------------------------------------------------
# Process helpers
# ---------------------------------------------------------------------------

# e2e_read_pid PIDFILE -- echo the pid if the file holds a live pid, else fail.
e2e_read_pid() {
	local pidfile="$1" pid
	[[ -s $pidfile ]] || return 1
	pid="$(<"$pidfile")"
	[[ $pid =~ ^[0-9]+$ ]] || return 1
	kill -0 "$pid" 2>/dev/null || return 1
	printf '%s\n' "$pid"
}

# e2e_spawn PIDFILE LOGFILE CMD...
#
# Start CMD detached in its own session/process group, append its output to
# LOGFILE, and write the *final* pid to PIDFILE.  Because the helper shell
# `exec`s the command, the recorded pid is the command itself and -- since
# setsid --fork makes it a process group leader -- it doubles as the process
# group id, so `kill -TERM -$pid` reaps the whole tree (needed for launchers
# that spawn children of their own, e.g. a dev server plus a compiler plus the
# app binary).
e2e_spawn() {
	local pidfile="$1" logfile="$2"
	shift 2
	: >"$pidfile"
	setsid --fork bash -c 'echo "$$" >"$1"; shift; exec "$@"' \
		e2e-spawn "$pidfile" "$@" >>"$logfile" 2>&1 </dev/null
}

# e2e_wait_pidfile PIDFILE [SECONDS] -- wait for e2e_spawn to record a live pid.
e2e_wait_pidfile() {
	local pidfile="$1" timeout="${2:-5}" pid i
	for ((i = 0; i < timeout * 10; i++)); do
		if pid="$(e2e_read_pid "$pidfile")"; then
			printf '%s\n' "$pid"
			return 0
		fi
		sleep 0.1
	done
	return 1
}

# e2e_kill_group PIDFILE LABEL [GRACE_SECONDS]
e2e_kill_group() {
	local pidfile="$1" label="$2" grace="${3:-15}" pid i
	if ! pid="$(e2e_read_pid "$pidfile")"; then
		rm -f -- "$pidfile"
		return 1
	fi
	e2e_say "stopping $label (pid $pid)"
	kill -TERM -- "-$pid" 2>/dev/null || kill -TERM -- "$pid" 2>/dev/null || true
	for ((i = 0; i < grace * 10; i++)); do
		kill -0 "$pid" 2>/dev/null || break
		sleep 0.1
	done
	if kill -0 "$pid" 2>/dev/null; then
		e2e_warn "$label did not exit on TERM; sending KILL"
		kill -KILL -- "-$pid" 2>/dev/null || kill -KILL -- "$pid" 2>/dev/null || true
		sleep 0.3
	fi
	rm -f -- "$pidfile"
	return 0
}

# ---------------------------------------------------------------------------
# sway IPC
# ---------------------------------------------------------------------------

# The sway IPC socket path is recorded by compositor.sh at start.  sway derives
# it as "$XDG_RUNTIME_DIR/sway-ipc.<uid>.<pid>.sock" (sway/ipc-server.c), so it
# is fully determined by the compositor pid.
e2e_expected_swaysock() {
	printf '%s/sway-ipc.%s.%s.sock\n' "$XDG_RUNTIME_DIR" "$(id -u)" "$1"
}

# Quiet on failure: callers (e2e_require_compositor, compositor.sh status)
# produce the human-facing message.
e2e_swaysock() {
	[[ -s $E2E_SWAY_SOCKFILE ]] || return 1
	local sock
	sock="$(<"$E2E_SWAY_SOCKFILE")"
	[[ -S $sock ]] || return 1
	printf '%s\n' "$sock"
}

# swaymsg_e2e ARGS... -- run swaymsg against the E2E compositor only.
swaymsg_e2e() {
	local sock
	sock="$(e2e_swaysock)" || return 1
	SWAYSOCK="$sock" swaymsg "$@"
}

e2e_compositor_up() {
	swaymsg_e2e -t get_version >/dev/null 2>&1
}

e2e_require_compositor() {
	e2e_compositor_up ||
		e2e_die "E2E compositor is not running -- start it with: $E2E_DIR/compositor.sh start --vnc"
}

# ---------------------------------------------------------------------------
# Running Wayland clients inside the E2E session
# ---------------------------------------------------------------------------

# e2e_wl CMD... -- run CMD against the E2E compositor: correct WAYLAND_DISPLAY,
# no DISPLAY (so nothing can fall back to X11 on the real desktop), and SWAYSOCK
# pointed at the E2E instance.
e2e_wl() {
	local sock
	sock="$(e2e_swaysock)" || return 1
	env -u DISPLAY \
		WAYLAND_DISPLAY="$E2E_WAYLAND_DISPLAY" \
		XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
		SWAYSOCK="$sock" \
		"$@"
}

# ---------------------------------------------------------------------------
# Tree / window inspection
# ---------------------------------------------------------------------------

# e2e_windows [APP_ID] -- TSV of visible views: app_id, name, x, y, width,
# height.  With no APP_ID (or "*"), every view is listed.
e2e_windows() {
	local want="${1-}"
	if [[ $want == '*' ]]; then want=''; fi
	swaymsg_e2e -t get_tree -r 2>/dev/null | E2E_WANT="$want" python3 -c '
import json, os, sys

want = os.environ.get("E2E_WANT", "")
rows = []


def walk(node):
    props = node.get("window_properties") or {}
    ident = node.get("app_id")
    if ident is None:
        ident = props.get("class")
    if ident is not None and (not want or ident == want):
        rect = node.get("rect") or {}
        rows.append((
            ident,
            node.get("name") or "",
            rect.get("x", 0), rect.get("y", 0),
            rect.get("width", 0), rect.get("height", 0),
        ))
    for key in ("nodes", "floating_nodes"):
        for child in node.get(key) or []:
            walk(child)


walk(json.load(sys.stdin))
for row in rows:
    print("\t".join(str(col) for col in row))
'
}

# e2e_app_window_present -- true once a window matching E2E_APP_ID exists.  With
# E2E_APP_ID empty, any window counts.
e2e_app_window_present() {
	local out
	out="$(e2e_windows "${E2E_APP_ID:-*}" 2>/dev/null || true)"
	[[ -n $out ]]
}

# e2e_seat_capabilities -- human summary of the seat's wl_seat capability
# bitmask.  1 = pointer, 2 = keyboard, 4 = touch (wl_seat.capability).
e2e_seat_capabilities() {
	swaymsg_e2e -t get_seats -r 2>/dev/null | E2E_SEAT="$E2E_SEAT" python3 -c '
import json, os, sys

seat_name = os.environ.get("E2E_SEAT", "seat0")
for seat in json.load(sys.stdin):
    if seat.get("name") != seat_name:
        continue
    caps = seat.get("capabilities", 0)
    names = [n for bit, n in ((1, "pointer"), (2, "keyboard"), (4, "touch")) if caps & bit]
    print("%s: capabilities=%d [%s] devices=%d" % (
        seat_name, caps, ",".join(names) or "none", len(seat.get("devices") or [])))
    break
else:
    print("%s: not present" % seat_name)
'
}

# e2e_seat_has_pointer -- true when the seat advertises wl_seat pointer
# capability.  Without it, `ui.sh click`/`warp` move sway's own cursor but no
# wl_pointer event ever reaches the client, so the app sees nothing.
e2e_seat_has_pointer() {
	local caps
	caps="$(swaymsg_e2e -t get_seats -r 2>/dev/null)" || return 1
	E2E_SEAT="$E2E_SEAT" python3 -c '
import json, os, sys

seat_name = os.environ.get("E2E_SEAT", "seat0")
for seat in json.load(sys.stdin):
    if seat.get("name") == seat_name and seat.get("capabilities", 0) & 1:
        sys.exit(0)
sys.exit(1)
' <<<"$caps"
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------

# e2e_port_in_use PORT -- true if anything is listening on TCP PORT locally.
e2e_port_in_use() {
	local port="$1"
	if command -v ss >/dev/null 2>&1; then
		[[ -n "$(ss -H -ltn "sport = :$port" 2>/dev/null)" ]]
	else
		(exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null
	fi
}

# e2e_port_owner PORT -- best-effort description of who holds the port.
e2e_port_owner() {
	local port="$1"
	if command -v ss >/dev/null 2>&1; then
		ss -H -ltnp "sport = :$port" 2>/dev/null | tr -s ' ' || true
	fi
}
