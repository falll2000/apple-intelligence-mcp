#!/bin/bash
# Apple Intelligence MCP Server - full stop (including watchdog)
#
# Normally stopping all agent gateways is enough; the watchdog will stop MCP automatically.
# This script is an escape hatch that also stops the watchdog, for example when
# pausing MCP while a gateway is still running.

DOMAIN="gui/$(id -u)"
MCP_TARGET="${DOMAIN}/com.apple-intel-mcp.server"

# Drop the manual-start pin first, so the watchdog cannot read it as "keep MCP up".
rm -f /tmp/apple-intel-mcp.manual-start

wait_unloaded() {
    local target="$1"
    local tries=20
    while [ "$tries" -gt 0 ]; do
        if ! launchctl print "$target" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
        tries=$((tries - 1))
    done
    return 1
}

# Stop the watchdog first, otherwise it may bring MCP back.
for L in com.apple-intel-mcp.watchdog com.apple-intel-mcp.hermes-watchdog com.apple-intel-mcp.openclaw-watchdog; do
    WATCHDOG_TARGET="${DOMAIN}/${L}"
    if launchctl print "$WATCHDOG_TARGET" >/dev/null 2>&1; then
        if launchctl bootout "$WATCHDOG_TARGET" && wait_unloaded "$WATCHDOG_TARGET"; then
            echo "✅ Watchdog stopped: ${L}"
        else
            echo "⚠️  Watchdog may still be running: ${L}"
        fi
    fi
done

if launchctl print "$MCP_TARGET" >/dev/null 2>&1; then
    if launchctl bootout "$MCP_TARGET" && wait_unloaded "$MCP_TARGET"; then
        echo "✅ MCP Server stopped"
    else
        echo "⚠️  MCP Server may still be running"
    fi
else
    echo "MCP Server was not running"
fi
