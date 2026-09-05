#!/bin/bash
# Apple Intelligence MCP Server - uninstall script

set -e

PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_MCP="$PLIST_DIR/com.apple-intel-mcp.server.plist"
PLIST_SWIFT="$PLIST_DIR/com.apple-intel-mcp.swift-core.plist"

echo "Uninstalling Apple Intelligence MCP Server..."

DOMAIN="gui/$(id -u)"
# Boot out the watchdog first so it does not bring MCP back.
# (current unified label + legacy per-agent labels.)
for L in com.apple-intel-mcp.watchdog com.apple-intel-mcp.hermes-watchdog com.apple-intel-mcp.openclaw-watchdog; do
    launchctl bootout "${DOMAIN}/${L}" 2>/dev/null && echo "Watchdog ${L} stopped" || true
    rm -f "$PLIST_DIR/${L}.plist"
done
launchctl bootout "${DOMAIN}/com.apple-intel-mcp.server" 2>/dev/null && echo "MCP Server stopped" || true
launchctl bootout "${DOMAIN}/com.apple-intel-mcp.swift-core" 2>/dev/null || true
# Also handle leftovers from legacy load.
launchctl unload "$PLIST_MCP" 2>/dev/null || true
launchctl unload "$PLIST_SWIFT" 2>/dev/null || true

rm -f "$PLIST_MCP" "$PLIST_SWIFT"
rm -rf "$HOME/Library/Application Support/apple-intel-mcp"
rm -f /tmp/apple-intel-mcp.manual-start
rm -f /tmp/apple-intel-mcp.watchdog-pids /tmp/apple-intel-mcp.hermes-pid /tmp/apple-intel-mcp.openclaw-pid
rm -f /tmp/apple-intel-mcp.watchdog.log /tmp/apple-intel-mcp.hermes-watchdog.log /tmp/apple-intel-mcp.openclaw-watchdog.log
echo "launchd configuration removed"
echo ""
echo "Done. Delete the project directory manually if needed."
