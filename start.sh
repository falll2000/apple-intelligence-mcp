#!/bin/bash
# Apple Intelligence MCP Server - 啟動（launchd）
#
# 若已裝 hermes 整合，watchdog 也會一併啟動。

PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_MCP="$PLIST_DIR/com.apple-intel-mcp.server.plist"
PLIST_WATCHDOG="$PLIST_DIR/com.apple-intel-mcp.hermes-watchdog.plist"
DOMAIN="gui/$(id -u)"
MCP_TARGET="${DOMAIN}/com.apple-intel-mcp.server"
WATCHDOG_TARGET="${DOMAIN}/com.apple-intel-mcp.hermes-watchdog"

if [ ! -f "$PLIST_MCP" ]; then
    echo "❌ 找不到 mcp launchd plist，請先執行 ./install.sh"
    exit 1
fi

if ! launchctl print "$MCP_TARGET" >/dev/null 2>&1; then
    launchctl bootstrap "$DOMAIN" "$PLIST_MCP"
    echo "✅ MCP Server 啟動"
else
    echo "ℹ️  MCP Server 已在執行"
fi

if [ -f "$PLIST_WATCHDOG" ]; then
    if ! launchctl print "$WATCHDOG_TARGET" >/dev/null 2>&1; then
        launchctl bootstrap "$DOMAIN" "$PLIST_WATCHDOG"
        echo "✅ Hermes watchdog 啟動"
    else
        echo "ℹ️  Hermes watchdog 已在執行"
    fi
fi

echo "   MCP 位址：http://127.0.0.1:11435/mcp"
echo "   日誌：tail -f /tmp/apple-intel-mcp.log"
