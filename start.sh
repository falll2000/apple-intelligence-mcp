#!/bin/bash
# Apple Intelligence MCP Server - 背景啟動

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="/tmp/apple-intel-mcp.pid"
LOG_FILE="/tmp/apple-intel-mcp.log"
PYTHON="$REPO_DIR/mcp-server/venv/bin/python3"
SERVER="$REPO_DIR/mcp-server/server.py"

# Foundation Models 巨集需要完整 Xcode；若 xcode-select 指向 CLT 自動切換
if [[ "$(xcode-select -p 2>/dev/null)" == *"CommandLineTools"* ]]; then
    XCODE_APP="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)"
    [ -n "$XCODE_APP" ] && export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
fi

# 已在執行中？
if [ -f "$PID_FILE" ] && kill -0 "$(cat $PID_FILE)" 2>/dev/null; then
    echo "✅ 服務已在執行中（PID: $(cat $PID_FILE)）"
    echo "   MCP 位址：http://127.0.0.1:11435/mcp"
    exit 0
fi

# 啟動
echo "🚀 啟動 Apple Intelligence MCP Server..."
nohup "$PYTHON" "$SERVER" > "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"

# 等待服務就緒
sleep 2
if kill -0 "$(cat $PID_FILE)" 2>/dev/null; then
    echo "✅ 服務已在背景執行（PID: $(cat $PID_FILE)）"
    echo "   MCP 位址：http://127.0.0.1:11435/mcp"
    echo "   日誌：tail -f $LOG_FILE"
else
    echo "❌ 啟動失敗，查看日誌："
    tail -20 "$LOG_FILE"
    rm -f "$PID_FILE"
    exit 1
fi
