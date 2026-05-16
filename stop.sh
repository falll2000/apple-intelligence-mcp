#!/bin/bash
# Apple Intelligence MCP Server - 完全停止（含 watchdog）
#
# 平常用 `hermes gateway stop` 即可，watchdog 會自動關 mcp。
# 這個腳本是「連 watchdog 一起關」的逃生口，例如要在 hermes 仍跑時暫停 mcp。

DOMAIN="gui/$(id -u)"
MCP_TARGET="${DOMAIN}/com.apple-intel-mcp.server"
WATCHDOG_TARGET="${DOMAIN}/com.apple-intel-mcp.hermes-watchdog"

# 先停 watchdog，否則它會把 mcp 拉回來
if launchctl print "$WATCHDOG_TARGET" >/dev/null 2>&1; then
    launchctl bootout "$WATCHDOG_TARGET"
    echo "✅ Watchdog 已停止"
fi

if launchctl print "$MCP_TARGET" >/dev/null 2>&1; then
    launchctl bootout "$MCP_TARGET"
    echo "✅ MCP Server 已停止"
else
    echo "MCP Server 原本就沒在跑"
fi
