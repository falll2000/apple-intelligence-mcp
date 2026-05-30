#!/bin/bash
# Apple Intelligence MCP - lifecycle watchdog
#
# One watchdog for all consumer daemons. Runs once per launchd trigger
# (StartInterval=3s) and syncs com.apple-intel-mcp.server with the gateways
# listed in CONSUMER_LABELS (hermes / openclaw / …):
#   any consumer present, mcp absent -> bootstrap mcp
#   all consumers absent             -> bootout mcp
#   any consumer's PID changed       -> kickstart -k mcp (restart)
#
# To support another agent, just add its launchd label to CONSUMER_LABELS.

set -u

MCP_LABEL="com.apple-intel-mcp.server"
CONSUMER_LABELS=("ai.hermes.gateway" "ai.openclaw.gateway")
DOMAIN="gui/$(id -u)"
STATE_FILE="/tmp/apple-intel-mcp.watchdog-pids"
PLIST_MCP="$HOME/Library/LaunchAgents/${MCP_LABEL}.plist"

pid_of()      { launchctl list 2>/dev/null | awk -v l="$1" '$3==l {print $1}'; }
last_pid_of() { awk -F= -v l="$1" '$1==l {print $2}' "$STATE_FILE" 2>/dev/null; }

any_present=0
restarted=0
new_state=""
for l in "${CONSUMER_LABELS[@]}"; do
    cur=$(pid_of "$l")
    [ -n "$cur" ] && any_present=1
    prev=$(last_pid_of "$l")
    # restart = was a real pid before, is a real (different) pid now
    if [ -n "$cur" ] && [ "$cur" != "-" ] && [ -n "$prev" ] && [ "$prev" != "-" ] && [ "$cur" != "$prev" ]; then
        restarted=1
    fi
    new_state+="${l}=${cur}"$'\n'
done

mcp_loaded=0
launchctl print "${DOMAIN}/${MCP_LABEL}" >/dev/null 2>&1 && mcp_loaded=1

if [ "$any_present" = "0" ]; then
    # every consumer is gone -> stop mcp
    if [ "$mcp_loaded" = "1" ]; then
        launchctl bootout "${DOMAIN}/${MCP_LABEL}" 2>/dev/null || true
    fi
    rm -f "$STATE_FILE"
    exit 0
fi

# at least one consumer present -> ensure mcp is up
if [ "$mcp_loaded" = "0" ] && [ -f "$PLIST_MCP" ]; then
    launchctl bootstrap "$DOMAIN" "$PLIST_MCP" 2>/dev/null || true
fi

# a consumer restarted -> restart mcp
if [ "$restarted" = "1" ]; then
    launchctl kickstart -k "${DOMAIN}/${MCP_LABEL}" 2>/dev/null || true
fi

printf '%s' "$new_state" > "$STATE_FILE"
