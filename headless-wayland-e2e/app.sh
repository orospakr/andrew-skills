#!/usr/bin/env bash
# app.sh -- run an arbitrary Wayland application inside the headless E2E
# compositor and wait until its window actually shows up.
#
# The command is entirely yours: give it as $E2E_APP_CMD (a shell command line)
# or after `--`.  Anything that spawns children -- a dev server plus a compiler
# plus the app binary, say -- is fine: the launch happens under `setsid`, so
# `app.sh stop` can reap the whole process group.
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/env.sh"

usage() {
	cat <<EOF
usage: app.sh start [-- CMD [ARG...]]
       app.sh stop | status

commands:
  start           launch the app on the E2E compositor and wait for its window
                  (timeout ${E2E_APP_TIMEOUT}s).  The command comes from the
                  arguments after \`--\`, or from \$E2E_APP_CMD.
  stop            kill the whole process group${E2E_APP_PORT:+, then wait for port $E2E_APP_PORT}
  status          report pid${E2E_APP_PORT:+, port} and window rect
  -h, --help      this message

environment:
  E2E_APP_CMD                     shell command line to launch (currently ${E2E_APP_CMD:-<unset>})
  E2E_APP_CWD                     working directory (currently $E2E_APP_CWD)
  E2E_APP_ID                      window app_id to wait for (currently ${E2E_APP_ID:-<any window>})
  E2E_APP_TIMEOUT                 seconds to wait for the window (currently $E2E_APP_TIMEOUT)
  E2E_APP_PORT                    optional singleton TCP port guard (currently ${E2E_APP_PORT:-<none>})
  E2E_APP_ENV_PASS                extra env var names to forward (space separated)
  WEBKIT_DISABLE_DMABUF_RENDERER  forwarded if set; try =1 for a blank webview
  WEBKIT_DISABLE_COMPOSITING_MODE forwarded if set; try =1 if that is not enough

examples:
  E2E_APP_ID=foot app.sh start -- foot
  E2E_APP_CMD='cargo run --release' E2E_APP_ID=myapp E2E_APP_CWD=~/src/myapp app.sh start
EOF
}

# Env vars forwarded into the app when they are set in app.sh's own environment.
# The WEBKIT_* ones are the standard escape hatches for WebKitGTK-based apps
# (Tauri, GNOME Web, ...); the rest are generic debugging knobs.
#
# Deliberately NOT in this list: GDK_BACKEND and QT_QPA_PLATFORM.  A desktop
# session commonly exports them with an X11 fallback appended
# ("wayland,x11,*", "wayland;xcb"), and inheriting that would undo the
# Wayland-only pinning below.  Name them in E2E_APP_ENV_PASS to override.
DEFAULT_ENV_PASS='WEBKIT_DISABLE_DMABUF_RENDERER WEBKIT_DISABLE_COMPOSITING_MODE
	WEBKIT_FORCE_SANDBOX GDK_DEBUG GTK_DEBUG G_MESSAGES_DEBUG
	RUST_LOG RUST_BACKTRACE'

cmd_start() {
	local -a app_argv=()
	while (($#)); do
		case "$1" in
		--)
			shift
			app_argv=("$@")
			break
			;;
		-h | --help)
			usage
			return 0
			;;
		*) e2e_die "start: unexpected argument: $1 (put the command after \`--\`)" ;;
		esac
	done

	if ((${#app_argv[@]} == 0)); then
		[[ -n $E2E_APP_CMD ]] ||
			e2e_die "nothing to launch: set E2E_APP_CMD='...' or pass the command after \`--\`"
		app_argv=(bash -c "$E2E_APP_CMD")
	fi

	e2e_need python3 setsid
	e2e_require_compositor

	if e2e_read_pid "$E2E_APP_PIDFILE" >/dev/null; then
		e2e_die "app already started by this harness (pid $(cat "$E2E_APP_PIDFILE")). Use: app.sh stop"
	fi
	if [[ -n $E2E_APP_PORT ]] && e2e_port_in_use "$E2E_APP_PORT"; then
		e2e_say "port $E2E_APP_PORT is already in use:"
		e2e_port_owner "$E2E_APP_PORT" >&2 || true
		e2e_die "E2E_APP_PORT=$E2E_APP_PORT is declared a singleton, so only one instance can run on this machine. Stop the other one (it may be a desktop-session instance, or a stale \`app.sh\` run) and retry."
	fi

	[[ -d $E2E_APP_CWD ]] || e2e_die "E2E_APP_CWD is not a directory: $E2E_APP_CWD"

	# Environment for the app.  No DISPLAY at all: the app is expected to be
	# Wayland-native and Xwayland is disabled in the E2E compositor.
	local -a child_env=(
		env
		-C "$E2E_APP_CWD"
		-u DISPLAY
		-u SWAYSOCK
		WAYLAND_DISPLAY="$E2E_WAYLAND_DISPLAY"
		XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR"
		GDK_BACKEND=wayland
		QT_QPA_PLATFORM=wayland
		SDL_VIDEODRIVER=wayland
	)
	local var
	for var in $DEFAULT_ENV_PASS $E2E_APP_ENV_PASS; do
		if [[ -n ${!var:-} ]]; then
			child_env+=("$var=${!var}")
			e2e_say "passing through $var=${!var}"
		fi
	done

	: >"$E2E_APP_LOG"
	e2e_say "starting: ${app_argv[*]} (cwd $E2E_APP_CWD, log $E2E_APP_LOG)"
	e2e_spawn "$E2E_APP_PIDFILE" "$E2E_APP_LOG" \
		"${child_env[@]}" "${app_argv[@]}"

	local pid
	if ! pid="$(e2e_wait_pidfile "$E2E_APP_PIDFILE" 5)"; then
		e2e_tail "$E2E_APP_LOG" 30
		e2e_die "the app command did not start"
	fi
	e2e_say "process group $pid started; waiting up to ${E2E_APP_TIMEOUT}s for a window matching app_id=\"${E2E_APP_ID:-<any>}\""

	local waited=0
	while ((waited < E2E_APP_TIMEOUT)); do
		if ! kill -0 "$pid" 2>/dev/null; then
			e2e_tail "$E2E_APP_LOG" 30
			e2e_die "the app exited before a window appeared"
		fi
		if e2e_app_window_present; then
			e2e_say "window is up after ~${waited}s:"
			print_windows
			return 0
		fi
		sleep 2
		waited=$((waited + 2))
	done

	e2e_warn "timed out after ${E2E_APP_TIMEOUT}s waiting for app_id=\"${E2E_APP_ID:-<any>}\""
	e2e_say "windows currently on the E2E compositor (set E2E_APP_ID to one of these app_ids):"
	e2e_windows '*' >&2 || true
	e2e_tail "$E2E_APP_LOG" 30
	e2e_die "app window never appeared (it may still be building; re-run \`app.sh status\`, raise E2E_APP_TIMEOUT, or fix E2E_APP_ID)"
}

print_windows() {
	local out
	out="$(e2e_windows "${E2E_APP_ID:-*}" 2>/dev/null || true)"
	if [[ -z $out ]]; then
		printf 'window:     none with app_id="%s"\n' "${E2E_APP_ID:-<any>}"
		return 1
	fi
	local app_id name x y w h
	while IFS=$'\t' read -r app_id name x y w h; do
		printf 'window:     app_id=%s name=%q rect=%s,%s %sx%s\n' \
			"$app_id" "$name" "$x" "$y" "$w" "$h"
	done <<<"$out"
}

cmd_stop() {
	if ! e2e_kill_group "$E2E_APP_PIDFILE" "app" 20; then
		e2e_say "app was not running (per pidfile)"
	fi
	[[ -n $E2E_APP_PORT ]] || return 0
	local i
	for ((i = 0; i < 100; i++)); do
		e2e_port_in_use "$E2E_APP_PORT" || break
		sleep 0.1
	done
	if e2e_port_in_use "$E2E_APP_PORT"; then
		e2e_warn "port $E2E_APP_PORT is still bound after stopping:"
		e2e_port_owner "$E2E_APP_PORT" >&2 || true
		return 1
	fi
	e2e_say "port $E2E_APP_PORT is free"
}

cmd_status() {
	local pid
	if pid="$(e2e_read_pid "$E2E_APP_PIDFILE")"; then
		printf 'app:        running (process group %s)\n' "$pid"
	else
		printf 'app:        not running (per %s)\n' "$E2E_APP_PIDFILE"
	fi
	if [[ -n $E2E_APP_PORT ]]; then
		if e2e_port_in_use "$E2E_APP_PORT"; then
			printf 'port:       %s in use\n' "$E2E_APP_PORT"
		else
			printf 'port:       %s free\n' "$E2E_APP_PORT"
		fi
	fi
	printf 'log:        %s\n' "$E2E_APP_LOG"
	if e2e_compositor_up; then
		print_windows || true
	else
		printf 'window:     unknown (E2E compositor is not running)\n'
	fi
}

main() {
	local cmd="${1:-}"
	[[ $# -gt 0 ]] && shift || true
	case "$cmd" in
	start) cmd_start "$@" ;;
	stop) cmd_stop "$@" ;;
	status) cmd_status "$@" ;;
	-h | --help | '') usage ;;
	*)
		usage >&2
		e2e_die "unknown command: $cmd"
		;;
	esac
}

main "$@"
