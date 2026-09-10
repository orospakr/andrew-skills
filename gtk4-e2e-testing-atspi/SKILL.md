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

### 1. Quick Start (Parameterized)

The fastest way - use environment variables to customize without editing:

```bash
#!/bin/bash
set -e

# Configuration (set these or pass as env vars)
APP_NAME="${APP_NAME:-myapp}"           # Your GTK4 app name
APP_PATH="${APP_PATH:-./myapp}"       # Path to your app binary
DISPLAY_NUM="${DISPLAY_NUM:-100}"     # X11 display number
WAIT_TIME="${WAIT_TIME:-8}"           # Seconds to wait for app startup

# Cleanup
pkill -9 Xvfb fluxbox at-spi "$APP_NAME" 2>/dev/null || true
rm -f "/tmp/.X${DISPLAY_NUM}-lock"

# Start Xvfb
export DISPLAY=":${DISPLAY_NUM}"
Xvfb ":${DISPLAY_NUM}" -screen 0 1920x1080x24 -ac -noreset &
sleep 2

# Run in isolated D-Bus session
dbus-run-session -- bash -c "
  export DISPLAY=:${DISPLAY_NUM}
  
  # Start AT-SPI services
  /usr/lib/at-spi-bus-launcher --launch-immediately &
  /usr/lib/at-spi2-registryd &
  fluxbox &
  sleep 2
  
  # Run the app
  \${APP_PATH} &
  sleep \${WAIT_TIME}
  
  # Dump accessibility tree
  python3 dump-atspi-tree.py --app-name '\${APP_NAME}' --format json
"
```

**Usage:**
```bash
# Quick test with defaults
./atspi-test.sh

# Test specific app
APP_NAME="MyApp" APP_PATH="./target/debug/my-app" ./atspi-test.sh

# Different display, longer wait
DISPLAY_NUM=99 WAIT_TIME=12 ./atspi-test.sh
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

## Automation Patterns (No Script Rewriting)

The `dump-atspi-tree.py` script is designed to be used as-is. Here are common patterns:

### Pattern 1: Shell Script Wrapper
Create a one-liner that configures everything:

```bash
#!/bin/bash
cd /path/to/your/project
export APP_NAME="YourApp"
export APP_PATH="./target/debug/your-app"

# Run the generic test
/path/to/gtk4-e2e-testing-atspi/atspi-xvfb-setup.sh "$APP_PATH"
```

### Pattern 2: Python Automation (Using the Script)
Call the tree dumper from your Python automation:

```python
import subprocess
import json

def get_accessibility_tree(app_name):
    """Get accessibility tree without rewriting the script"""
    result = subprocess.run(
        ['python3', 'dump-atspi-tree.py', '--app-name', app_name, '--format', 'json'],
        capture_output=True,
        text=True
    )
    if result.returncode == 0:
        return json.loads(result.stdout)
    return None

def click_button_via_atspi(app_name, button_name):
    """Click a button by name using AT-SPI"""
    script = f'''
import gi
gi.require_version("Atspi", "2.0")
from gi.repository import Atspi

def click(node_name):
    desktop = Atspi.get_desktop(0)
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        if "{app_name}".lower() in (app.get_name() or "").lower():
            def find(node, depth=0):
                if node_name.lower() in (node.get_name() or "").lower():
                    node.do_action(0)
                    return True
                for j in range(node.get_child_count()):
                    if find(node.get_child_at_index(j), depth+1):
                        return True
                return False
            if find(app):
                print("clicked")
                return
click("{button_name}")
'''
    subprocess.run(['python3', '-c', script])
```

### Pattern 3: Makefile Integration

```makefile
ATSPI_DIR := /path/to/gtk4-e2e-testing-atspi

# Run tests against your app
test-ui:
	APP_NAME="MyApp" APP_PATH="./target/debug/my-app" \
	  $(ATSPI_DIR)/atspi-xvfb-setup.sh

# Get tree dump
dump-tree:
	python3 $(ATSPI_DIR)/dump-atspi-tree.py --app-name "MyApp" --format json
