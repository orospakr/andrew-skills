#!/usr/bin/env bash
# ui.sh -- drive the app running inside the headless E2E compositor.
#
# Everything here goes through the E2E compositor's own seat (sway IPC), its own
# Wayland socket (wtype/grim), and its own wayvnc virtual pointer.  No uinput,
# no hyprctl, no talking to the real session: the desktop you are sitting in
# front of never receives a single event.
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/env.sh"

usage() {
	cat <<EOF
usage: ui.sh <command> [args]

pointer (sway IPC, "seat $E2E_SEAT cursor ..." on the E2E compositor only)
  warp X Y                 move cursor to X,Y, then jiggle -- a bare warp does
                           not produce the pointer motion clients need for hover
  click [X Y]              left click, optionally warping (with jiggle) first
  rightclick [X Y]         right click
  middleclick [X Y]        middle click
  press [BUTTON]           press and hold (default: left).  NOTE: sway sends no
                           motion while a button is down, so press+warp+release
                           does NOT make a drag -- use \`drag\`.
  release [BUTTON]         release (default: left)
  drag X1 Y1 X2 Y2 [STEPS] press, interpolate in STEPS moves (default 20),
                           release.  Goes through wayvnc's virtual pointer, so
                           it needs --vnc.
  scroll N [X Y]           N wheel notches: positive scrolls down/away, negative
                           up.  Real wl_pointer axis events, sent through
                           wayvnc's virtual pointer (sway's \`cursor press
                           button4/5\` silently does nothing).  Needs --vnc.
  keyscroll N [X Y]        fallback: Page_Down/Page_Up N times via wtype.  Needs
                           *keyboard* focus, so \`click\` the pane first.
  cursorpos                last position this script warped to, plus the seat's
                           wl_seat capabilities (sway IPC cannot report the real
                           cursor position)

keyboard (wtype, virtual-keyboard protocol)
  type TEXT                type literal text
  key KEY                  named key, optionally with modifiers:
                           "Return", "Escape", "Tab", "ctrl+a", "ctrl+shift+k"
                           modifiers: shift, ctrl, alt, logo/win, altgr, capslock

screen
  shot [--cursor] FILE [GEOM]
                           grim screenshot of $E2E_OUTPUT, or of GEOM given as
                           "X,Y WxH".  Output scale is 1, so pixels == the
                           coordinates used by warp/click.
  tree                     windows on the E2E compositor (app_id, rect, name)

Coordinates are logical == physical pixels on a ${E2E_WIDTH}x${E2E_HEIGHT} output
at 0,0, and the app is fullscreen, so screen coords == window coords.
Note: sway treats a coordinate of 0 specially, so values are clamped to >= 1.
EOF
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# sway_cmd WORDS... -- run one sway command.  The words are joined into a single
# argument so that negative numbers (e.g. `cursor move -2 0`) are not eaten by
# swaymsg's own option parser.
sway_cmd() {
	swaymsg_e2e -q -- "$*"
}

need_int() {
	[[ $1 =~ ^-?[0-9]+$ ]] || e2e_die "expected an integer, got: $1"
}

clamp_x() {
	local v="$1"
	if ((v < 1)); then v=1; fi
	if ((v > E2E_WIDTH - 1)); then v=$((E2E_WIDTH - 1)); fi
	printf '%s\n' "$v"
}

clamp_y() {
	local v="$1"
	if ((v < 1)); then v=1; fi
	if ((v > E2E_HEIGHT - 1)); then v=$((E2E_HEIGHT - 1)); fi
	printf '%s\n' "$v"
}

# button_name NAME -- normalise a button to sway's button[1-9] spelling.
# sway maps button1=BTN_LEFT, button2=BTN_MIDDLE, button3=BTN_RIGHT.
# button1..button9 is the portable spelling accepted by every sway version;
# BTN_LEFT etc. also work but go through a libevdev name lookup.
button_name() {
	case "${1:-left}" in
	left | BTN_LEFT | button1 | 1) printf 'button1\n' ;;
	middle | BTN_MIDDLE | button2 | 2) printf 'button2\n' ;;
	right | BTN_RIGHT | button3 | 3) printf 'button3\n' ;;
	button[4-9]) printf '%s\n' "$1" ;;
	BTN_*) printf '%s\n' "$1" ;;
	*) e2e_die "unknown mouse button: $1 (use left/middle/right or button1..button9)" ;;
	esac
}

set_cursor() { # set_cursor X Y  (no jiggle, no bookkeeping)
	sway_cmd seat "$E2E_SEAT" cursor set "$1" "$2"
}

# do_warp X Y -- absolute move plus a 2px round trip.  Warping alone leaves some
# clients without a fresh pointer motion event, so hover state does not update;
# the extra relative move fixes that.  The final `set` puts the cursor back on
# the exact requested pixel.
do_warp() {
	local x y
	x="$(clamp_x "$1")"
	y="$(clamp_y "$2")"
	set_cursor "$x" "$y"
	sleep 0.03
	sway_cmd seat "$E2E_SEAT" cursor move 2 0
	sleep 0.03
	set_cursor "$x" "$y"
	printf '%s %s\n' "$x" "$y" >"$E2E_CURSOR_FILE"
}

# vnc_pointer MODE ARGS... -- run the wayvnc-backed pointer helper.  sway IPC
# cannot synthesise wheel events or motion-while-pressed; see vnc-pointer.py.
vnc_pointer() {
	[[ -r $E2E_VNC_POINTER ]] || e2e_die "pointer helper not found: $E2E_VNC_POINTER"
	e2e_port_in_use "$E2E_VNC_PORT" || e2e_die \
		"'$1' needs wayvnc on $E2E_VNC_HOST:$E2E_VNC_PORT (sway IPC cannot do it) -- start it with: $E2E_DIR/compositor.sh vnc"
	python3 "$E2E_VNC_POINTER" "$E2E_VNC_HOST" "$E2E_VNC_PORT" "$@" ||
		e2e_die "$1 failed (see the message above)"
}

# maybe_warp [X Y] -- warp when a coordinate pair was supplied.
maybe_warp() {
	if (($# >= 2)); then
		need_int "$1"
		need_int "$2"
		do_warp "$1" "$2"
		sleep 0.05
	elif (($# == 1)); then
		e2e_die "coordinates come in pairs: give both X and Y (or neither)"
	fi
}

do_click() {
	local button="$1"
	shift
	e2e_require_compositor
	maybe_warp "$@"
	sway_cmd seat "$E2E_SEAT" cursor press "$button"
	sleep 0.05
	sway_cmd seat "$E2E_SEAT" cursor release "$button"
}

# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------

cmd_warp() {
	(($# == 2)) || e2e_die "usage: ui.sh warp X Y"
	need_int "$1"
	need_int "$2"
	e2e_require_compositor
	do_warp "$1" "$2"
}

cmd_press() {
	e2e_require_compositor
	sway_cmd seat "$E2E_SEAT" cursor press "$(button_name "${1:-left}")"
}

cmd_release() {
	e2e_require_compositor
	sway_cmd seat "$E2E_SEAT" cursor release "$(button_name "${1:-left}")"
}

cmd_drag() {
	(($# >= 4)) || e2e_die "usage: ui.sh drag X1 Y1 X2 Y2 [STEPS]"
	local x1 y1 x2 y2 steps
	need_int "$1"
	need_int "$2"
	need_int "$3"
	need_int "$4"
	e2e_require_compositor
	x1="$(clamp_x "$1")"
	y1="$(clamp_y "$2")"
	x2="$(clamp_x "$3")"
	y2="$(clamp_y "$4")"
	steps="${5:-20}"
	need_int "$steps"
	((steps >= 1)) || e2e_die "STEPS must be >= 1"

	# NOT via sway IPC.  A drag is press + motion + release, and sway delivers no
	# motion at all while a button is down: `cursor set`/`cursor move` only
	# *rebase* the pointer, and the seat operation that is active during a press
	# on a client surface (seatop_down) has no rebase handler, so the motion is
	# discarded.  The client sees press and release at the same pixel.  Measured
	# on sway 1.12 against two unrelated clients (a terminal: drag-select
	# selected nothing; a WebKitGTK webview: a scrollbar thumb never followed the
	# cursor, though a plain click on the scrollbar track did jump it -- the
	# buttons arrive, the motion does not).  wayvnc's virtual pointer does it
	# properly.
	do_warp "$x1" "$y1"
	sleep 0.05
	vnc_pointer drag "$x1" "$y1" "$x2" "$y2" "$steps"
	printf '%s %s\n' "$x2" "$y2" >"$E2E_CURSOR_FILE"
	# Put sway's own cursor where the drag ended, so a following warp/hover
	# starts from the right place.
	set_cursor "$x2" "$y2"
}

cmd_scroll() {
	(($# >= 1)) || e2e_die "usage: ui.sh scroll N [X Y]   (positive N scrolls down)"
	local n="$1"
	shift
	need_int "$n"
	e2e_require_compositor

	# NOT via sway IPC.  `seat <s> cursor press button4/button5` looks like it
	# should work -- swaymsg even answers {"success": true} -- but sway resolves
	# those names to its SWAY_SCROLL_UP/DOWN pseudo-button codes, which exist
	# only so `bindsym button4 ...` can match.  `cursor press` pushes the
	# pseudo-code down the ordinary button path, so no wl_pointer.axis event is
	# ever sent and no client scrolls (verified against a terminal's scrollback
	# *and* a WebKitGTK webview: zero movement at any notch count).
	#
	# wayvnc's zwlr_virtual_pointer_v1 does emit real axis events, so the wheel
	# is synthesised by speaking RFB to the wayvnc the harness already runs.
	local x y
	if (($# >= 2)); then
		need_int "$1"
		need_int "$2"
		do_warp "$1" "$2"
		sleep 0.05
		x="$(clamp_x "$1")"
		y="$(clamp_y "$2")"
	elif (($# == 1)); then
		e2e_die "coordinates come in pairs: give both X and Y (or neither)"
	elif [[ -s $E2E_CURSOR_FILE ]]; then
		read -r x y <"$E2E_CURSOR_FILE"
	else
		e2e_die "ui.sh scroll needs a target: pass X Y (nothing has been warped yet)"
	fi

	vnc_pointer scroll "$x" "$y" "$n"
}

cmd_keyscroll() {
	(($# >= 1)) || e2e_die "usage: ui.sh keyscroll N [X Y]"
	local n="$1"
	shift
	need_int "$n"
	e2e_require_compositor
	e2e_need wtype
	maybe_warp "$@"
	local keyname='Page_Down' i count="$n"
	if ((n < 0)); then
		keyname='Page_Up'
		count=$((-n))
	fi
	for ((i = 0; i < count; i++)); do
		e2e_wl wtype -k "$keyname"
		sleep 0.05
	done
}

cmd_type() {
	(($# >= 1)) || e2e_die "usage: ui.sh type TEXT"
	e2e_require_compositor
	e2e_need wtype
	e2e_wl wtype -- "$*"
}

cmd_key() {
	(($# == 1)) || e2e_die "usage: ui.sh key KEY   (e.g. Return, Escape, ctrl+shift+k)"
	e2e_require_compositor
	e2e_need wtype
	local spec="$1" keyname part idx
	local -a mods=() args=() parts=()
	IFS='+' read -r -a parts <<<"$spec"
	keyname="${parts[-1]}"
	unset 'parts[-1]'
	for part in ${parts[@]+"${parts[@]}"}; do
		if [[ -z $part ]]; then continue; fi
		case "${part,,}" in
		shift | capslock | ctrl | logo | win | alt | altgr) mods+=("${part,,}") ;;
		control) mods+=(ctrl) ;;
		super | meta) mods+=(logo) ;;
		*) e2e_die "unknown modifier: $part (shift, capslock, ctrl, logo, win, alt, altgr)" ;;
		esac
	done
	for ((idx = 0; idx < ${#mods[@]}; idx++)); do args+=(-M "${mods[idx]}"); done
	args+=(-k "$keyname")
	for ((idx = ${#mods[@]} - 1; idx >= 0; idx--)); do args+=(-m "${mods[idx]}"); done
	e2e_wl wtype "${args[@]}"
}

cmd_shot() {
	local with_cursor=0
	while (($#)); do
		case "$1" in
		--cursor | -c)
			with_cursor=1
			shift
			;;
		*) break ;;
		esac
	done
	(($# >= 1)) || e2e_die "usage: ui.sh shot [--cursor] FILE [\"X,Y WxH\"]"
	e2e_require_compositor
	e2e_need grim
	local out="$1"
	shift
	local -a args=()
	if ((with_cursor)); then args+=(-c); fi
	if (($# >= 1)); then
		args+=(-g "$1")
	else
		args+=(-o "$E2E_OUTPUT")
	fi
	e2e_wl grim "${args[@]}" "$out"
	e2e_say "wrote $out"
}

cmd_tree() {
	e2e_require_compositor
	local out
	out="$(e2e_windows '*' || true)"
	if [[ -z $out ]]; then
		e2e_say "no windows on the E2E compositor"
		return 1
	fi
	printf '%-24s %-16s %s\n' 'APP_ID' 'RECT' 'NAME'
	local app_id name x y w h
	while IFS=$'\t' read -r app_id name x y w h; do
		printf '%-24s %-16s %s\n' "$app_id" "$x,$y ${w}x${h}" "$name"
	done <<<"$out"
}

cmd_cursorpos() {
	e2e_require_compositor
	if [[ -s $E2E_CURSOR_FILE ]]; then
		printf 'last warp: %s\n' "$(<"$E2E_CURSOR_FILE")"
	else
		printf 'last warp: unknown (nothing warped since the compositor started)\n'
	fi
	printf 'seat:      %s\n' "$(e2e_seat_capabilities || echo 'unavailable')"
	printf 'note:      sway IPC does not expose the live cursor position; use\n'
	printf '           `ui.sh shot --cursor /tmp/c.png` to see where it really is.\n'
}

main() {
	local cmd="${1:-}"
	[[ $# -gt 0 ]] && shift || true
	case "$cmd" in
	warp) cmd_warp "$@" ;;
	click) do_click button1 "$@" ;;
	rightclick) do_click button3 "$@" ;;
	middleclick) do_click button2 "$@" ;;
	press) cmd_press "$@" ;;
	release) cmd_release "$@" ;;
	drag) cmd_drag "$@" ;;
	scroll) cmd_scroll "$@" ;;
	keyscroll) cmd_keyscroll "$@" ;;
	type) cmd_type "$@" ;;
	key) cmd_key "$@" ;;
	shot) cmd_shot "$@" ;;
	tree) cmd_tree "$@" ;;
	cursorpos) cmd_cursorpos "$@" ;;
	-h | --help | '') usage ;;
	*)
		usage >&2
		e2e_die "unknown command: $cmd"
		;;
	esac
}

main "$@"
