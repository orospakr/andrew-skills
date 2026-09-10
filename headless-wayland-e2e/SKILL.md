---
name: headless-wayland-e2e
description: Use when driving, E2E-testing, screenshotting or visually verifying a Linux desktop Wayland app (GTK, Qt, Tauri/WebKitGTK, wlroots clients) without disturbing the user's live desktop session. Launches the app inside a private headless sway compositor with its own seat, then clicks, hovers, drags, scrolls, types and captures PNGs against it. Triggers: "run the app and screenshot it", "click through the UI", "test the GUI headlessly", "automate the desktop app", "verify this change in the real window".
---

# Headless Wayland E2E

## Overview

Run a real Wayland app — real window, real toolkit, real rendering — inside a
**private headless sway compositor**, and drive it with pointer, keyboard and
screenshots. The user's actual session never sees any of it: no stolen focus, no
cursor jumping across their screen, no synthetic keystrokes landing in the wrong
window. They can keep working while a run is in progress.

Why not the obvious alternatives:

* **Driving the live session** (`hyprctl dispatch`, `/dev/uinput`, `ydotool`)
  takes the machine over. Every click is a click the user can see and collide
  with, and a stray keystroke goes wherever focus happens to be.
* **Xvfb** only helps X11 apps. A Wayland-native app under Xvfb either refuses
  to start or runs through XWayland with different input, scaling and rendering
  paths than production — you end up testing the wrong thing.

What this gives instead: a wlroots headless backend, one output, one seat, one
Wayland socket, all disposable. Scale 1 and a fullscreen window mean screenshot
pixels are the same numbers you pass to `click`.

**Do not use for X11-only apps** — reach for the `gtk4-e2e-testing-atspi`
sibling skill (Xvfb + AT-SPI) instead. That skill is also the better answer when
you need the *accessibility tree* rather than pixels.

## Prerequisites

```sh
sudo pacman -S --needed sway wayvnc grim wtype   # plus python3, already present
```

`wayvnc` is not optional in practice — see the pointer-capability gotcha below.

## Files

| file | what it is |
| --- | --- |
| `env.sh` | sourced by the others; knobs, paths, `swaymsg_e2e`, process helpers |
| `compositor.sh` | `start [--vnc]` / `vnc` / `stop` / `status` for the headless sway |
| `sway-e2e.config` | **template** sway config (`@OUTPUT@`/`@WIDTH@`/`@HEIGHT@`/`@APP_ID@`), rendered into `$E2E_RUNTIME_DIR/sway.rendered.config` at start |
| `app.sh` | `start` / `stop` / `status` for *your* app inside it |
| `ui.sh` | pointer, keyboard and screenshot commands against that compositor only |
| `vnc-hold.py` | idle RFB client that keeps wayvnc's virtual pointer on the seat |
| `vnc-pointer.py` | wheel + drag gestures via that virtual pointer (sway IPC can do neither) |

State (pidfiles, logs, recorded socket paths, rendered config) lives under
`$E2E_RUNTIME_DIR`, default `$XDG_RUNTIME_DIR/headless-e2e`. Set it per project
to keep concurrent harnesses apart (`E2E_VNC_PORT` too, if you run two at once).

## Quickstart

```sh
cd <this skill dir>

./compositor.sh start --vnc          # ~1s.  --vnc is what gives the seat a pointer
E2E_APP_ID=foot ./app.sh start -- foot

./ui.sh tree                         # what is on screen
./ui.sh shot /tmp/x.png              # full-output PNG
./ui.sh click 640 400
./ui.sh warp 300 250                 # hover
./ui.sh shot /tmp/hover.png "200,200 400x200"
./ui.sh type "echo hello"
./ui.sh key Return
./ui.sh scroll -5 640 400            # 5 notches up, real wl_pointer.axis
./ui.sh drag 200 200 400 300

./app.sh stop && ./compositor.sh stop
```

`compositor.sh status` and `app.sh status` are safe at any time and are the
first thing to check when something looks wrong.

### Pointing it at your app

Two equivalent forms:

```sh
E2E_APP_ID=myapp ./app.sh start -- myapp --some-flag
E2E_APP_CMD='npm run dev:desktop' E2E_APP_ID=myapp E2E_APP_CWD=~/src/myapp ./app.sh start
```