```

### Pattern 4: CI/CD (GitHub Actions Example)

```yaml
- name: Test GTK4 UI
  run: |
    export APP_NAME="MyApp"
    export APP_PATH="./target/debug/my-app"
    export DISPLAY_NUM=99
    
    # Copy scripts
    cp /path/to/gtk4-e2e-testing-atspi/*.py .
    
    # Run tests
    APP_NAME="$APP_NAME" APP_PATH="$APP_PATH" ./atspi-xvfb-setup.sh
    
    # Capture artifacts
    python3 dump-atspi-tree.py --app-name "$APP_NAME" --format json --output tree.json
    xwd -root -out screenshot.xwd
  env:
    APP_NAME: MyApp
    APP_PATH: ./target/debug/my-app
```

### Key Principle

**Never rewrite the scripts** - pass configuration via:
1. Environment variables (`APP_NAME`, `APP_PATH`, `DISPLAY_NUM`)
2. Command-line arguments (`--app-name`, `--format`, `--output`)
3. Shell variables in your wrapper scripts

| Symptom | Cause | Fix |
|---------|-------|-----|
| Black screenshot | No window manager | Start fluxbox |
| AT-SPI "Registry not found" | Missing registry daemon | Run `/usr/lib/at-spi2-registryd` |
| App uses Wayland | WAYLAND_DISPLAY set | `unset WAYLAND_DISPLAY` |
| "No DRI3" warnings | Headless GPU | Ignore, software rendering works |
| Window not in AT-SPI tree | Registry not running | Check `busctl --user status org.a11y.atspi.Registry` |

## AI Integration Workflow

1. **Start Environment** (pass app dynamically)
   ```bash
   APP_NAME="YourApp" APP_PATH="./your-app" ./atspi-xvfb-setup.sh
   ```

2. **Dump Tree for AI** (generic - any app name)
   ```bash
   # Auto-detect the app name from running apps
   python3 dump-atspi-tree.py --format json > ui_tree.json
   
   # Or specify explicitly
   python3 dump-atspi-tree.py --app-name "$APP_NAME" --format json > ui_tree.json
   ```

3. **AI Decision Loop**
   ```
   Screenshot → AI analyzes image + tree → AI decides action → 
   AT-SPI click or xdotool click → Screenshot → verify
   ```

4. **Click via AT-SPI** (works with any accessible button)
   ```python
   # In your automation script
   import subprocess
   result = subprocess.run(
       ['python3', '-c', '''
import gi
gi.require_version("Atspi", "2.0")
from gi.repository import Atspi

def find_and_click(app_name, button_name):
    desktop = Atspi.get_desktop(0)
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        if app_name.lower() in (app.get_name() or "").lower():
            def find_button(node, depth=0):
                if button_name.lower() in (node.get_name() or "").lower():
                    return node
                for j in range(node.get_child_count()):
                    child = node.get_child_at_index(j)
                    result = find_button(child, depth+1)
                    if result:
                        return result
                return None
            button = find_button(app)
            if button:
                button.do_action(0)  # Click
                return True
    return False

find_and_click("'" + app_name + "'", "'" + button_name + "'")
       '''],
       capture_output=True
   )
   '''])
   ```

## Files Reference

- `atspi-xvfb-setup.sh` - Full setup script with error handling
- `dump-atspi-tree.py` - Tree dumper with text/JSON/XML output
- `ATSPI_SETUP_GUIDE.md` - Detailed technical documentation
- `ATSPI_MYAPP_USAGE.md` - Project-specific examples

## Example: Complete Test

```bash
#!/bin/bash

# Configuration via environment variables
APP_NAME="${APP_NAME:-myapp}"
APP_PATH="${APP_PATH:-./myapp}"
DISPLAY_NUM="${DISPLAY_NUM:-100}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp}"

unset WAYLAND_DISPLAY

# 1. Setup
export DISPLAY=":${DISPLAY_NUM}"
Xvfb ":${DISPLAY_NUM}" -screen 0 1920x1080x24 -ac &
sleep 2

# 2. Run in isolated dbus
dbus-run-session -- bash -c "
  export DISPLAY=:${DISPLAY_NUM}
  /usr/lib/at-spi-bus-launcher --launch-immediately &
  /usr/lib/at-spi2-registryd &
  fluxbox &
  sleep 2
  
  \${APP_PATH} &
  sleep 8
  
  # Verify AT-SPI - list all apps
  python3 -c '
import gi
gi.require_version(\"Atspi\", \"2.0\")
from gi.repository import Atspi
desktop = Atspi.get_desktop(0)
for i in range(desktop.get_child_count()):
    app = desktop.get_child_at_index(i)
    print(f\"Found: {app.get_name()}\")
  '
  
  # Screenshot and tree dump
  xwd -root -out ${OUTPUT_DIR}/test.xwd
  magick ${OUTPUT_DIR}/test.xwd ${OUTPUT_DIR}/test.png
  python3 dump-atspi-tree.py --app-name '\${APP_NAME}' --format json --output ${OUTPUT_DIR}/tree.json
"

# Cleanup
pkill -9 Xvfb

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
