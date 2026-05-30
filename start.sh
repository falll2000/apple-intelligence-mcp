#!/bin/bash
# Apple Intelligence MCP Server - start (launchd)
#
# If the agent-gateway integration is installed, the watchdog is started too.

PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_MCP="$PLIST_DIR/com.apple-intel-mcp.server.plist"
PLIST_WATCHDOG="$PLIST_DIR/com.apple-intel-mcp.watchdog.plist"
PLIST_LEGACY_WATCHDOG="$PLIST_DIR/com.apple-intel-mcp.hermes-watchdog.plist"
DOMAIN="gui/$(id -u)"
MCP_TARGET="${DOMAIN}/com.apple-intel-mcp.server"
WATCHDOG_TARGET="${DOMAIN}/com.apple-intel-mcp.watchdog"
LEGACY_WATCHDOG_TARGET="${DOMAIN}/com.apple-intel-mcp.hermes-watchdog"

if [ ! -f "$PLIST_MCP" ]; then
    echo "❌ MCP launchd plist not found. Run ./install.sh first."
    exit 1
fi

if ! launchctl print "$MCP_TARGET" >/dev/null 2>&1; then
    if launchctl bootstrap "$DOMAIN" "$PLIST_MCP"; then
        echo "✅ MCP Server started"
    else
        echo "⚠️  MCP Server failed to start"
    fi
else
    echo "ℹ️  MCP Server is already running"
fi

if [ -f "$PLIST_WATCHDOG" ]; then
    if ! launchctl print "$WATCHDOG_TARGET" >/dev/null 2>&1; then
        if launchctl bootstrap "$DOMAIN" "$PLIST_WATCHDOG"; then
            echo "✅ Watchdog started"
        else
            echo "⚠️  Watchdog failed to start"
        fi
    else
        echo "ℹ️  Watchdog is already running"
    fi
elif [ -f "$PLIST_LEGACY_WATCHDOG" ]; then
    if ! launchctl print "$LEGACY_WATCHDOG_TARGET" >/dev/null 2>&1; then
        if launchctl bootstrap "$DOMAIN" "$PLIST_LEGACY_WATCHDOG"; then
            echo "✅ Legacy Hermes watchdog started"
        else
            echo "⚠️  Legacy Hermes watchdog failed to start"
        fi
    else
        echo "ℹ️  Legacy Hermes watchdog is already running"
    fi
fi

echo "   MCP endpoint: http://127.0.0.1:11435/mcp"
echo "   Logs: tail -f /tmp/apple-intel-mcp.log"
