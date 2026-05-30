#!/bin/bash
# ============================================================
# Apple Intelligence MCP - Hermes lifecycle integration
#
# After installation, hermes gateway start/stop/restart automatically drives MCP:
#   - uses a lightweight launchd watchdog (checks hermes every 3 seconds)
#   - hermes stopped -> bootout mcp
#   - hermes started -> bootstrap mcp
#   - hermes restart (PID changed) -> kickstart -k mcp
#
# This script only installs the watchdog; run ./install.sh first to install MCP itself.
# ============================================================

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_MCP="$PLIST_DIR/com.apple-intel-mcp.server.plist"
PLIST_WATCHDOG="$PLIST_DIR/com.apple-intel-mcp.hermes-watchdog.plist"
PLIST_HERMES="$PLIST_DIR/ai.hermes.gateway.plist"
# The watchdog script must live under $HOME; launchd running shell scripts from /Volumes is blocked by TCC.
WATCHDOG_DIR="$HOME/Library/Application Support/apple-intel-mcp"
WATCHDOG_SCRIPT="$WATCHDOG_DIR/hermes-watchdog.sh"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

[ -f "$PLIST_MCP" ] || error "MCP launchd plist not found. Run ./install.sh first."
[ -f "$PLIST_HERMES" ] || warn "ai.hermes.gateway.plist not found. The watchdog will still be installed, but will do nothing until hermes is running."
[ -f "$REPO_DIR/bin/hermes-watchdog.sh" ] || error "Watchdog source not found: $REPO_DIR/bin/hermes-watchdog.sh"

# 1. Copy the watchdog script into $HOME
mkdir -p "$WATCHDOG_DIR"
cp "$REPO_DIR/bin/hermes-watchdog.sh" "$WATCHDOG_SCRIPT"
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
    <string>com.apple-intel-mcp.hermes-watchdog</string>
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
    <string>/tmp/apple-intel-mcp.hermes-watchdog.log</string>
</dict>
</plist>
EOF
info "Watchdog plist written"

# 3. bootstrap
DOMAIN="gui/$(id -u)"
TARGET="${DOMAIN}/com.apple-intel-mcp.hermes-watchdog"
launchctl bootout "$TARGET" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST_WATCHDOG"
info "Watchdog started (syncs MCP with ai.hermes.gateway every 3 seconds)"

echo ""
echo "Done. Try:"
echo "  hermes gateway stop    # MCP stops within 3 seconds"
echo "  hermes gateway start   # MCP starts within 3 seconds"
echo "  hermes gateway restart # MCP restarts within 3 seconds"
echo ""
echo "Watchdog logs: tail -f /tmp/apple-intel-mcp.hermes-watchdog.log"
echo "Remove integration: ./uninstall-hermes-integration.sh"
