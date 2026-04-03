#!/bin/bash
#
# AT-SPI / Xvfb E2E Testing Environment Setup Script
# 
# This script sets up an isolated environment for testing GTK4 applications
# with AT-SPI accessibility support in a headless Xvfb environment.
#
# Usage: ./atspi-xvfb-setup.sh [command_to_run]
#
# The script will:
# 1. Start an isolated D-Bus session bus
# 2. Start the AT-SPI bus launcher
# 3. Start Xvfb (virtual framebuffer)
# 4. Start a window manager (fluxbox)
# 5. Run the provided command or start an interactive shell
# 6. Clean up all processes on exit
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
XVFB_DISPLAY=${XVFB_DISPLAY:-:99}
XVFB_RESOLUTION=${XVFB_RESOLUTION:-1280x720x24}
FLUXBOX_CONFIG_DIR=$(mktemp -d)
LOG_DIR=$(mktemp -d)

# Process IDs for cleanup
XVFB_PID=""
FLUXBOX_PID=""
AT_SPI_PID=""
DBUS_PID=""

# Logging
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Cleanup function
cleanup() {
    log_info "Cleaning up..."
    
    # Kill processes in reverse order
    if [ -n "$FLUXBOX_PID" ] && kill -0 "$FLUXBOX_PID" 2>/dev/null; then
        log_info "Stopping fluxbox (PID: $FLUXBOX_PID)..."
        kill "$FLUXBOX_PID" 2>/dev/null || true
        wait "$FLUXBOX_PID" 2>/dev/null || true
    fi
    
    if [ -n "$XVFB_PID" ] && kill -0 "$XVFB_PID" 2>/dev/null; then
        log_info "Stopping Xvfb (PID: $XVFB_PID)..."
        kill "$XVFB_PID" 2>/dev/null || true
        wait "$XVFB_PID" 2>/dev/null || true
    fi
    
    if [ -n "$AT_SPI_PID" ] && kill -0 "$AT_SPI_PID" 2>/dev/null; then
        log_info "Stopping AT-SPI bus launcher (PID: $AT_SPI_PID)..."
        kill "$AT_SPI_PID" 2>/dev/null || true
        wait "$AT_SPI_PID" 2>/dev/null || true
    fi
    
    # Clean up temporary directories
    if [ -d "$FLUXBOX_CONFIG_DIR" ]; then
        rm -rf "$FLUXBOX_CONFIG_DIR"
    fi
    
    if [ -d "$LOG_DIR" ]; then
        rm -rf "$LOG_DIR"
    fi
    
    log_success "Cleanup complete"
}

# Set trap for cleanup on exit
trap cleanup EXIT INT TERM

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    local missing=()
    
    if ! command -v Xvfb &> /dev/null; then
        missing+=("Xvfb")
    fi
    
    if ! command -v fluxbox &> /dev/null; then
        missing+=("fluxbox")
    fi
    
    if ! command -v dbus-run-session &> /dev/null; then
        missing+=("dbus-run-session")
    fi
    
    if ! command -v /usr/lib/at-spi-bus-launcher &> /dev/null; then
        missing+=("at-spi-bus-launcher (at-spi2-core)")
    fi
    
    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing prerequisites: ${missing[*]}"
        log_info "Install on Arch Linux: sudo pacman -S xorg-server-xvfb fluxbox dbus at-spi2-core"
        exit 1
    fi
    
    log_success "All prerequisites found"
}

# Start Xvfb
start_xvfb() {
    log_info "Starting Xvfb on display $XVFB_DISPLAY..."
    
    # Check if display is already in use
    if [ -e "/tmp/.X${XVFB_DISPLAY#:}-lock" ]; then
        log_warn "Display $XVFB_DISPLAY may be in use, trying to find free display..."
        for i in {99..199}; do
            if [ ! -e "/tmp/.X$i-lock" ]; then
                XVFB_DISPLAY=":$i"
                log_info "Using display $XVFB_DISPLAY"
                break
            fi
        done
    fi
    
    # Start Xvfb
    Xvfb "$XVFB_DISPLAY" -screen 0 "$XVFB_RESOLUTION" +extension GLX +extension RANDR +extension RENDER +extension XINERAMA -ac -noreset -nolisten tcp > "$LOG_DIR/xvfb.log" 2>&1 &
    XVFB_PID=$!
    
    # Wait for Xvfb to be ready
    local attempts=0
    while [ $attempts -lt 30 ]; do
        if DISPLAY="$XVFB_DISPLAY" xset q &>/dev/null; then
            log_success "Xvfb started on $XVFB_DISPLAY (PID: $XVFB_PID)"
            return 0
        fi
        sleep 0.1
        ((attempts++))
    done
    
    log_error "Xvfb failed to start within timeout"
    cat "$LOG_DIR/xvfb.log"
    return 1
}

# Start fluxbox window manager
start_fluxbox() {
    log_info "Starting fluxbox window manager..."
    
    # Create minimal fluxbox config
    mkdir -p "$FLUXBOX_CONFIG_DIR/.fluxbox"
    cat > "$FLUXBOX_CONFIG_DIR/.fluxbox/init" << 'EOF'
session.screen0.workspaceCount: 1
session.screen0.workspacenames: Workspace 1
session.configVersion: 13
session.menuFile: /dev/null
session.keyFile: /dev/null
session.styleOverlay: /dev/null
session.style: 
EOF
    
    # Create apps file to auto-maximize windows (optional)
    cat > "$FLUXBOX_CONFIG_DIR/.fluxbox/apps" << 'EOF'
[app] (name=.*)
  [Maximized] {yes}
[end]
EOF
    
    HOME="$FLUXBOX_CONFIG_DIR" DISPLAY="$XVFB_DISPLAY" fluxbox > "$LOG_DIR/fluxbox.log" 2>&1 &
    FLUXBOX_PID=$!
    
    # Wait for fluxbox to be ready
    sleep 0.5
    
    if kill -0 "$FLUXBOX_PID" 2>/dev/null; then
        log_success "Fluxbox started (PID: $FLUXBOX_PID)"
        return 0
    else
        log_error "Fluxbox failed to start"
        cat "$LOG_DIR/fluxbox.log"
        return 1
    fi
}

