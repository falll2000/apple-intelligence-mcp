#!/bin/bash
# Apple Intelligence MCP Server - 移除腳本

set -e

PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_MCP="$PLIST_DIR/com.apple-intel-mcp.server.plist"
PLIST_SWIFT="$PLIST_DIR/com.apple-intel-mcp.swift-core.plist"

echo "移除 Apple Intelligence MCP Server..."

launchctl unload "$PLIST_MCP" 2>/dev/null && echo "已停止 MCP Server" || true
launchctl unload "$PLIST_SWIFT" 2>/dev/null || true

rm -f "$PLIST_MCP" "$PLIST_SWIFT"
echo "已移除 launchd 設定"
echo ""
echo "完成。專案資料夾需手動刪除（若需要）。"
