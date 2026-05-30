#!/bin/bash
# Apple Intelligence MCP Server - start (launchd)
#
# If the hermes integration is installed, the watchdog is started too.

PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_MCP="$PLIST_DIR/com.apple-intel-mcp.server.plist"
PLIST_WATCHDOG="$PLIST_DIR/com.apple-intel-mcp.hermes-watchdog.plist"
DOMAIN="gui/$(id -u)"
MCP_TARGET="${DOMAIN}/com.apple-intel-mcp.server"
WATCHDOG_TARGET="${DOMAIN}/com.apple-intel-mcp.hermes-watchdog"

if [ ! -f "$PLIST_MCP" ]; then
    echo "❌ MCP launchd plist not found. Run ./install.sh first."
    exit 1
fi

if ! launchctl print "$MCP_TARGET" >/dev/null 2>&1; then
    launchctl bootstrap "$DOMAIN" "$PLIST_MCP"
    echo "✅ MCP Server started"
else
    echo "ℹ️  MCP Server is already running"
fi

if [ -f "$PLIST_WATCHDOG" ]; then
    if ! launchctl print "$WATCHDOG_TARGET" >/dev/null 2>&1; then
        launchctl bootstrap "$DOMAIN" "$PLIST_WATCHDOG"
        echo "✅ Hermes watchdog started"
    else
        echo "ℹ️  Hermes watchdog is already running"
    fi
fi

echo "   MCP endpoint: http://127.0.0.1:11435/mcp"
echo "   Logs: tail -f /tmp/apple-intel-mcp.log"
