#!/bin/bash
# Apple Intelligence MCP Server - 停止服務

PID_FILE="/tmp/apple-intel-mcp.pid"

if [ ! -f "$PID_FILE" ]; then
    echo "服務未在執行"
    exit 0
fi

PID=$(cat "$PID_FILE")
if kill -0 "$PID" 2>/dev/null; then
    kill "$PID"
    rm -f "$PID_FILE"
    echo "✅ 服務已停止（PID: $PID）"
else
    echo "服務已不在執行"
    rm -f "$PID_FILE"
fi
