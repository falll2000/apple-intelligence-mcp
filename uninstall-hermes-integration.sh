#!/bin/bash
# ============================================================
# Remove hermes integration (keep MCP itself)
# ============================================================

set -e

PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_WATCHDOG="$PLIST_DIR/com.apple-intel-mcp.hermes-watchdog.plist"
WATCHDOG_DIR="$HOME/Library/Application Support/apple-intel-mcp"

DOMAIN="gui/$(id -u)"
launchctl bootout "${DOMAIN}/com.apple-intel-mcp.hermes-watchdog" 2>/dev/null && echo "Watchdog stopped" || echo "Watchdog was not running"

rm -f "$PLIST_WATCHDOG"
rm -rf "$WATCHDOG_DIR"
rm -f /tmp/apple-intel-mcp.hermes-pid /tmp/apple-intel-mcp.hermes-watchdog.log
echo "Watchdog configuration removed. MCP itself was not changed."
