#!/usr/bin/env bash
# post-update.sh — explicit OpenClaw post-update orchestrator
#
# Run this after `openclaw update` (or wire it into a wrapper/hook) to execute
# the canonical post-update sequence:
#   1. check-update.sh --fix
#   2. heal.sh
#   3. workspace reconcile script (if present)
#   4. security-scan.sh
#   5. openclaw health --json
#
# The script is idempotent: if the current OpenClaw version matches the stored
# watchdog state and no version change is pending, it exits without running the
# heavy sequence.
#
# Nested `openclaw` calls inherit OPENCLAW_SKIP_WRAPPER_BACKUP=1 so a wrapper
# can call this script without triggering backup loops on internal subcommands.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"

require_tools python3 openclaw || exit 1

SCRIPT_DIR="${OPENCLAW_POST_UPDATE_SCRIPTS_DIR:-$LIB_DIR}"
STATE_FILE="${OPENCLAW_POST_UPDATE_STATE_FILE:-$HOME/.openclaw/watchdog-state.json}"
POLICY_GUARD_TRIGGER_FILE="${OPENCLAW_POST_UPDATE_POLICY_GUARD_TRIGGER:-$HOME/.openclaw/state/policy-guard.trigger}"
WORKSPACE_ROOT="${OPENCLAW_WORKSPACE_ROOT:-$HOME/.openclaw/workspace}"
RECONCILE_SCRIPT="${OPENCLAW_POST_UPDATE_RECONCILE_SCRIPT:-$WORKSPACE_ROOT/scripts/openclaw_post_update_reconcile.py}"
RECONCILE_INTERPRETER="${OPENCLAW_POST_UPDATE_RECONCILE_INTERPRETER:-python3}"

log()  { echo -e "${CYN}[~]${RST} $1"; }
good() { echo -e "${GRN}[✓]${RST} $1"; }

export OPENCLAW_SKIP_WRAPPER_BACKUP=1

read_state() {
  python3 - "$STATE_FILE" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding='utf-8'))
except Exception:
    data = {}

current = str(data.get('current_version') or data.get('last_version') or '').strip()
pending = '1' if data.get('version_change_pending') else '0'
print(current)
print(pending)
PY
}

STATE_INFO="$(read_state)"
STATE_CURRENT_VERSION="$(printf '%s\n' "$STATE_INFO" | sed -n '1p')"
STATE_PENDING="$(printf '%s\n' "$STATE_INFO" | sed -n '2p')"
CURRENT_VERSION="$(get_openclaw_version)"

log "Current version: ${CURRENT_VERSION:-unknown}"

if [[ -n "$STATE_CURRENT_VERSION" ]] && [[ "$STATE_CURRENT_VERSION" == "$CURRENT_VERSION" ]] && [[ "$STATE_PENDING" != "1" ]]; then
  good "Version unchanged ($CURRENT_VERSION) — skipping post-update sequence"
  exit 0
fi

log "Version changed or pending state detected — running post-update sequence"

run_step() {
  local label="$1"
  shift
  log "$label"
  if ! "$@"; then
    log_warn "$label failed"
    return 1
  fi
}

FAILED=0

if ! run_step "1/5 check-update.sh --fix" bash "$SCRIPT_DIR/check-update.sh" --fix; then
  FAILED=1
fi
if ! run_step "2/5 heal.sh" bash "$SCRIPT_DIR/heal.sh"; then
  FAILED=1
fi
run_workspace_reconcile() {
  if [[ ! -f "$RECONCILE_SCRIPT" ]]; then
    log "3/5 workspace reconcile skipped (missing: $RECONCILE_SCRIPT)"
    return 0
  fi

  run_step "3/5 workspace reconcile" "$RECONCILE_INTERPRETER" "$RECONCILE_SCRIPT"
}

if ! run_workspace_reconcile; then
  FAILED=1
fi
if ! run_step "4/5 security-scan.sh" bash "$SCRIPT_DIR/security-scan.sh"; then
  FAILED=1
fi
if ! run_step "5/5 openclaw health --json" openclaw health --json; then
  FAILED=1
fi

# Optional: deep security audit if available in this OpenClaw build
if command -v openclaw >/dev/null 2>&1 && openclaw security audit --help >/dev/null 2>&1; then
  if ! run_step "6/6 openclaw security audit --deep" openclaw security audit --deep; then
    FAILED=1
  fi
else
  log "6/6 openclaw security audit --deep skipped (command not available)"
fi

touch_policy_guard_trigger() {
  local trigger_dir
  trigger_dir="$(dirname "$POLICY_GUARD_TRIGGER_FILE")"

  if mkdir -p "$trigger_dir" 2>/dev/null && : > "$POLICY_GUARD_TRIGGER_FILE" 2>/dev/null; then
    good "Policy guard trigger touched: $POLICY_GUARD_TRIGGER_FILE"
  else
    log_warn "Policy guard trigger could not be written (non-fatal): $POLICY_GUARD_TRIGGER_FILE"
  fi
}

touch_policy_guard_trigger

if [[ "$FAILED" -eq 0 ]]; then
  good "Post-update sequence completed"
else
  log_warn "Post-update sequence completed with warnings"
fi
exit "$FAILED"
