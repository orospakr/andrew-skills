#!/usr/bin/env bash
# compositor.sh -- start/stop/inspect the private headless sway compositor used
# for Wayland E2E automation.
#
# The compositor runs on the wlroots headless backend with its own Wayland
# socket and its own seat, so nothing it does can reach the real desktop session
# on this machine.
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/env.sh"

usage() {
	cat <<EOF
usage: compositor.sh <command>

commands:
  start [--vnc]   launch headless sway.  --vnc also starts wayvnc *and* an idle
                  RFB client, which is what gives $E2E_SEAT its pointer capability
                  (see vnc-hold.py); without a pointer, ui.sh clicks/hovers
                  never reach the app.
  vnc             attach wayvnc + the seat holder to an already-running
                  compositor (same thing \`start --vnc\` does)
  stop            stop the seat holder, wayvnc and sway; clean up pidfiles/symlink
  status          report pid, sockets, outputs and seat capabilities
  -h, --help      this message

environment:
  E2E_RUNTIME_DIR       pidfiles/logs dir   (currently $E2E_RUNTIME_DIR)
  E2E_WAYLAND_DISPLAY   stable socket name  (currently $E2E_WAYLAND_DISPLAY)
  E2E_WIDTH/E2E_HEIGHT  output size         (currently ${E2E_WIDTH}x${E2E_HEIGHT})
  E2E_APP_ID            app_id fullscreened (currently ${E2E_APP_ID:-<any>})
  E2E_WLR_RENDERER      passed to sway as WLR_RENDERER (try: pixman)
  E2E_VNC_HOST/PORT     wayvnc bind address (currently $E2E_VNC_HOST:$E2E_VNC_PORT)
  E2E_SWAY_CONFIG       use this config verbatim instead of rendering the
                        template at $E2E_SWAY_CONFIG_TEMPLATE
EOF
}

# Path of the stable symlink that gives the E2E compositor a predictable
# WAYLAND_DISPLAY.  sway picks wayland-1..wayland-32 itself and ignores any
# WAYLAND_DISPLAY we set, so we link our name onto whatever it chose.
alias_path() { printf '%s/%s\n' "$XDG_RUNTIME_DIR" "$E2E_WAYLAND_DISPLAY"; }

# Render the sway config template, substituting the knobs sway itself cannot
# read from the environment.  Echoes the path of the config to load.
render_config() {
	if [[ -n $E2E_SWAY_CONFIG ]]; then
		[[ -r $E2E_SWAY_CONFIG ]] || e2e_die "sway config not readable: $E2E_SWAY_CONFIG"
		printf '%s\n' "$E2E_SWAY_CONFIG"
		return 0
	fi
	[[ -r $E2E_SWAY_CONFIG_TEMPLATE ]] ||
		e2e_die "sway config template not readable: $E2E_SWAY_CONFIG_TEMPLATE"
	# Empty E2E_APP_ID => match everything, so a single unknown-app_id window
	# still ends up fullscreen.
	local app_id="${E2E_APP_ID:-.*}"
	sed \
		-e "s|@OUTPUT@|$E2E_OUTPUT|g" \
		-e "s|@WIDTH@|$E2E_WIDTH|g" \
		-e "s|@HEIGHT@|$E2E_HEIGHT|g" \
		-e "s|@APP_ID@|$app_id|g" \
		-- "$E2E_SWAY_CONFIG_TEMPLATE" >"$E2E_SWAY_CONFIG_RENDERED"
	printf '%s\n' "$E2E_SWAY_CONFIG_RENDERED"
}

# List of currently existing wayland-N sockets, one basename per line.
wayland_socket_names() {
	local path name
	for path in "$XDG_RUNTIME_DIR"/wayland-*; do
		[[ -S $path ]] || continue
		name="${path##*/}"
		if [[ $name == "$E2E_WAYLAND_DISPLAY" ]]; then continue; fi
		printf '%s\n' "$name"
	done
}

# Extract sway's chosen display name from its log.  sway logs
#   "Running compositor on wayland display 'wayland-N'"
# at SWAY_INFO level, which is why it is started with -V.
display_from_log() {
	local line
	line="$(grep -o "Running compositor on wayland display '[^']*'" "$E2E_SWAY_LOG" 2>/dev/null | tail -n 1)" || true
	[[ -n $line ]] || return 1
	line="${line#*\'}"
	printf '%s\n' "${line%\'}"
}

clear_state() {
	rm -f -- "$E2E_SWAY_PIDFILE" "$E2E_SWAY_SOCKFILE" "$E2E_SWAY_DISPLAYFILE" \
		"$E2E_VNC_PIDFILE" "$E2E_VNC_HOLD_PIDFILE" "$E2E_CURSOR_FILE"
	rm -f -- "$(alias_path)"
}

# wayvnc registers its wlr_virtual_pointer_v1 / wlr_virtual_keyboard_v1 pair on
# the seat per *connected client* and destroys them when the last one leaves, so
# a bare `wayvnc` leaves the seat at capabilities=0.  Keep one idle RFB client
# attached; that is what gives the seat its pointer, and therefore what makes
# `ui.sh click`/`warp` reach the app at all.
start_vnc_hold() {
	if e2e_read_pid "$E2E_VNC_HOLD_PIDFILE" >/dev/null; then
		e2e_say "seat holder already running"
		return 0
	fi
	[[ -r $E2E_VNC_HOLD ]] || {
		e2e_warn "seat holder script not found: $E2E_VNC_HOLD"
		return 1
	}
	: >"$E2E_VNC_HOLD_LOG"
	e2e_spawn "$E2E_VNC_HOLD_PIDFILE" "$E2E_VNC_HOLD_LOG" \
		python3 "$E2E_VNC_HOLD" "$E2E_VNC_HOST" "$E2E_VNC_PORT"
	local pid i
	if ! pid="$(e2e_wait_pidfile "$E2E_VNC_HOLD_PIDFILE" 5)"; then
		e2e_warn "seat holder failed to start"
		e2e_tail "$E2E_VNC_HOLD_LOG" 20
		return 1
	fi
	for ((i = 0; i < 100; i++)); do
		if e2e_seat_has_pointer; then
			e2e_say "seat holder attached (pid $pid); $(e2e_seat_capabilities)"
			return 0
		fi
		kill -0 "$pid" 2>/dev/null || break
		sleep 0.1
	done
	e2e_warn "seat still has no pointer capability after starting the seat holder"
	e2e_tail "$E2E_VNC_HOLD_LOG" 20
	return 1
}

start_wayvnc() {
	if ! command -v wayvnc >/dev/null 2>&1; then
		e2e_say "wayvnc is not installed; skipping --vnc (install it: the seat gets no pointer without it)"
		return 0
	fi
	local pid
	if pid="$(e2e_read_pid "$E2E_VNC_PIDFILE")"; then
		e2e_say "wayvnc already running (pid $pid)"
	else
		local sock
		sock="$(e2e_swaysock)"
		: >"$E2E_VNC_LOG"
		e2e_spawn "$E2E_VNC_PIDFILE" "$E2E_VNC_LOG" \
			env -u DISPLAY \
			WAYLAND_DISPLAY="$E2E_WAYLAND_DISPLAY" \
			XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
			SWAYSOCK="$sock" \
			wayvnc -o "$E2E_OUTPUT" "$E2E_VNC_HOST" "$E2E_VNC_PORT"
		if pid="$(e2e_wait_pidfile "$E2E_VNC_PIDFILE" 5)"; then
			e2e_say "wayvnc listening on $E2E_VNC_HOST:$E2E_VNC_PORT (pid $pid, log $E2E_VNC_LOG)"
		else
			e2e_warn "wayvnc failed to start"
			e2e_tail "$E2E_VNC_LOG" 20
			return 0
		fi
	fi
	# Wait for the listening socket before the seat holder tries to connect.
	local i
	for ((i = 0; i < 100; i++)); do
		e2e_port_in_use "$E2E_VNC_PORT" && break
		sleep 0.1
	done
	start_vnc_hold || true
}

cmd_start() {
	local want_vnc=0
	while (($#)); do
		case "$1" in
		--vnc) want_vnc=1 ;;
		-h | --help)
			usage
			return 0
			;;
		*) e2e_die "start: unknown option: $1" ;;
		esac
		shift
	done

	e2e_need sway swaymsg python3 setsid sed

	if e2e_compositor_up; then
		e2e_die "E2E compositor is already running (pid $(cat "$E2E_SWAY_PIDFILE" 2>/dev/null || echo '?'), socket $(cat "$E2E_SWAY_SOCKFILE" 2>/dev/null || echo '?')). Use: compositor.sh stop"
	fi
	if e2e_read_pid "$E2E_SWAY_PIDFILE" >/dev/null; then
		e2e_die "a process from a previous run is still alive (pid $(cat "$E2E_SWAY_PIDFILE")) but its IPC socket does not answer. Use: compositor.sh stop"
	fi

	local config
	config="$(render_config)"

	clear_state
	: >"$E2E_SWAY_LOG"

	local before
	before="$(wayland_socket_names || true)"

	# Environment for the child compositor.  Critically:
	#   * WAYLAND_DISPLAY is UNSET so sway does not nest inside the real session,
	#   * DISPLAY is UNSET so wlroots cannot pick the X11 backend,
	#   * SWAYSOCK is UNSET so sway creates its own IPC socket path,
	#   * WLR_BACKENDS=headless forces the headless backend (no DRM, no
	#     libinput, no logind seat takeover -- the machine stays usable).
	local -a child_env=(
		env
		-u DISPLAY
		-u WAYLAND_DISPLAY
		-u SWAYSOCK
		-u XDG_SESSION_TYPE
		-u XDG_SESSION_ID
		XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR"
		XDG_CURRENT_DESKTOP=sway
		WLR_BACKENDS=headless
		WLR_LIBINPUT_NO_DEVICES=1
		WLR_HEADLESS_OUTPUTS=1
	)
	if [[ -n ${E2E_WLR_RENDERER:-} ]]; then
		child_env+=("WLR_RENDERER=$E2E_WLR_RENDERER")
	fi

	e2e_say "starting headless sway (config $config, ${E2E_WIDTH}x${E2E_HEIGHT})"
	# -V (verbose) makes sway log the wayland display name it settled on.
	e2e_spawn "$E2E_SWAY_PIDFILE" "$E2E_SWAY_LOG" \
		"${child_env[@]}" sway -V -c "$config"

	local pid
	if ! pid="$(e2e_wait_pidfile "$E2E_SWAY_PIDFILE" 5)"; then
		e2e_tail "$E2E_SWAY_LOG" 40
		e2e_die "sway did not start (no live pid recorded)"
	fi

	# sway names its IPC socket after its own pid; wait for it to answer.
	local sock i
	sock="$(e2e_expected_swaysock "$pid")"
	local ok=0
	for ((i = 0; i < E2E_COMPOSITOR_TIMEOUT * 10; i++)); do
		if [[ -S $sock ]] && SWAYSOCK="$sock" swaymsg -t get_version >/dev/null 2>&1; then
			ok=1
			break
		fi
		if ! kill -0 "$pid" 2>/dev/null; then
			e2e_tail "$E2E_SWAY_LOG" 40
			e2e_die "sway exited during startup"
		fi
		sleep 0.1
	done
	if ((ok == 0)); then
		e2e_tail "$E2E_SWAY_LOG" 40
		e2e_die "timed out after ${E2E_COMPOSITOR_TIMEOUT}s waiting for sway IPC at $sock"
	fi
	printf '%s\n' "$sock" >"$E2E_SWAY_SOCKFILE"

	# Discover the Wayland socket sway chose, then publish it under our stable
	# name via a symlink (libwayland resolves a relative WAYLAND_DISPLAY inside
	# XDG_RUNTIME_DIR, and follows symlinks there).
	local display=''
	for ((i = 0; i < 50; i++)); do
		if display="$(display_from_log)"; then break; fi
		display=''
		sleep 0.1
	done
	if [[ -z $display ]]; then
		# Fallback: whichever wayland-N socket appeared since we launched.
		local name
		while read -r name; do
			[[ -n $name ]] || continue
			if ! grep -qxF -- "$name" <<<"$before"; then
				display="$name"
				break
			fi
		done < <(wayland_socket_names || true)
	fi
	[[ -n $display ]] || {
		e2e_tail "$E2E_SWAY_LOG" 40
		e2e_die "could not determine sway's WAYLAND_DISPLAY"
	}
	printf '%s\n' "$display" >"$E2E_SWAY_DISPLAYFILE"
	ln -sfn -- "$display" "$(alias_path)"

	e2e_say "compositor up: pid=$pid display=$E2E_WAYLAND_DISPLAY -> $display"
	e2e_say "  SWAYSOCK=$sock"
	e2e_say "  log=$E2E_SWAY_LOG"
	swaymsg_e2e -t get_outputs || true

	if ((want_vnc)); then
		start_wayvnc
	fi
}

# Attach wayvnc (and the seat holder) to a compositor that is already up.
cmd_vnc() {
	e2e_require_compositor
	start_wayvnc
}

cmd_stop() {
	local stopped=0
	if e2e_kill_group "$E2E_VNC_HOLD_PIDFILE" "vnc seat holder" 5; then stopped=1; fi
	if e2e_kill_group "$E2E_VNC_PIDFILE" wayvnc 5; then stopped=1; fi
	if e2e_kill_group "$E2E_SWAY_PIDFILE" "sway (E2E)" 10; then stopped=1; fi
	rm -f -- "$(alias_path)" "$E2E_SWAY_SOCKFILE" "$E2E_SWAY_DISPLAYFILE" "$E2E_CURSOR_FILE"
	if ((stopped)); then
		e2e_say "stopped"
	else
		e2e_say "nothing to stop"
	fi
}

cmd_status() {
	local pid sock display
	if pid="$(e2e_read_pid "$E2E_SWAY_PIDFILE")"; then
		printf 'compositor: running (pid %s)\n' "$pid"
	else
		printf 'compositor: not running\n'
	fi
	sock="$(cat "$E2E_SWAY_SOCKFILE" 2>/dev/null || echo '-')"
	display="$(cat "$E2E_SWAY_DISPLAYFILE" 2>/dev/null || echo '-')"
	printf 'swaysock:   %s\n' "$sock"
	printf 'display:    %s -> %s\n' "$E2E_WAYLAND_DISPLAY" "$display"
	printf 'log:        %s\n' "$E2E_SWAY_LOG"
	if e2e_read_pid "$E2E_VNC_PIDFILE" >/dev/null; then
		printf 'wayvnc:     running on %s:%s\n' "$E2E_VNC_HOST" "$E2E_VNC_PORT"
	else
		printf 'wayvnc:     not running\n'
	fi
	if e2e_read_pid "$E2E_VNC_HOLD_PIDFILE" >/dev/null; then
		printf 'seat holder: attached (keeps the virtual pointer/keyboard alive)\n'
	else
		printf 'seat holder: not running\n'
	fi
	if e2e_compositor_up; then
		printf '\n'
		swaymsg_e2e -t get_outputs || true
		printf '\n'
		e2e_seat_capabilities || true
	else
		printf 'ipc:        no response\n'
		return 1
	fi
}

main() {
	local cmd="${1:-}"
	[[ $# -gt 0 ]] && shift || true
	case "$cmd" in
	start) cmd_start "$@" ;;
	vnc) cmd_vnc "$@" ;;
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
