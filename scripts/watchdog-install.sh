#!/usr/bin/env bash
# watchdog-install.sh — install OpenClaw watchdog as a macOS LaunchAgent
# Runs watchdog.sh every 5 minutes. Survives reboots.
# Uninstall: bash watchdog-uninstall.sh

set -euo pipefail

PLIST_LABEL="ai.openclaw.watchdog"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
WATCHDOG_SCRIPT="$SCRIPTS_DIR/watchdog.sh"
LOG_DIR="${OPENCLAW_LOG_DIR:-$HOME/.openclaw/logs}"

# Require macOS
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Error: LaunchAgent watchdog is macOS only."
  echo "On Linux, use a systemd timer or cron instead:"
  echo "  */5 * * * * bash $WATCHDOG_SCRIPT >> $LOG_DIR/watchdog.log 2>&1"
  exit 1
fi

# Validate watchdog script exists
if [[ ! -f "$WATCHDOG_SCRIPT" ]]; then
  echo "Error: watchdog.sh not found at $WATCHDOG_SCRIPT"
  exit 1
fi
chmod +x "$WATCHDOG_SCRIPT"

mkdir -p "$LOG_DIR"
mkdir -p "$HOME/Library/LaunchAgents"

# Unload existing if present
if launchctl list "$PLIST_LABEL" &>/dev/null; then
  echo "Unloading existing watchdog..."
  launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || \
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
fi

# Discover the actual node binary directory at install time
# so the plist PATH is concrete, not dependent on nvm at runtime
NODE_BIN_DIR=""
if command -v node &>/dev/null; then
  NODE_BIN_DIR="$(dirname "$(command -v node)")"
fi

# Build PATH: always include homebrew + standard locations + actual node dir if found
PLIST_PATH_VALUE="/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:/opt/homebrew/sbin:${HOME}/.local/bin"
if [[ -n "$NODE_BIN_DIR" ]] && [[ "$NODE_BIN_DIR" != "/usr/bin" ]] && [[ "$NODE_BIN_DIR" != "/usr/local/bin" ]]; then
  PLIST_PATH_VALUE="${PLIST_PATH_VALUE}:${NODE_BIN_DIR}"
fi

# Write plist
cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${WATCHDOG_SCRIPT}</string>
  </array>

  <!-- Run every 5 minutes -->
  <key>StartInterval</key>
  <integer>300</integer>

  <!-- RunAtLoad=false: waits for first interval tick, does not run immediately on load -->
  <key>RunAtLoad</key>
  <false/>

  <key>StandardOutPath</key>
  <string>${LOG_DIR}/watchdog-launchd.log</string>

  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/watchdog-launchd.log</string>

  <!-- Restart if it crashes -->
  <key>KeepAlive</key>
  <false/>

  <!-- PATH resolved at install time — re-run watchdog-install.sh if you change Node versions -->
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${PLIST_PATH_VALUE}</string>
    <key>HOME</key>
    <string>${HOME}</string>
  </dict>
</dict>
</plist>
PLIST

# Load it (bootstrap is the modern API; fall back to load for older macOS)
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || \
  launchctl load "$PLIST_PATH"

echo ""
echo "OpenClaw watchdog installed."
echo ""
echo "  Runs every:   5 minutes"
echo "  Script:       $WATCHDOG_SCRIPT"
echo "  Plist:        $PLIST_PATH"
echo "  Log:          $LOG_DIR/watchdog.log"
echo ""
echo "Commands:"
echo "  Status:    launchctl list $PLIST_LABEL"
echo "  Run now:   launchctl kickstart -k gui/\$(id -u)/$PLIST_LABEL"
echo "  Uninstall: bash $SCRIPTS_DIR/watchdog-uninstall.sh"
echo "  Log:       tail -f $LOG_DIR/watchdog.log"
