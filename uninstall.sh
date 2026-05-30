#!/bin/bash
# Apple Intelligence MCP Server - uninstall script

set -e

PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_MCP="$PLIST_DIR/com.apple-intel-mcp.server.plist"
PLIST_SWIFT="$PLIST_DIR/com.apple-intel-mcp.swift-core.plist"
PLIST_WATCHDOG="$PLIST_DIR/com.apple-intel-mcp.hermes-watchdog.plist"

echo "Uninstalling Apple Intelligence MCP Server..."

DOMAIN="gui/$(id -u)"
# Boot out the watchdog first so it does not bring MCP back.
launchctl bootout "${DOMAIN}/com.apple-intel-mcp.hermes-watchdog" 2>/dev/null && echo "Watchdog stopped" || true
launchctl bootout "${DOMAIN}/com.apple-intel-mcp.server" 2>/dev/null && echo "MCP Server stopped" || true
launchctl bootout "${DOMAIN}/com.apple-intel-mcp.swift-core" 2>/dev/null || true
# Also handle leftovers from legacy load.
launchctl unload "$PLIST_MCP" 2>/dev/null || true
launchctl unload "$PLIST_SWIFT" 2>/dev/null || true

rm -f "$PLIST_MCP" "$PLIST_SWIFT" "$PLIST_WATCHDOG"
rm -rf "$HOME/Library/Application Support/apple-intel-mcp"
rm -f /tmp/apple-intel-mcp.hermes-pid
echo "launchd configuration removed"
echo ""
echo "Done. Delete the project directory manually if needed."
