#!/bin/bash
# ============================================================
# Apple Intelligence MCP - agent lifecycle integration
#
# Installs one launchd watchdog that drives MCP from the agent gateways listed
# in bin/mcp-watchdog.sh (hermes / openclaw). After install:
#   - any gateway start    -> MCP starts   (within 3 seconds)
#   - gateway restarts     -> MCP stays up; the gateway reconnects
#   - all gateways stopped -> MCP stops    (within 3 seconds)
#
# This script only installs the watchdog; run ./install.sh first to install MCP itself.
# ============================================================

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_MCP="$PLIST_DIR/com.apple-intel-mcp.server.plist"
PLIST_WATCHDOG="$PLIST_DIR/com.apple-intel-mcp.watchdog.plist"
WATCHDOG_DIR="$HOME/Library/Application Support/apple-intel-mcp"
WATCHDOG_SCRIPT="$WATCHDOG_DIR/mcp-watchdog.sh"
DOMAIN="gui/$(id -u)"
WATCHDOG_TARGET="${DOMAIN}/com.apple-intel-mcp.watchdog"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

[ -f "$PLIST_MCP" ] || error "MCP launchd plist not found. Run ./install.sh first."
[ -f "$REPO_DIR/bin/mcp-watchdog.sh" ] || error "Watchdog source not found: $REPO_DIR/bin/mcp-watchdog.sh"

[ -f "$PLIST_DIR/ai.hermes.gateway.plist" ] || [ -f "$PLIST_DIR/ai.openclaw.gateway.plist" ] \
    || warn "No hermes/openclaw gateway plist found. The watchdog installs anyway but does nothing until a gateway runs."

# Migrate: remove any older per-agent watchdogs so we don't run old + new together.
for OLD in com.apple-intel-mcp.hermes-watchdog com.apple-intel-mcp.openclaw-watchdog; do
    if launchctl print "${DOMAIN}/${OLD}" >/dev/null 2>&1; then
        launchctl bootout "${DOMAIN}/${OLD}" 2>/dev/null || true
        warn "Removed legacy watchdog: ${OLD}"
    fi
    rm -f "$PLIST_DIR/${OLD}.plist"
done
rm -f "$WATCHDOG_DIR/hermes-watchdog.sh" "$WATCHDOG_DIR/openclaw-watchdog.sh"

# 1. Copy the watchdog script into $HOME
#    (launchd running shell scripts from /Volumes is blocked by TCC.)
mkdir -p "$WATCHDOG_DIR"
cp "$REPO_DIR/bin/mcp-watchdog.sh" "$WATCHDOG_SCRIPT"
chmod +x "$WATCHDOG_SCRIPT"
info "Watchdog script installed at $WATCHDOG_SCRIPT"

# 2. Write the plist
cat > "$PLIST_WATCHDOG" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.apple-intel-mcp.watchdog</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${WATCHDOG_SCRIPT}</string>
    </array>
    <key>StartInterval</key>
    <integer>3</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/apple-intel-mcp.watchdog.log</string>
</dict>
</plist>
EOF
info "Watchdog plist written"

# 3. bootstrap
launchctl bootout "$WATCHDOG_TARGET" 2>/dev/null || true
if launchctl bootstrap "$DOMAIN" "$PLIST_WATCHDOG" &&
   launchctl print "$WATCHDOG_TARGET" >/dev/null 2>&1; then
    info "Watchdog started (keeps MCP alive while hermes/openclaw is running)"
else
    error "Watchdog failed to start"
fi

echo ""
echo "Done. MCP now stays up while any agent gateway is running."
echo "Watchdog logs: tail -f /tmp/apple-intel-mcp.watchdog.log"
echo "Remove integration: ./uninstall-integration.sh"