# Start AT-SPI bus launcher
start_at_spi() {
    log_info "Starting AT-SPI bus launcher..."
    
    # Method 1: Using dbus-run-session to start at-spi-bus-launcher
    # This ensures the AT-SPI bus is properly connected to our isolated session bus
    
    # Note: at-spi-bus-launcher registers itself as org.a11y.Bus on the session bus
    # and provides the GetAddress method to get the accessibility bus address
    
    # First, ensure we have DBUS_SESSION_BUS_ADDRESS set
    if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        log_error "DBUS_SESSION_BUS_ADDRESS not set! D-Bus session bus not running?"
        return 1
    fi
    
    # Start the AT-SPI bus launcher
    # Use --launch-immediately to start the accessibility bus right away
    /usr/lib/at-spi-bus-launcher --launch-immediately > "$LOG_DIR/atspi.log" 2>&1 &
    AT_SPI_PID=$!
    
    # Wait for the AT-SPI bus to be ready
    local attempts=0
    while [ $attempts -lt 30 ]; do
        if busctl --user status org.a11y.Bus &>/dev/null; then
            log_success "AT-SPI bus launcher started (PID: $AT_SPI_PID)"
            
            # Get the accessibility bus address
            local at_spi_address
            at_spi_address=$(busctl --user call org.a11y.Bus /org/a11y/bus org.a11y.Bus GetAddress 2>/dev/null | tr -d 's ' || echo "")
            if [ -n "$at_spi_address" ]; then
                log_info "AT-SPI bus address: $at_spi_address"
                export AT_SPI_BUS="$at_spi_address"
            fi
            
            return 0
        fi
        sleep 0.1
        ((attempts++))
    done
    
    log_error "AT-SPI bus launcher failed to start within timeout"
    cat "$LOG_DIR/atspi.log"
    return 1
}

# Wait for a window to appear (useful for testing)
wait_for_window() {
    local window_name="${1:-}"
    local timeout="${2:-10}"
    
    log_info "Waiting for window${window_name:+: $window_name}..."
    
    local attempts=0
    while [ $attempts -lt $((timeout * 10)) ]; do
        if DISPLAY="$XVFB_DISPLAY" xdotool search --name ".*" &>/dev/null; then
            log_success "Window detected"
            return 0
        fi
        sleep 0.1
        ((attempts++))
    done
    
    log_warn "No window detected within ${timeout}s"
    return 1
}

# Main execution
main() {
    echo "=========================================="
    echo "AT-SPI / Xvfb E2E Testing Environment"
    echo "=========================================="
    
    check_prerequisites
    
    # Export display for all child processes
    export DISPLAY="$XVFB_DISPLAY"
    log_info "Using DISPLAY=$DISPLAY"
    
    # Start Xvfb first
    start_xvfb
    
    # Now use dbus-run-session to run everything in an isolated session
    # This is the key to having an isolated D-Bus environment
    log_info "Starting isolated D-Bus session..."
    
    # Build the command to run inside dbus-run-session
    local inner_command=""
    if [ $# -eq 0 ]; then
        # No command provided, start a shell
        inner_command="bash"
    else
        inner_command="$*"
    fi
    
    # Create the setup script that will run inside dbus-run-session
    local setup_script=$(mktemp)
    cat > "$setup_script" << SCRIPT_EOF
#!/bin/bash
set -e

# Export display
export DISPLAY="$DISPLAY"

# Start AT-SPI bus launcher
/usr/lib/at-spi-bus-launcher --launch-immediately &
AT_SPI_LAUNCHER_PID=\$!

# Wait for AT-SPI to be ready
for i in {1..50}; do
    if busctl --user status org.a11y.Bus &>/dev/null; then
        echo "[AT-SPI] Bus ready"
        break
    fi
    sleep 0.1
done

# Start fluxbox
export HOME="$FLUXBOX_CONFIG_DIR"
fluxbox &
FLUXBOX_PID=\$!
sleep 0.5

# Print environment info
echo ""
echo "========================================"
echo "Environment Ready"
echo "========================================"
echo "DISPLAY: \$DISPLAY"
echo "DBUS_SESSION_BUS_ADDRESS: \$DBUS_SESSION_BUS_ADDRESS"

# Get AT-SPI bus address
AT_SPI_BUS=\$(busctl --user call org.a11y.Bus /org/a11y/bus org.a11y.Bus GetAddress 2>/dev/null | tr -d 's ' || echo "")
echo "AT_SPI_BUS: \$AT_SPI_BUS"
echo ""

# Run the user command or interactive shell
$inner_command

# Cleanup
kill \$FLUXBOX_PID 2>/dev/null || true
kill \$AT_SPI_LAUNCHER_PID 2>/dev/null || true
SCRIPT_EOF
    
    chmod +x "$setup_script"
    
    # Run everything inside dbus-run-session for isolation
    log_info "Starting isolated D-Bus session with X environment..."
    dbus-run-session -- "$setup_script"
    
    # Cleanup the temp script
    rm -f "$setup_script"
    
    log_success "Test environment session complete"
}

# Run main
main "$@"
