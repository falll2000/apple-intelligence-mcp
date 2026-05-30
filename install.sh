#!/bin/bash
# ============================================================
# Apple Intelligence MCP Server - install script
# Requirements: Apple Silicon Mac + macOS 26 (Tahoe)+
# ============================================================

set -e  # Exit immediately on any error

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
echo "║   Apple Intelligence MCP Server Install  ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── 1. Prerequisite checks ───────────────────────────────────

# Apple Silicon check
ARCH=$(uname -m)
[ "$ARCH" = "arm64" ] || error "Apple Silicon Mac required (current: $ARCH)"
info "Apple Silicon confirmed ($ARCH)"

# macOS version check (requires 26+)
MACOS_VERSION=$(sw_vers -productVersion | cut -d. -f1)
[ "$MACOS_VERSION" -ge 26 ] 2>/dev/null || error "macOS 26 (Tahoe) or later required (current: $(sw_vers -productVersion))"
info "macOS version confirmed ($(sw_vers -productVersion))"

# Swift check
command -v swift >/dev/null 2>&1 || error "Swift not found. Install Xcode Command Line Tools: xcode-select --install"
info "Swift confirmed ($(swift --version 2>&1 | head -1))"

# Foundation Models macros require full Xcode (CLT is not enough).
# If xcode-select points to CLT, find Xcode under /Applications and set DEVELOPER_DIR.
ACTIVE_DEV="$(xcode-select -p 2>/dev/null || true)"
if [[ "$ACTIVE_DEV" == *"CommandLineTools"* ]] || [ -z "$ACTIVE_DEV" ]; then
    XCODE_APP="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)"
    [ -n "$XCODE_APP" ] || error "Full Xcode is required for FoundationModels macros. Command Line Tools are not enough. Install Xcode from the App Store."
    export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
    info "Command Line Tools detected; using Xcode: $DEVELOPER_DIR"
else
    info "DEVELOPER_DIR: $ACTIVE_DEV"
fi

# Python check (try Homebrew first, then python3 on PATH; compatible with pyenv/asdf)
if [ -x "/opt/homebrew/bin/python3" ]; then
    PYTHON_BIN="/opt/homebrew/bin/python3"
elif command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3)"
else
    warn "python3 not found; trying to install it with Homebrew..."
    command -v brew >/dev/null 2>&1 || error "Homebrew and python3 are both missing. Install one first: https://brew.sh"
    brew install python3
    PYTHON_BIN="/opt/homebrew/bin/python3"
fi
info "Python confirmed ($PYTHON_BIN — $($PYTHON_BIN --version))"

# ── 2. Build Swift Core Service ──────────────────────────────

info "Building Swift Core Service..."
cd "$REPO_DIR/swift-core"
swift build -c release
SWIFT_BIN="$REPO_DIR/swift-core/.build/release/AppleIntelCore"
[ -f "$SWIFT_BIN" ] || error "Swift build failed"
info "Swift build complete: $SWIFT_BIN"

# ── 3. Create Python virtualenv and install dependencies ─────

info "Setting up Python virtual environment..."
cd "$REPO_DIR/mcp-server"
if [ ! -d "venv" ]; then
    "$PYTHON_BIN" -m venv venv
fi
source venv/bin/activate
pip install -q -r requirements.txt
deactivate
info "Python dependencies installed"

# ── 4. Create launchd plist files (auto-start) ───────────────

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

info "launchd plist files created"

# ── 5. Load and start the service ────────────────────────────

LAUNCHD_DOMAIN="gui/$(id -u)"
MCP_TARGET="${LAUNCHD_DOMAIN}/com.apple-intel-mcp.server"

# Clear any previous instance (legacy load or modern bootstrap)
launchctl bootout "$MCP_TARGET" 2>/dev/null || true
launchctl unload "$PLIST_MCP" 2>/dev/null || true

launchctl bootstrap "$LAUNCHD_DOMAIN" "$PLIST_MCP"
info "MCP Server started (port 11435)"

# ── 6. Done ──────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║           Install complete!              ║"
echo "╚══════════════════════════════════════════╝"
echo ""
PYTHON_VENV_BIN="$REPO_DIR/mcp-server/venv/bin/python3"
SERVER_PY="$REPO_DIR/mcp-server/server.py"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Claude Desktop (stdio mode)"
echo "  Edit ~/Library/Application Support/Claude/claude_desktop_config.json"
echo ""
echo '  "mcpServers": {'
echo '    "apple-intelligence": {'
echo "      \"command\": \"${PYTHON_VENV_BIN}\","
echo "      \"args\": [\"${SERVER_PY}\", \"--stdio\"]"
echo '    }'
echo '  }'
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Other AI clients (HTTP mode, already running in the background)"
echo "  MCP Endpoint: http://127.0.0.1:11435/mcp"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Logs: tail -f /tmp/apple-intel-mcp.log"
echo ""

# Detect hermes and suggest installing the integration
if [ -f "$HOME/Library/LaunchAgents/ai.hermes.gateway.plist" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  hermes gateway detected"
    echo "  To link hermes gateway start/stop/restart with MCP:"
    echo "    ./install-hermes-integration.sh"
    echo ""
fi