| var | meaning |
| --- | --- |
| `E2E_APP_CMD` | shell command line to launch (alternative to `-- CMD...`) |
| `E2E_APP_CWD` | working directory (default: cwd) |
| `E2E_APP_ID` | xdg-shell `app_id` to wait for. **Unset = wait for any window** and fullscreen everything |
| `E2E_APP_TIMEOUT` | seconds to wait for the window (default 120; a cold compile needs it) |
| `E2E_APP_PORT` | optional singleton TCP-port guard, see below. Unset = no guard |
| `E2E_APP_ENV_PASS` | extra env var names to forward into the app |
| `E2E_WIDTH`/`E2E_HEIGHT` | output size (default 1280x800); rendered into the sway config, so this is the only place to change it |

`app.sh start` launches under `setsid` and records the process-group leader, so
`app.sh stop` reaps the whole tree with `kill -TERM -<pgid>` — necessary when the
launch command is a wrapper that spawns a dev server plus a compiler plus the
app binary.

`WEBKIT_DISABLE_DMABUF_RENDERER`, `WEBKIT_DISABLE_COMPOSITING_MODE`,
`WEBKIT_FORCE_SANDBOX`, `GDK_DEBUG`, `GTK_DEBUG`, `G_MESSAGES_DEBUG`,
`RUST_LOG` and `RUST_BACKTRACE` are forwarded automatically when set.
`GDK_BACKEND`/`QT_QPA_PLATFORM` are deliberately *not* inherited — desktop
sessions export them with an X11 fallback appended (`wayland,x11,*`,
`wayland;xcb`) and that would undo the Wayland-only pinning; the harness forces
`=wayland` instead.

## Coordinate model

* One output (`HEADLESS-1`) at position `0,0`, `scale 1`.
* Scale 1 means **logical coordinates == pixels**: the numbers you pass to
  `ui.sh warp/click/drag` are the numbers you read off a `ui.sh shot` PNG.
* The app is fullscreened by `for_window [app_id="…"] fullscreen enable`, and
  there is no bar and no border, so its rect is the whole output and **screen
  coords == window coords == CSS px** (for a webview at devicePixelRatio 1).
* Change the size with `E2E_WIDTH`/`E2E_HEIGHT` alone — the sway config is
  rendered from a template at every `compositor.sh start`, so they cannot drift
  apart.

## Gotcha catalogue

This is the part worth reading twice. Every entry below was paid for in
debugging time.

### You must run `--vnc`, or the app receives no pointer events at all

sway advertises `wl_seat` pointer capability only when the seat actually *has* a
pointer device, and the wlroots headless backend creates none. Without one,
`ui.sh warp`/`click` still move sway's own cursor (so window focus follows it)
but **no `wl_pointer` event ever reaches the client** — the app ignores
everything, silently.

wayvnc supplies the missing device via `wlr_virtual_pointer_v1` +
`wlr_virtual_keyboard_v1` — but, measured on wayvnc 0.10.1 / sway 1.12, it
registers them **per connected RFB client** and destroys them when the last
client leaves:

| state | seat0 |
| --- | --- |
| wayvnc running, nobody connected | `capabilities=0 [none] devices=0` |
| one RFB client connected | `capabilities=3 [pointer,keyboard] devices=2` |

So running wayvnc is not by itself enough. `compositor.sh start --vnc` also
starts `vnc-hold.py`: an idle RFB client that completes the handshake and then
does nothing — it never requests a framebuffer update, so it costs a socket and
no encoding work — and reconnects with backoff if wayvnc restarts. It connects
`shared`, so a real viewer can join alongside it. `compositor.sh status` reports
it as `seat holder: attached`.

Check with `compositor.sh status`; look for `seat0: capabilities=… [pointer,…]`.
To attach wayvnc + holder to a compositor already started without `--vnc`:
`compositor.sh vnc`.

The alternative, if you would rather not run wayvnc, is `wlrctl` — keep a
`wlrctl pointer` client alive for the same effect (but then `scroll` and `drag`
have no transport; see next). Keyboard capability also appears on its own
whenever `wtype` runs.

### Two gestures sway IPC simply cannot do: the wheel, and drags

Both are real limitations of `swaymsg seat … cursor`, measured on **sway 1.12**
against two unrelated clients (a terminal emulator and a WebKitGTK webview), and
both are routed through wayvnc's virtual pointer instead (`vnc-pointer.py`).
`ui.sh scroll` and `ui.sh drag` therefore *require* `--vnc`; they fail with a
clear message if wayvnc is not listening.

