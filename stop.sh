#!/bin/bash
# Apple Intelligence MCP Server - full stop (including watchdog)
#
# Normally `hermes gateway stop` is enough; the watchdog will stop MCP automatically.
# This script is an escape hatch that also stops the watchdog, for example when
# pausing MCP while hermes is still running.

DOMAIN="gui/$(id -u)"
MCP_TARGET="${DOMAIN}/com.apple-intel-mcp.server"
WATCHDOG_TARGET="${DOMAIN}/com.apple-intel-mcp.hermes-watchdog"

# Stop the watchdog first, otherwise it may bring MCP back.
if launchctl print "$WATCHDOG_TARGET" >/dev/null 2>&1; then
    launchctl bootout "$WATCHDOG_TARGET"
    echo "✅ Watchdog stopped"
fi

if launchctl print "$MCP_TARGET" >/dev/null 2>&1; then
    launchctl bootout "$MCP_TARGET"
    echo "✅ MCP Server stopped"
else
    echo "MCP Server was not running"
fi
