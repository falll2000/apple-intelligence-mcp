#!/bin/bash
# Apple Intelligence MCP - Hermes lifecycle watchdog
#
# 每次被 launchd 觸發（StartInterval=3s）執行一次，把
# com.apple-intel-mcp.server 的存活狀態同步到 ai.hermes.gateway：
#   hermes 不在     → bootout mcp
#   hermes 在、mcp 沒在 → bootstrap mcp
#   hermes PID 變了 → kickstart -k mcp（hermes restart 也跟著重啟）

set -u

HERMES_LABEL="ai.hermes.gateway"
MCP_LABEL="com.apple-intel-mcp.server"
DOMAIN="gui/$(id -u)"
STATE_FILE="/tmp/apple-intel-mcp.hermes-pid"
PLIST_MCP="$HOME/Library/LaunchAgents/${MCP_LABEL}.plist"

# hermes 的 PID（loaded 但沒跑會是 "-"；沒 load 則為空）
hpid=$(launchctl list 2>/dev/null | awk -v l="$HERMES_LABEL" '$3==l {print $1}')
last=$(cat "$STATE_FILE" 2>/dev/null || true)

mcp_loaded=0
launchctl print "${DOMAIN}/${MCP_LABEL}" >/dev/null 2>&1 && mcp_loaded=1

if [ -z "$hpid" ]; then
    # hermes 沒 load → 把 mcp 也關掉
    if [ "$mcp_loaded" = "1" ]; then
        launchctl bootout "${DOMAIN}/${MCP_LABEL}" 2>/dev/null || true
    fi
    rm -f "$STATE_FILE"
    exit 0
fi

# hermes 在
if [ "$mcp_loaded" = "0" ] && [ -f "$PLIST_MCP" ]; then
    launchctl bootstrap "$DOMAIN" "$PLIST_MCP" 2>/dev/null || true
fi

# hermes PID 變了（restart）→ 重啟 mcp
if [ "$hpid" != "-" ] && [ -n "$last" ] && [ "$last" != "-" ] && [ "$last" != "$hpid" ]; then
    launchctl kickstart -k "${DOMAIN}/${MCP_LABEL}" 2>/dev/null || true
fi

echo "$hpid" > "$STATE_FILE"