* **Wheel.** `seat <s> cursor press button4|button5` answers `{"success":
  true}` and sends nothing usable: sway resolves those names to its internal
  `SWAY_SCROLL_UP`/`SWAY_SCROLL_DOWN` pseudo-codes, which exist so that
  `bindsym button4 …` can match, and `cursor press` pushes the pseudo-code down
  the ordinary button path. No `wl_pointer.axis` is emitted at all. Neither
  client moved a single line at any notch count.
* **Motion while a button is held.** `cursor set` and `cursor move` only
  *rebase* the pointer, and `seatop_down` — the seat operation active for as
  long as a button is pressed on a client surface — implements no rebase
  handler, so the motion is dropped. The client sees press and release at the
  same pixel. A drag built out of `press` + warps therefore does nothing;
  `ui.sh press`/`ui.sh release` are only good for press-and-release-in-place.

`ui.sh scroll N` (positive `N` scrolls down/away) and `ui.sh drag X1 Y1 X2 Y2`
both work correctly through the wayvnc path. The keyboard fallback is
`ui.sh keyscroll N` (`Page_Down`/`Page_Up` via `wtype`), which needs *keyboard*
focus, so `click` inside the pane first; it does not depend on wayvnc.

### A bare warp does not trigger hover

`ui.sh warp` deliberately does `cursor set` → `cursor move 2 0` → `cursor set`
again. The relative move is what produces the pointer motion event a client
needs to update hover state and fire `pointermove`. Every command that takes
optional coordinates (`click`, `scroll`, …) warps this way too. If you drive
sway IPC yourself, replicate the jiggle.

### Coordinate 0 is special

sway-input(5) documents `seat … cursor set` as *ignoring* a coordinate given as
`0` (it means "leave this axis unchanged"), so `ui.sh` clamps everything to
`>= 1`. If you need the very top-left, use `1 1`.

### No live cursor position over IPC

sway's `get_seats` does not report where the cursor is. `ui.sh cursorpos` prints
the last position *this script* warped to. To see the truth, take
`ui.sh shot --cursor /tmp/c.png`.

### Overlay scrollbars move when hovered (WebKit-specific, but instructive)

A WebKitGTK overlay scrollbar is an indicator ~1px wide until the pointer is
over it, at which point it expands to a ~7px-wide thumb several pixels to the
left. Measure the thumb from a screenshot taken *while hovering the scrollbar*
(`ui.sh warp` onto it first), or a `drag` aimed at un-hovered coordinates will
miss. GTK and Qt overlay scrollbars behave similarly. The same "measure it in
the state you will click it in" rule applies to any hover-reactive target.

### A dev-server file watcher will reload the app under you

If the app under test is served by a dev server with a file watcher (Vite,
webpack, `cargo watch`, …), editing **any** watched file mid-run reloads the app
and throws away its state — the SPA route resets, the view you navigated to is
gone. The watcher root is usually the whole project, so this includes the
harness scripts themselves if you vendored them inside the watched tree, and it
includes anything else that rewrites build output concurrently (a second build,
a linter that regenerates config, a review tool). Finish your edits *before*
starting a navigation sequence, or re-navigate afterwards.

### `E2E_APP_PORT`: singleton dev-server ports

Dev servers configured with a fixed, non-negotiable port (Vite's
`strictPort: true`, for instance) are machine-wide singletons: a second instance
anywhere — including one the user started by hand — makes the run fail in
confusing ways. Set `E2E_APP_PORT=<port>` and `app.sh start` refuses up front
with the port owner printed, while `app.sh stop` waits for the port to clear
before returning. Leave it unset for apps with no such constraint.

### wayvnc binds `::1` only

`localhost` resolves to IPv6 first and wayvnc binds exactly one address, so a
client hardcoded to `127.0.0.1` gets `ECONNREFUSED`. Use the name `localhost`
(or `[::1]:5910`); set `E2E_VNC_HOST=127.0.0.1` if you need the v4 address.

### The ext-image-copy-capture error in `wayvnc.log` is benign

`ERROR: … ext-image-copy-capture.c: … No supported buffer formats were found` is
wayvnc trying the newer `ext-image-copy-capture` protocol first, failing on this
headless output, and falling back to `wlr-screencopy`. Framebuffer updates do
arrive. `grim` (`ui.sh shot`) uses `wlr-screencopy` directly and is unaffected
either way.

