#!/bin/bash
# Apple Intelligence MCP - lifecycle watchdog (keep-alive only)
#
# Runs once per launchd trigger (StartInterval=3s). Keeps
# com.apple-intel-mcp.server alive while ANY consumer gateway listed in
# CONSUMER_LABELS (hermes / openclaw / …) is loaded:
#   any consumer present, mcp absent -> bootstrap mcp
#   all consumers absent             -> bootout mcp
#
# It deliberately does NOT restart MCP when a gateway restarts. MCP is a stable
# HTTP endpoint that each gateway reconnects to on its own; bouncing it on one
# gateway's restart would needlessly drop the sessions of other connected
# agents. If MCP itself crashes, its launchd plist (KeepAlive=true) revives it.
#
# To support another agent, add its launchd label to CONSUMER_LABELS.

set -u

MCP_LABEL="com.apple-intel-mcp.server"
# start.sh drops this marker so a manually started MCP is not booted out three
# seconds later when no gateway happens to be running. The first poll that sees
# a consumer clears it again, handing MCP back to the gateway-driven lifecycle.
PIN_FILE="/tmp/apple-intel-mcp.manual-start"
CONSUMER_LABELS=("ai.hermes.gateway" "ai.openclaw.gateway")
DOMAIN="gui/$(id -u)"
PLIST_MCP="$HOME/Library/LaunchAgents/${MCP_LABEL}.plist"

pid_of() { launchctl list 2>/dev/null | awk -v l="$1" '$3==l {print $1}'; }

any_present=0
for l in "${CONSUMER_LABELS[@]}"; do
    [ -n "$(pid_of "$l")" ] && any_present=1
done

mcp_loaded=0
launchctl print "${DOMAIN}/${MCP_LABEL}" >/dev/null 2>&1 && mcp_loaded=1

if [ "$any_present" = "0" ]; then
    # every consumer is gone -> stop mcp, unless the operator pinned it up by hand
    [ -f "$PIN_FILE" ] && exit 0
    if [ "$mcp_loaded" = "1" ]; then
        launchctl bootout "${DOMAIN}/${MCP_LABEL}" 2>/dev/null || true
    fi
    exit 0
fi

# a consumer is present: the gateway-driven lifecycle owns MCP again
rm -f "$PIN_FILE"

# at least one consumer present -> ensure mcp is up
if [ "$mcp_loaded" = "0" ] && [ -f "$PLIST_MCP" ]; then
    launchctl bootstrap "$DOMAIN" "$PLIST_MCP" 2>/dev/null || true
fi
