#!/bin/bash
# ============================================================
# Apple Intelligence MCP - Hermes 生命週期整合
#
# 裝完後 hermes gateway start/stop/restart 會自動連動 mcp：
#   - 透過一個輕量 launchd watchdog（每 3 秒查一次 hermes 狀態）
#   - hermes 停 → bootout mcp
#   - hermes 啟 → bootstrap mcp
#   - hermes restart（PID 變）→ kickstart -k mcp
#
# 此腳本只裝 watchdog，需要先跑 ./install.sh 把 mcp 本體裝好。
# ============================================================

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_MCP="$PLIST_DIR/com.apple-intel-mcp.server.plist"
PLIST_WATCHDOG="$PLIST_DIR/com.apple-intel-mcp.hermes-watchdog.plist"
PLIST_HERMES="$PLIST_DIR/ai.hermes.gateway.plist"
# Watchdog script 必須放在 $HOME 下（launchd 從 /Volumes/ 執行 shell script 會被 TCC 擋）
WATCHDOG_DIR="$HOME/Library/Application Support/apple-intel-mcp"
WATCHDOG_SCRIPT="$WATCHDOG_DIR/hermes-watchdog.sh"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

[ -f "$PLIST_MCP" ] || error "找不到 mcp launchd plist，請先執行 ./install.sh"
[ -f "$PLIST_HERMES" ] || warn "找不到 ai.hermes.gateway.plist（hermes 尚未安裝？watchdog 仍會裝，但 hermes 跑起來前不會做事）"
[ -f "$REPO_DIR/bin/hermes-watchdog.sh" ] || error "找不到 watchdog source：$REPO_DIR/bin/hermes-watchdog.sh"

# 1. 把 watchdog script copy 到 $HOME
mkdir -p "$WATCHDOG_DIR"
cp "$REPO_DIR/bin/hermes-watchdog.sh" "$WATCHDOG_SCRIPT"
chmod +x "$WATCHDOG_SCRIPT"
info "Watchdog script 安裝到 $WATCHDOG_SCRIPT"

# 2. 寫 plist
cat > "$PLIST_WATCHDOG" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.apple-intel-mcp.hermes-watchdog</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${WATCHDOG_SCRIPT}</string>
    </array>
    <key>StartInterval</key>
    <integer>3</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/apple-intel-mcp.hermes-watchdog.log</string>
</dict>
</plist>
EOF
info "Watchdog plist 寫入完成"

# 3. bootstrap
DOMAIN="gui/$(id -u)"
TARGET="${DOMAIN}/com.apple-intel-mcp.hermes-watchdog"
launchctl bootout "$TARGET" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST_WATCHDOG"
info "Watchdog 已啟動（每 3 秒同步 mcp ↔ ai.hermes.gateway）"

echo ""
echo "完成。試試："
echo "  hermes gateway stop    # mcp 會在 3 秒內跟著關"
echo "  hermes gateway start   # mcp 會在 3 秒內被拉起來"
echo "  hermes gateway restart # mcp 會在 3 秒內跟著重啟"
echo ""
echo "Watchdog 日誌：tail -f /tmp/apple-intel-mcp.hermes-watchdog.log"
echo "解除整合：./uninstall-hermes-integration.sh"