### Blank, garbled, or non-starting renderer

In order, for a WebKitGTK-based app:

```sh
WEBKIT_DISABLE_DMABUF_RENDERER=1 ./app.sh start
WEBKIT_DISABLE_DMABUF_RENDERER=1 WEBKIT_DISABLE_COMPOSITING_MODE=1 ./app.sh start
```

And if sway itself fails to initialise its renderer (headless wlroots still
opens a render node, and GL init can fail):

```sh
E2E_WLR_RENDERER=pixman ./compositor.sh start --vnc
```

### `app_id` mismatch

`app.sh` waits for an exact `app_id` match. On timeout it prints **every window
it can see** on the E2E compositor — read the list, then set `E2E_APP_ID` to the
one you meant. `E2E_APP_ID` is used by `app.sh` and by the rendered sway config
(fullscreen rule) alike, so it is worth getting right. Leave it unset to accept
any window.

### Stale state

`compositor.sh stop` removes the pidfiles and the `wayland-e2e` symlink; it is
the right cleanup even after a run was killed hard. `compositor.sh start`
refuses to run on top of a live pid rather than leaving two compositors around.

## Watching it live

```sh
./compositor.sh start --vnc
vncviewer localhost:5910        # or wlvncc / remmina / any VNC client
```

Connecting a viewer is the quickest way to sanity-check that the app is
rendering at all, and it coexists with the seat holder.

## Implementation notes

* **sway ignores `WAYLAND_DISPLAY`** for its own socket name — it picks the
  first free `wayland-1`..`wayland-32` itself. `compositor.sh` starts sway with
  `-V`, scrapes the chosen name out of the log (`Running compositor on wayland
  display '…'`), and symlinks `$XDG_RUNTIME_DIR/wayland-e2e` onto it, so
  everything downstream uses the stable name `WAYLAND_DISPLAY=wayland-e2e`.
* **sway's IPC socket** is `$XDG_RUNTIME_DIR/sway-ipc.<uid>.<pid>.sock`, derived
  purely from the compositor pid. `compositor.sh` records it and `swaymsg_e2e`
  runs `SWAYSOCK=<recorded> swaymsg …`, so the harness can never accidentally
  talk to another compositor — including the user's.
* **The compositor child gets `DISPLAY`, `WAYLAND_DISPLAY` and `SWAYSOCK`
  unset**, plus `WLR_BACKENDS=headless` and `WLR_LIBINPUT_NO_DEVICES=1`, so
  wlroots cannot pick the X11 or nested-Wayland backend and end up drawing on
  the real desktop, and cannot take over real input devices.
* **`xwayland disable`** in the config: no X server is pulled in and `DISPLAY`
  stays meaningless inside the session.
* **sway configs cannot expand environment variables**, hence the template plus
  `sed` render into `$E2E_RUNTIME_DIR`. Set `E2E_SWAY_CONFIG=<file>` to bypass
  templating and use a config of your own verbatim.
* `seat … cursor` is marked deprecated in sway-input(5) in favour of the
  virtual-pointer protocol. It still works and needs no extra tooling; if it
  ever stops, `wlrctl pointer` is the drop-in replacement to reach for (and
  `vnc-pointer.py` already shows the virtual-pointer path).

## Adopting into a project

Two ways:

1. **Use the skill's scripts in place**, driving them entirely with env vars.
   Good for one-off investigations and for driving somebody else's app:
   ```sh
   export E2E_RUNTIME_DIR=~/.cache/myapp-e2e E2E_APP_ID=myapp \
          E2E_APP_CWD=~/src/myapp E2E_APP_CMD='cargo run'
   ```
2. **Vendor them into the repo** (e.g. `scripts/e2e/`) when the project wants a
   pinned, self-contained harness with the app's own command, app_id, port and
   window geometry baked into defaults, checked in and reviewable alongside the
   code. Copy all seven files, edit the defaults in `env.sh`, and note in the
   project README that the copy diverged from this skill.

Provenance: verified 2026-08/2026-09 on Arch Linux, sway 1.12, wayvnc 0.10.1.
Smoke-tested end to end against `foot`; originally developed driving a
Tauri/WebKitGTK desktop app.
