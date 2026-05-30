#!/bin/bash
# ============================================================
# Remove agent lifecycle integration (keep MCP itself)
# ============================================================

set -e

PLIST_DIR="$HOME/Library/LaunchAgents"
WATCHDOG_DIR="$HOME/Library/Application Support/apple-intel-mcp"
DOMAIN="gui/$(id -u)"

# Current watchdog + any legacy per-agent ones.
for L in com.apple-intel-mcp.watchdog com.apple-intel-mcp.hermes-watchdog com.apple-intel-mcp.openclaw-watchdog; do
    launchctl bootout "${DOMAIN}/${L}" 2>/dev/null && echo "Stopped ${L}" || true
    rm -f "$PLIST_DIR/${L}.plist"
done

rm -f "$WATCHDOG_DIR/mcp-watchdog.sh" "$WATCHDOG_DIR/hermes-watchdog.sh" "$WATCHDOG_DIR/openclaw-watchdog.sh"
rm -f /tmp/apple-intel-mcp.watchdog-pids /tmp/apple-intel-mcp.watchdog.log \
      /tmp/apple-intel-mcp.hermes-pid /tmp/apple-intel-mcp.openclaw-pid \
      /tmp/apple-intel-mcp.hermes-watchdog.log /tmp/apple-intel-mcp.openclaw-watchdog.log
echo "Watchdog configuration removed. MCP itself was not changed."
