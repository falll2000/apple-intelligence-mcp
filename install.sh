#!/bin/bash
# ============================================================
# Apple Intelligence MCP Server - 安裝腳本
# 需求：Apple Silicon Mac + macOS 26 (Tahoe)+
# ============================================================

set -e  # 任何錯誤立即中止

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_SWIFT="$PLIST_DIR/com.apple-intel-mcp.swift-core.plist"
PLIST_MCP="$PLIST_DIR/com.apple-intel-mcp.server.plist"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   Apple Intelligence MCP Server 安裝     ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── 1. 前提條件檢查 ─────────────────────────────────────────

# Apple Silicon 確認
ARCH=$(uname -m)
[ "$ARCH" = "arm64" ] || error "需要 Apple Silicon Mac（目前：$ARCH）"
info "Apple Silicon 確認（$ARCH）"

# macOS 版本確認（需要 26+）
MACOS_VERSION=$(sw_vers -productVersion | cut -d. -f1)
[ "$MACOS_VERSION" -ge 26 ] 2>/dev/null || error "需要 macOS 26（Tahoe）或更新版本（目前：$(sw_vers -productVersion)）"
info "macOS 版本確認（$(sw_vers -productVersion)）"

# Swift 確認
command -v swift >/dev/null 2>&1 || error "找不到 Swift，請安裝 Xcode Command Line Tools：xcode-select --install"
info "Swift 確認（$(swift --version 2>&1 | head -1)）"

# Foundation Models 巨集需要完整 Xcode（CLT 不夠）。
# 如果 xcode-select 指向 CLT，找 /Applications 下的 Xcode 並設 DEVELOPER_DIR。
ACTIVE_DEV="$(xcode-select -p 2>/dev/null || true)"
if [[ "$ACTIVE_DEV" == *"CommandLineTools"* ]] || [ -z "$ACTIVE_DEV" ]; then
    XCODE_APP="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)"
    [ -n "$XCODE_APP" ] || error "需要完整 Xcode（含 FoundationModels macros），CLT 不足。請從 App Store 安裝 Xcode。"
    export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
    info "偵測到 CLT，改用 Xcode：$DEVELOPER_DIR"
else
    info "DEVELOPER_DIR：$ACTIVE_DEV"
fi

# Python 確認（依序嘗試：homebrew → PATH 上的 python3，相容 pyenv/asdf）
if [ -x "/opt/homebrew/bin/python3" ]; then
    PYTHON_BIN="/opt/homebrew/bin/python3"
elif command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3)"
else
    warn "找不到 python3，嘗試以 Homebrew 安裝..."
    command -v brew >/dev/null 2>&1 || error "找不到 Homebrew 或 python3，請先安裝其一：https://brew.sh"
    brew install python3
    PYTHON_BIN="/opt/homebrew/bin/python3"
fi
info "Python 確認（$PYTHON_BIN — $($PYTHON_BIN --version)）"

# ── 2. 編譯 Swift Core Service ───────────────────────────────

info "編譯 Swift Core Service..."
cd "$REPO_DIR/swift-core"
swift build -c release
SWIFT_BIN="$REPO_DIR/swift-core/.build/release/AppleIntelCore"
[ -f "$SWIFT_BIN" ] || error "Swift 編譯失敗"
info "Swift 編譯完成：$SWIFT_BIN"

# ── 3. 建立 Python 虛擬環境並安裝依賴 ───────────────────────

info "設定 Python 虛擬環境..."
cd "$REPO_DIR/mcp-server"
if [ ! -d "venv" ]; then
    "$PYTHON_BIN" -m venv venv
fi
source venv/bin/activate
pip install -q -r requirements.txt
deactivate
info "Python 依賴安裝完成"

# ── 4. 建立 launchd plist（自動啟動）────────────────────────

mkdir -p "$PLIST_DIR"

# Swift Core Service plist
cat > "$PLIST_SWIFT" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.apple-intel-mcp.swift-core</string>
    <key>ProgramArguments</key>
    <array>
        <string>${SWIFT_BIN}</string>
    </array>
    <key>RunAtLoad</key>
    <false/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardErrorPath</key>
    <string>/tmp/apple-intel-swift-core.log</string>
</dict>
</plist>
EOF

# Python MCP Server plist
PYTHON_VENV="$REPO_DIR/mcp-server/venv/bin/python3"
DEVELOPER_DIR_LINE=""
if [ -n "${DEVELOPER_DIR:-}" ]; then
    DEVELOPER_DIR_LINE="        <key>DEVELOPER_DIR</key>
        <string>${DEVELOPER_DIR}</string>"
fi

cat > "$PLIST_MCP" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.apple-intel-mcp.server</string>
    <key>ProgramArguments</key>
    <array>
        <string>${PYTHON_VENV}</string>
        <string>${REPO_DIR}/mcp-server/server.py</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
${DEVELOPER_DIR_LINE}
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/apple-intel-mcp.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/apple-intel-mcp.log</string>
</dict>
</plist>
EOF

info "launchd 設定檔建立完成"

# ── 5. 載入並啟動服務 ────────────────────────────────────────

LAUNCHD_DOMAIN="gui/$(id -u)"
MCP_TARGET="${LAUNCHD_DOMAIN}/com.apple-intel-mcp.server"

# 清掉舊的（無論是 legacy load 還是 modern bootstrap）
launchctl bootout "$MCP_TARGET" 2>/dev/null || true
launchctl unload "$PLIST_MCP" 2>/dev/null || true

launchctl bootstrap "$LAUNCHD_DOMAIN" "$PLIST_MCP"
info "MCP Server 已啟動（port 11435）"

# ── 6. 完成 ──────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║           安裝完成！                     ║"
echo "╚══════════════════════════════════════════╝"
echo ""
PYTHON_VENV_BIN="$REPO_DIR/mcp-server/venv/bin/python3"
SERVER_PY="$REPO_DIR/mcp-server/server.py"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Claude Desktop（stdio 模式）"
echo "  編輯 ~/Library/Application Support/Claude/claude_desktop_config.json"
echo ""
echo '  "mcpServers": {'
echo '    "apple-intelligence": {'
echo "      \"command\": \"${PYTHON_VENV_BIN}\","
echo "      \"args\": [\"${SERVER_PY}\", \"--stdio\"]"
echo '    }'
echo '  }'
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  其他 AI 客戶端（HTTP 模式，已在背景執行）"
echo "  MCP Endpoint：http://127.0.0.1:11435/mcp"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "查看日誌：tail -f /tmp/apple-intel-mcp.log"
echo ""

# 偵測 hermes，提示可裝整合
if [ -f "$HOME/Library/LaunchAgents/ai.hermes.gateway.plist" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  偵測到 hermes gateway"
    echo "  如要讓 hermes gateway start/stop/restart 連動 mcp："
    echo "    ./install-hermes-integration.sh"
    echo ""
fi
