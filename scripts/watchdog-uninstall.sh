#!/usr/bin/env bash
# watchdog-uninstall.sh — remove OpenClaw watchdog LaunchAgent

set -euo pipefail

PLIST_LABEL="ai.openclaw.watchdog"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Error: LaunchAgent watchdog is macOS only."
  exit 1
fi

if launchctl list "$PLIST_LABEL" &>/dev/null; then
  launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || \
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
  echo "Watchdog unloaded."
else
  echo "Watchdog was not running."
fi

if [[ -f "$PLIST_PATH" ]]; then
  rm "$PLIST_PATH"
  echo "Plist removed: $PLIST_PATH"
fi

echo "OpenClaw watchdog uninstalled."
