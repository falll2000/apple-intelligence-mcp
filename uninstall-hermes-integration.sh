#!/bin/bash
# ============================================================
# 解除 hermes 整合（保留 mcp 本體）
# ============================================================

set -e

PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_WATCHDOG="$PLIST_DIR/com.apple-intel-mcp.hermes-watchdog.plist"
WATCHDOG_DIR="$HOME/Library/Application Support/apple-intel-mcp"

DOMAIN="gui/$(id -u)"
launchctl bootout "${DOMAIN}/com.apple-intel-mcp.hermes-watchdog" 2>/dev/null && echo "已停止 watchdog" || echo "watchdog 原本就沒在跑"

rm -f "$PLIST_WATCHDOG"
rm -rf "$WATCHDOG_DIR"
rm -f /tmp/apple-intel-mcp.hermes-pid /tmp/apple-intel-mcp.hermes-watchdog.log
echo "已移除 watchdog 設定。mcp 本體未動。"
