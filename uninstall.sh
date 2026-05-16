#!/bin/bash
# Apple Intelligence MCP Server - 移除腳本

set -e

PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_MCP="$PLIST_DIR/com.apple-intel-mcp.server.plist"
PLIST_SWIFT="$PLIST_DIR/com.apple-intel-mcp.swift-core.plist"
PLIST_WATCHDOG="$PLIST_DIR/com.apple-intel-mcp.hermes-watchdog.plist"

echo "移除 Apple Intelligence MCP Server..."

DOMAIN="gui/$(id -u)"
# 先 bootout watchdog，避免它把 mcp 拉回來
launchctl bootout "${DOMAIN}/com.apple-intel-mcp.hermes-watchdog" 2>/dev/null && echo "已停止 watchdog" || true
launchctl bootout "${DOMAIN}/com.apple-intel-mcp.server" 2>/dev/null && echo "已停止 MCP Server" || true
launchctl bootout "${DOMAIN}/com.apple-intel-mcp.swift-core" 2>/dev/null || true
# 同時處理 legacy load 留下的
launchctl unload "$PLIST_MCP" 2>/dev/null || true
launchctl unload "$PLIST_SWIFT" 2>/dev/null || true

rm -f "$PLIST_MCP" "$PLIST_SWIFT" "$PLIST_WATCHDOG"
rm -rf "$HOME/Library/Application Support/apple-intel-mcp"
rm -f /tmp/apple-intel-mcp.hermes-pid
echo "已移除 launchd 設定"
echo ""
echo "完成。專案資料夾需手動刪除（若需要）。"
