---
name: gtk4-e2e-testing-atspi
description: Use when setting up end-to-end testing for GTK4 applications with headless Xvfb, capturing screenshots, and extracting accessibility tree hierarchies for AI-powered UI automation.
---

# GTK4 E2E Testing with AT-SPI

## Overview

Complete workflow for testing GTK4/Relm4/libadwaita applications in headless environments using Xvfb, AT-SPI accessibility, and screenshot capture. Enables AI models to understand UI structure and interact with applications programmatically.

## When to Use

Use when:
- Testing GTK4 applications without a physical display
- Need to capture screenshots for visual regression testing
- Want to extract UI hierarchy for AI automation
- Setting up CI/CD for GUI applications
- Debugging UI elements programmatically

Do not use when:
- Testing command-line only applications
- Using native Wayland compositors (this is X11/Xvfb specific)

## Prerequisites

```bash
# Arch Linux
sudo pacman -S xorg-server-xvfb fluxbox dbus at-spi2-core python-gobject xorg-xwd imagemagick

# The AT-SPI registry daemon
/usr/lib/at-spi2-registryd  # usually installed with at-spi2-core
```

## Core Setup

### 1. Isolated Environment Structure

The key is isolation via `dbus-run-session`:

```bash
#!/bin/bash
set -e

# Cleanup first
pkill -9 Xvfb fluxbox at-spi wordspace 2>/dev/null || true
rm -f /tmp/.X99-lock /tmp/.X100-lock

# 1. Start Xvfb (no D-Bus yet)
export DISPLAY=:100
Xvfb :100 -screen 0 1920x1080x24 -ac -noreset &
XVFB_PID=$!
sleep 2

# 2. Everything else inside dbus-run-session
dbus-run-session -- bash -c '
  export DISPLAY=:100
  
  # Start AT-SPI bus
  /usr/lib/at-spi-bus-launcher --launch-immediately &
  sleep 2
  
  # CRITICAL: Start registry daemon too
  /usr/lib/at-spi2-registryd &
  sleep 2
  
  # Start window manager
  fluxbox &
  sleep 2
  
  # Run your app
  ./target/debug/your-gtk-app &
  sleep 8
  
  # Now AT-SPI works!
  python3 dump-atspi-tree.py --app-name your-app
'

kill $XVFB_PID
```

### 2. Critical Environment Variables

```bash
# Must unset Wayland to force X11 backend
unset WAYLAND_DISPLAY

# DISPLAY set by you (e.g., :100)
export DISPLAY=:100

# D-Bus session address set automatically by dbus-run-session
# AT-SPI bus address queried via busctl
```

## Quick Commands

| Task | Command |
|------|---------|
| Screenshot window | `xwd -id <window_id> -out shot.xwd` |
| Screenshot root | `xwd -root -out shot.xwd` |
| Convert to PNG | `magick shot.xwd shot.png` |
| Find window ID | `xwininfo -root -tree \| grep "AppName"` |
| List accessible apps | `python3 -c "from gi.repository import Atspi; print([a.get_name() for a in Atspi.get_desktop(0).get_children()])"` |
| Verify AT-SPI | `busctl --user status org.a11y.Bus` |
| Verify Registry | `busctl --user status org.a11y.atspi.Registry` |

## Python AT-SPI Example

```python
import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi

# Get desktop
desktop = Atspi.get_desktop(0)

# List all applications
for i in range(desktop.get_child_count()):
    app = desktop.get_child_at_index(i)
    print(f"App: {app.get_name()}")
    
    # Walk tree recursively
    def dump_tree(node, depth=0):
        name = node.get_name() or "(unnamed)"
        role = node.get_role_name()
        print(f"{'  ' * depth}[{role}] {name}")
        
        for j in range(node.get_child_count()):
            child = node.get_child_at_index(j)
            dump_tree(child, depth + 1)
    
    dump_tree(app)
```

## Common Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| Black screenshot | No window manager | Start fluxbox |
| AT-SPI "Registry not found" | Missing registry daemon | Run `/usr/lib/at-spi2-registryd` |
| App uses Wayland | WAYLAND_DISPLAY set | `unset WAYLAND_DISPLAY` |
| "No DRI3" warnings | Headless GPU | Ignore, software rendering works |
| Window not in AT-SPI tree | Registry not running | Check `busctl --user status org.a11y.atspi.Registry` |

## AI Integration Workflow

1. **Start Environment**
   ```bash
   ./atspi-xvfb-setup.sh "./your-app"
   ```

2. **Dump Tree for AI**
   ```bash
   python3 dump-atspi-tree.py --app-name YourApp --format json > ui_tree.json
   ```

3. **AI Decision Loop**
   ```
   Screenshot → AI analyzes image + tree → AI decides action → 
   AT-SPI click or xdotool click → Screenshot → verify
   ```

4. **Click via AT-SPI**
   ```python
   button = find_node_by_name(app, "Import Media")
   button.do_action(0)  # First action is usually "click"
   ```

## Files Reference

- `atspi-xvfb-setup.sh` - Full setup script with error handling
- `dump-atspi-tree.py` - Tree dumper with text/JSON/XML output
- `ATSPI_SETUP_GUIDE.md` - Detailed technical documentation
- `ATSPI_WORDSPACE_USAGE.md` - Project-specific examples

## Example: Complete Test

```bash
#!/bin/bash
unset WAYLAND_DISPLAY

# 1. Setup
Xvfb :100 -screen 0 1920x1080x24 -ac &
sleep 2

# 2. Run in isolated dbus
dbus-run-session -- bash -c '
  export DISPLAY=:100
  /usr/lib/at-spi-bus-launcher --launch-immediately &
  /usr/lib/at-spi2-registryd &
  fluxbox &
  sleep 2
  
  ./wordspace-gtk &
  sleep 8
  
  # Verify AT-SPI
  python3 -c "
import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi
desktop = Atspi.get_desktop(0)
for i in range(desktop.get_child_count()):
    app = desktop.get_child_at_index(i)
    print(f\"Found: {app.get_name()}\")
  "
  
  # Screenshot
  xwd -root -out /tmp/test.xwd
  magick /tmp/test.xwd /tmp/test.png
  echo "Screenshot: /tmp/test.png"
'

# Cleanup
pkill Xvfb
```

## Key Insights

1. **dbus-run-session is critical** - Provides isolated D-Bus for AT-SPI
2. **Both daemons needed** - `at-spi-bus-launcher` AND `at-spi2-registryd`
3. **Timing matters** - Wait 2-3 seconds between each service startup
4. **X11 only** - Must unset WAYLAND_DISPLAY to force X11 backend
5. **Fluxbox essential** - Without window manager, windows don't map properly

## Troubleshooting

Check services are running:
```bash
busctl --user list | grep -E "(a11y|atspi)"
```

Should show:
- `org.a11y.Bus` (bus launcher)
- `org.a11y.atspi.Registry` (registry daemon)

If missing, the app won't expose accessibility info.
