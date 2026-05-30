#!/bin/bash
# Apple Intelligence MCP - Hermes lifecycle watchdog
#
# Runs once per launchd trigger (StartInterval=3s) and syncs
# com.apple-intel-mcp.server lifecycle with ai.hermes.gateway:
#   hermes absent -> bootout mcp
#   hermes present, mcp absent -> bootstrap mcp
#   hermes PID changed -> kickstart -k mcp (restart mcp when hermes restarts)

set -u

HERMES_LABEL="ai.hermes.gateway"
MCP_LABEL="com.apple-intel-mcp.server"
DOMAIN="gui/$(id -u)"
STATE_FILE="/tmp/apple-intel-mcp.hermes-pid"
PLIST_MCP="$HOME/Library/LaunchAgents/${MCP_LABEL}.plist"

# hermes PID (loaded but not running is "-"; unloaded is empty)
hpid=$(launchctl list 2>/dev/null | awk -v l="$HERMES_LABEL" '$3==l {print $1}')
last=$(cat "$STATE_FILE" 2>/dev/null || true)

mcp_loaded=0
launchctl print "${DOMAIN}/${MCP_LABEL}" >/dev/null 2>&1 && mcp_loaded=1

if [ -z "$hpid" ]; then
    # hermes is not loaded -> stop mcp too
    if [ "$mcp_loaded" = "1" ]; then
        launchctl bootout "${DOMAIN}/${MCP_LABEL}" 2>/dev/null || true
    fi
    rm -f "$STATE_FILE"
    exit 0
fi

# hermes is present
if [ "$mcp_loaded" = "0" ] && [ -f "$PLIST_MCP" ]; then
    launchctl bootstrap "$DOMAIN" "$PLIST_MCP" 2>/dev/null || true
fi

# hermes PID changed (restart) -> restart mcp
if [ "$hpid" != "-" ] && [ -n "$last" ] && [ "$last" != "-" ] && [ "$last" != "$hpid" ]; then
    launchctl kickstart -k "${DOMAIN}/${MCP_LABEL}" 2>/dev/null || true
fi

echo "$hpid" > "$STATE_FILE"
