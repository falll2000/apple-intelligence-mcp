#!/bin/bash
# Apple Intelligence MCP Server - upgrade script

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_MCP="$HOME/Library/LaunchAgents/com.apple-intel-mcp.server.plist"
DOMAIN="gui/$(id -u)"
MCP_TARGET="${DOMAIN}/com.apple-intel-mcp.server"
REQUESTED_RELEASE="${1:-latest}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   Apple Intelligence MCP Server Upgrade  ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── 1. Check build/runtime prerequisites ─────────────────────

command -v swift >/dev/null 2>&1 || error "Swift not found. Install full Xcode first."

ACTIVE_DEV="$(xcode-select -p 2>/dev/null || true)"
if [[ "$ACTIVE_DEV" == *"CommandLineTools"* ]] || [ -z "$ACTIVE_DEV" ]; then
    XCODE_APP="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)"
    [ -n "$XCODE_APP" ] || error "Full Xcode is required for FoundationModels macros. Command Line Tools are not enough."
    export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
    info "Command Line Tools detected; using Xcode: $DEVELOPER_DIR"
else
    info "DEVELOPER_DIR: $ACTIVE_DEV"
fi

if [ -x "/opt/homebrew/bin/python3" ]; then
    PYTHON_BIN="/opt/homebrew/bin/python3"
elif command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3)"
else
    error "python3 not found. Install Python 3.10+ first."
fi
info "Python: $PYTHON_BIN — $($PYTHON_BIN --version)"

# ── 2. Switch to a GitHub Release tag if this is a git checkout ─

github_repo_from_remote() {
    local url="$1"
    case "$url" in
        git@github.com:*.git)
            url="${url#git@github.com:}"
            echo "${url%.git}"
            ;;
        https://github.com/*.git)
            url="${url#https://github.com/}"
            echo "${url%.git}"
            ;;
        https://github.com/*)
            echo "${url#https://github.com/}"
            ;;
        *)
            return 1
            ;;
    esac
}

latest_release_tag() {
    "$PYTHON_BIN" -c 'import json, sys, urllib.request
repo = sys.argv[1]
url = "https://api.github.com/repos/%s/releases/latest" % repo
req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "apple-intelligence-mcp-upgrade"})
with urllib.request.urlopen(req, timeout=30) as r:
    tag = json.load(r).get("tag_name", "")
if not tag:
    raise SystemExit("latest release has no tag_name")
print(tag)
' "$1"
}

release_tag() {
    "$PYTHON_BIN" -c 'import json, sys, urllib.parse, urllib.request
repo = sys.argv[1]
tag = urllib.parse.quote(sys.argv[2], safe="")
url = "https://api.github.com/repos/%s/releases/tags/%s" % (repo, tag)
req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "apple-intelligence-mcp-upgrade"})
with urllib.request.urlopen(req, timeout=30) as r:
    resolved = json.load(r).get("tag_name", "")
if not resolved:
    raise SystemExit("release has no tag_name")
print(resolved)
' "$1" "$2"
}

if [ -d "$REPO_DIR/.git" ]; then
    cd "$REPO_DIR"
    if ! git diff --quiet || ! git diff --cached --quiet; then
        error "Tracked files have uncommitted changes. Commit or stash them before upgrading."
    fi

    ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
    GITHUB_REPO="${APPLE_INTEL_RELEASE_REPO:-}"
    if [ -z "$GITHUB_REPO" ] && [ -n "$ORIGIN_URL" ]; then
        GITHUB_REPO="$(github_repo_from_remote "$ORIGIN_URL" || true)"
    fi
    [ -n "$GITHUB_REPO" ] || error "Could not infer a GitHub repo from origin. Set APPLE_INTEL_RELEASE_REPO=owner/repo."

    if [ "$REQUESTED_RELEASE" = "latest" ]; then
        info "Resolving latest GitHub release: $GITHUB_REPO"
        TARGET_RELEASE="$(latest_release_tag "$GITHUB_REPO")" || error "Could not resolve the latest GitHub release."
    else
        info "Resolving GitHub release: $GITHUB_REPO@$REQUESTED_RELEASE"
        TARGET_RELEASE="$(release_tag "$GITHUB_REPO" "$REQUESTED_RELEASE")" ||
            error "GitHub release not found: $REQUESTED_RELEASE"
    fi

    info "Fetching release tags..."
    git fetch --tags origin
    git rev-parse -q --verify "refs/tags/$TARGET_RELEASE" >/dev/null ||
        error "Release tag not found locally after fetch: $TARGET_RELEASE"

    CURRENT_DESCRIBE="$(git describe --tags --exact-match 2>/dev/null || true)"
    if [ "$CURRENT_DESCRIBE" = "$TARGET_RELEASE" ]; then
        info "Already on release: $TARGET_RELEASE"
    else
        info "Switching to release: $TARGET_RELEASE"
        git checkout --detach "$TARGET_RELEASE"
    fi
else
    warn "This is not a git checkout; cannot switch GitHub releases. Skipping source update."
fi

# ── 3. Rebuild Swift core ───────────────────────────────────

info "Building Swift Core Service..."
cd "$REPO_DIR/swift-core"
swift build -c release
SWIFT_BIN="$REPO_DIR/swift-core/.build/release/AppleIntelCore"
[ -f "$SWIFT_BIN" ] || error "Swift build failed."
info "Swift build complete: $SWIFT_BIN"

# ── 4. Update Python venv dependencies ──────────────────────

info "Updating Python virtual environment..."
cd "$REPO_DIR/mcp-server"
if [ ! -d "venv" ]; then
    "$PYTHON_BIN" -m venv venv
fi
source venv/bin/activate
python3 -m pip install -q --upgrade -r requirements.txt
deactivate
info "Python dependencies updated"

# ── 5. Ensure the installed launchd service uses the new binary ─

if launchctl print "$MCP_TARGET" >/dev/null 2>&1; then
    launchctl kickstart -k "$MCP_TARGET"
    info "MCP Server restarted"
elif [ -f "$PLIST_MCP" ]; then
    launchctl bootstrap "$DOMAIN" "$PLIST_MCP"
    info "MCP Server started"
else
    warn "launchd agent is not installed. Run 'bash install.sh' if you need the HTTP background service."
fi

# ── 6. Refresh the lifecycle watchdog if it's installed ─────
# The watchdog runs from a copy under $HOME, so re-run install-integration.sh
# to pick up watchdog changes in the new release and migrate any legacy
# per-agent watchdog to the unified com.apple-intel-mcp.watchdog.
WATCHDOG_SCRIPT="$HOME/Library/Application Support/apple-intel-mcp/mcp-watchdog.sh"
WD_INSTALLED=0
for L in com.apple-intel-mcp.watchdog com.apple-intel-mcp.hermes-watchdog com.apple-intel-mcp.openclaw-watchdog; do
    launchctl print "${DOMAIN}/${L}" >/dev/null 2>&1 && WD_INSTALLED=1
done
if [ "$WD_INSTALLED" = "1" ] || [ -f "$WATCHDOG_SCRIPT" ]; then
    info "Refreshing agent lifecycle watchdog..."
    bash "$REPO_DIR/install-integration.sh"
fi

echo ""
echo "Upgrade complete."
