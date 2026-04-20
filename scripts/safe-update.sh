#!/usr/bin/env bash
# safe-update.sh — conservative OpenClaw update flow with backup + triage

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_PATH="$SCRIPT_DIR/lib.sh"
USE_LIB=0

if [[ -f "$LIB_PATH" ]]; then
  # shellcheck disable=SC1091
  source "$LIB_PATH"
  USE_LIB=1
fi

TOTAL_STEPS=7
FAILED=0
CURRENT_STEP=0
LAST_STEP_LABEL="startup"
TRIAGE_DONE=0
TRIAGE_DIR=""
BACKUP_RESULT=""
RESTART_RESULT=""
BACKUP_TIMEOUT_SEC="${OPENCLAW_SAFE_UPDATE_BACKUP_TIMEOUT_SEC:-300}"
UPDATE_TIMEOUT_SEC="${OPENCLAW_SAFE_UPDATE_UPDATE_TIMEOUT_SEC:-1800}"
POST_UPDATE_TIMEOUT_SEC="${OPENCLAW_SAFE_UPDATE_POST_UPDATE_TIMEOUT_SEC:-1200}"
BASELINE_TIMEOUT_SEC="${OPENCLAW_SAFE_UPDATE_BASELINE_TIMEOUT_SEC:-120}"
UPDATE_EXIT_CODE=""
UPDATE_TIMED_OUT=0
LOCK_DIR="${OPENCLAW_SAFE_UPDATE_LOCK_DIR:-$HOME/.openclaw/locks}"
LOCK_FILE="$LOCK_DIR/safe-update.lock"
LOCK_BACKEND="none"
UPDATE_BINARY="${OPENCLAW_SAFE_UPDATE_BINARY:-}"
MAINTENANCE_MODE=0
HEARTBEAT_SEC="${OPENCLAW_SAFE_UPDATE_HEARTBEAT_SEC:-60}"
CHECKPOINT_LOG=""
UPDATE_CMD_EXTRA_ARGS=()

run_with_timeout() {
  local timeout_sec="$1"
  shift

  if ! [[ "$timeout_sec" =~ ^[0-9]+$ ]] || [[ "$timeout_sec" -le 0 ]]; then
    "$@"
    return
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout --foreground "$timeout_sec" "$@"
  else
    python3 - "$timeout_sec" "$@" <<'PY'
import subprocess
import sys

timeout_sec = int(sys.argv[1])
cmd = sys.argv[2:]
if not cmd:
    raise SystemExit(0)

try:
    proc = subprocess.Popen(cmd)
except FileNotFoundError as exc:
    print(str(exc), file=sys.stderr)
    raise SystemExit(127)

try:
    raise SystemExit(proc.wait(timeout=timeout_sec))
except subprocess.TimeoutExpired:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    raise SystemExit(124)
PY
  fi
}

timestamp_now() {
  date -u +"%Y%m%d-%H%M%SZ"
}

usage() {
  cat <<'EOF'
Usage: safe-update.sh [options]

Options:
  --maintenance-window   Enable long maintenance mode (higher timeouts + update heartbeats)
  -h, --help             Show this help and exit
EOF
}

log_info_msg() {
  if [[ "$USE_LIB" -eq 1 ]] && declare -F log_info >/dev/null 2>&1; then
    log_info "$1"
  else
    printf '        %s\n' "$1"
  fi
}

log_ok_msg() {
  if [[ "$USE_LIB" -eq 1 ]] && declare -F log_ok >/dev/null 2>&1; then
    log_ok "$1"
  else
    printf '[OK] %s\n' "$1"
  fi
}

log_warn_msg() {
  if [[ "$USE_LIB" -eq 1 ]] && declare -F log_warn >/dev/null 2>&1; then
    log_warn "$1"
  else
    printf '[WARN] %s\n' "$1"
  fi
}

log_error_msg() {
  if [[ "$USE_LIB" -eq 1 ]] && declare -F log_error >/dev/null 2>&1; then
    log_error "$1"
  else
    printf '[ERROR] %s\n' "$1"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --maintenance-window)
        MAINTENANCE_MODE=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log_error_msg "Unknown argument: $1"
        usage
        return 1
        ;;
    esac
    shift
  done
}

checkpoint() {
  local message="$1"
  if [[ -n "$CHECKPOINT_LOG" ]]; then
    printf '%s | %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$message" >>"$CHECKPOINT_LOG" 2>/dev/null || true
  fi
}

init_checkpoint_log() {
  local ts
  ts="$(timestamp_now)"
  CHECKPOINT_LOG="${OPENCLAW_SAFE_UPDATE_CHECKPOINT_LOG:-$HOME/.openclaw/triage/safe-update-checkpoints-$ts.log}"
  mkdir -p "$(dirname "$CHECKPOINT_LOG")"
  : >"$CHECKPOINT_LOG"
  chmod 600 "$CHECKPOINT_LOG" 2>/dev/null || true
  checkpoint "safe-update start maintenance_mode=$MAINTENANCE_MODE"
}

configure_maintenance_defaults() {
  if [[ "$MAINTENANCE_MODE" -ne 1 ]]; then
    return 0
  fi

  if [[ -z "${OPENCLAW_SAFE_UPDATE_BACKUP_TIMEOUT_SEC:-}" ]]; then
    BACKUP_TIMEOUT_SEC=1800
  fi
  if [[ -z "${OPENCLAW_SAFE_UPDATE_UPDATE_TIMEOUT_SEC:-}" ]]; then
    UPDATE_TIMEOUT_SEC=7200
  fi
  if [[ -z "${OPENCLAW_SAFE_UPDATE_POST_UPDATE_TIMEOUT_SEC:-}" ]]; then
    POST_UPDATE_TIMEOUT_SEC=1800
  fi
  if [[ -z "${OPENCLAW_SAFE_UPDATE_BASELINE_TIMEOUT_SEC:-}" ]]; then
    BASELINE_TIMEOUT_SEC=300
  fi

  if ! [[ "$HEARTBEAT_SEC" =~ ^[0-9]+$ ]] || [[ "$HEARTBEAT_SEC" -lt 5 ]]; then
    HEARTBEAT_SEC=60
  fi
}

step() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  LAST_STEP_LABEL="$1"
  printf '\n[%d/%d] %s\n' "$CURRENT_STEP" "$TOTAL_STEPS" "$1"
  checkpoint "step=${CURRENT_STEP}/${TOTAL_STEPS} label=$1"
}

sanitize_output() {
  if [[ "$USE_LIB" -eq 1 ]] && declare -F sanitize_sensitive >/dev/null 2>&1; then
    sanitize_sensitive
  else
    sed -E \
      -e 's/sk-[A-Za-z0-9-]{20,}/[REDACTED_API_KEY]/g' \
      -e 's/xoxb-[0-9A-Za-z-]+/[REDACTED_SLACK_TOKEN]/g' \
      -e 's/ghp_[A-Za-z0-9]{20,}/[REDACTED_GH_TOKEN]/g' \
      -e 's/(Bearer[[:space:]]+)[A-Za-z0-9._-]{20,}/\1[REDACTED]/Ig' \
      -e 's/(token|password|secret|api_key|apiKey|auth_token)[[:space:]]*[:=][[:space:]]*[^[:space:]]+/\1=[REDACTED]/Ig'
  fi
}

run_and_capture() {
  local outfile="$1"
  shift
  {
    printf '$ %s\n' "$*"
    "$@"
  } 2>&1 | sanitize_output >"$outfile" || true
}

acquire_update_lock() {
  mkdir -p "$LOCK_DIR"
  chmod 700 "$LOCK_DIR" 2>/dev/null || true

  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
      log_error_msg "Another safe-update run appears active (lock busy: $LOCK_FILE)"
      return 1
    fi
    LOCK_BACKEND="flock"
    printf '%s\n' "$$" 1>&9 || true
    return 0
  fi

  if [[ -f "$LOCK_FILE" ]]; then
    local existing_pid
    existing_pid="$(head -n 1 "$LOCK_FILE" 2>/dev/null || true)"
    if [[ "$existing_pid" =~ ^[0-9]+$ ]] && kill -0 "$existing_pid" 2>/dev/null; then
      log_error_msg "Another safe-update run appears active (pid $existing_pid; lock: $LOCK_FILE)"
      return 1
    fi
    log_warn_msg "Replacing stale lock file: $LOCK_FILE"
  fi

  printf '%s\n' "$$" >"$LOCK_FILE"
  chmod 600 "$LOCK_FILE" 2>/dev/null || true
  LOCK_BACKEND="pidfile"
}

release_update_lock() {
  if [[ "$LOCK_BACKEND" == "pidfile" ]] && [[ -f "$LOCK_FILE" ]]; then
    local lock_pid
    lock_pid="$(head -n 1 "$LOCK_FILE" 2>/dev/null || true)"
    if [[ "$lock_pid" == "$$" ]]; then
      rm -f "$LOCK_FILE" || true
    fi
  fi
}

detect_external_update_in_progress() {
  local self_pid
  self_pid="$$"
  if command -v pgrep >/dev/null 2>&1; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local pid
      pid="${line%% *}"
      if [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$pid" != "$self_pid" ]]; then
        return 0
      fi
    done < <(pgrep -af '(^|[[:space:]])openclaw[[:space:]]+update([[:space:]]|$)' || true)
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local pid cmdline
    pid="${line%% *}"
    cmdline="${line#* }"
    if [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$pid" != "$self_pid" ]] && [[ "$cmdline" == *"openclaw update"* ]]; then
      return 0
    fi
  done < <(ps -eo pid=,args= 2>/dev/null || true)

  return 1
}

collect_update_timeout_triage() {
  local outfile="$TRIAGE_DIR/update-timeout.txt"
  {
    printf 'update_timeout=true\n'
    printf 'update_timeout_sec=%s\n' "$UPDATE_TIMEOUT_SEC"
    printf 'update_exit_code=%s\n' "${UPDATE_EXIT_CODE:-unknown}"
    printf 'captured_at_utc=%s\n' "$(timestamp_now)"
    echo
    echo "== openclaw/safe-update processes =="
    if command -v pgrep >/dev/null 2>&1; then
      pgrep -af 'openclaw|safe-update\.sh' || true
    else
      ps aux || true
    fi
    echo
    echo "== lock context =="
    printf 'lock_backend=%s\n' "$LOCK_BACKEND"
    printf 'lock_file=%s\n' "$LOCK_FILE"
    if [[ -f "$LOCK_FILE" ]]; then
      ls -l "$LOCK_FILE" || true
      echo "lock_file_contents:"
      cat "$LOCK_FILE" || true
    else
      echo "lock_file_missing=true"
    fi
  } 2>&1 | sanitize_output >"$outfile" || true
  chmod 600 "$outfile" 2>/dev/null || true
}

collect_triage() {
  if [[ "$TRIAGE_DONE" -eq 1 ]]; then
    return 0
  fi
  TRIAGE_DONE=1

  local ts
  ts="$(timestamp_now)"
  TRIAGE_DIR="$HOME/.openclaw/triage/$ts"
  mkdir -p "$TRIAGE_DIR"
  chmod 700 "$TRIAGE_DIR" 2>/dev/null || true

  local captured_by_script=0
  local capture_script="$SCRIPT_DIR/capture-triage.sh"
  if [[ -x "$capture_script" ]]; then
    if bash "$capture_script" --output "$TRIAGE_DIR" >/dev/null 2>&1; then
      captured_by_script=1
      log_warn_msg "Base triage collected via capture-triage.sh at: $TRIAGE_DIR"
    fi
    if [[ "$captured_by_script" -eq 0 ]]; then
      log_warn_msg "capture-triage.sh failed; collecting fallback triage inline"
    fi
  fi

  {
    printf 'safe-update failure triage\n'
    printf 'timestamp_utc=%s\n' "$ts"
    printf 'failed_step=%s\n' "$LAST_STEP_LABEL"
    printf 'backup_result=%s\n' "${BACKUP_RESULT:-unknown}"
    printf 'restart_result=%s\n' "${RESTART_RESULT:-unknown}"
    printf 'update_exit_code=%s\n' "${UPDATE_EXIT_CODE:-unknown}"
    printf 'update_timed_out=%s\n' "$UPDATE_TIMED_OUT"
    printf 'update_timeout_sec=%s\n' "$UPDATE_TIMEOUT_SEC"
    printf 'maintenance_mode=%s\n' "$MAINTENANCE_MODE"
    if [[ "${#UPDATE_CMD_EXTRA_ARGS[@]}" -gt 0 ]]; then
      printf 'update_extra_args=%s\n' "${UPDATE_CMD_EXTRA_ARGS[*]}"
    else
      printf 'update_extra_args=none\n'
    fi
    printf 'checkpoint_log=%s\n' "${CHECKPOINT_LOG:-none}"
  } >"$TRIAGE_DIR/meta.txt"
  chmod 600 "$TRIAGE_DIR/meta.txt" 2>/dev/null || true

  if [[ "$captured_by_script" -eq 0 ]]; then
    run_and_capture "$TRIAGE_DIR/status.txt" openclaw status --all

    if openclaw health --json >/dev/null 2>&1; then
      run_and_capture "$TRIAGE_DIR/health.txt" openclaw health --json
    else
      run_and_capture "$TRIAGE_DIR/health.txt" openclaw health
    fi

    if openclaw channels status --probe >/dev/null 2>&1; then
      run_and_capture "$TRIAGE_DIR/channels.txt" openclaw channels status --probe
    else
      run_and_capture "$TRIAGE_DIR/channels.txt" openclaw channels status
    fi

    if openclaw gateway status >/dev/null 2>&1; then
      run_and_capture "$TRIAGE_DIR/gateway-status.txt" openclaw gateway status
    elif command -v systemctl >/dev/null 2>&1; then
      run_and_capture "$TRIAGE_DIR/gateway-status.txt" systemctl --user status openclaw-gateway.service --no-pager
    else
      run_and_capture "$TRIAGE_DIR/gateway-status.txt" ps aux
    fi

    {
      if [[ -f "$HOME/.openclaw/logs/gateway.err.log" ]]; then
        echo "== gateway.err.log (tail -n 200) =="
        tail -n 200 "$HOME/.openclaw/logs/gateway.err.log"
        echo
      fi
      if [[ -f "$HOME/.openclaw/logs/gateway.out.log" ]]; then
        echo "== gateway.out.log (tail -n 200) =="
        tail -n 200 "$HOME/.openclaw/logs/gateway.out.log"
        echo
      fi
      if command -v journalctl >/dev/null 2>&1; then
        echo "== journalctl --user -u openclaw-gateway.service -n 200 =="
        journalctl --user -u openclaw-gateway.service -n 200 --no-pager 2>/dev/null || true
      fi
    } 2>&1 | sanitize_output >"$TRIAGE_DIR/logs.txt" || true
  fi

  chmod 600 "$TRIAGE_DIR"/*.txt 2>/dev/null || true

  if [[ "$UPDATE_TIMED_OUT" -eq 1 ]]; then
    collect_update_timeout_triage || true
    log_warn_msg "Timeout-specific triage collected at: $TRIAGE_DIR/update-timeout.txt"
  fi

  log_warn_msg "Triage collected at: $TRIAGE_DIR"
}

on_error() {
  local code="$?"
  FAILED=1
  log_error_msg "Failure during step: $LAST_STEP_LABEL"
  collect_triage || true
  exit "$code"
}

trap on_error ERR
trap release_update_lock EXIT

run_update_with_observability() {
  local -a cmd
  cmd=("$UPDATE_BINARY" update "${UPDATE_CMD_EXTRA_ARGS[@]}")

  if [[ "$MAINTENANCE_MODE" -ne 1 ]]; then
    run_with_timeout "$UPDATE_TIMEOUT_SEC" "${cmd[@]}"
    return "$?"
  fi

  checkpoint "update_start cmd=${cmd[*]} timeout_sec=$UPDATE_TIMEOUT_SEC"

  local update_pid
  set +e
  run_with_timeout "$UPDATE_TIMEOUT_SEC" "${cmd[@]}" &
  update_pid="$!"

  while kill -0 "$update_pid" 2>/dev/null; do
    local process_hint="unavailable"
    if command -v pgrep >/dev/null 2>&1; then
      process_hint="$(pgrep -af 'openclaw update|pnpm|oxlint|tsgolint' 2>/dev/null | tr '\n' ';' | cut -c1-500)"
      [[ -z "$process_hint" ]] && process_hint="none"
    fi
    checkpoint "update_heartbeat pid=$update_pid hint=$process_hint"
    sleep "$HEARTBEAT_SEC"
  done

  wait "$update_pid"
  local rc=$?
  set -e
  checkpoint "update_end rc=$rc"
  return "$rc"
}

print_summary() {
  echo
  echo "Summary"
  echo "-------"
  if [[ "$FAILED" -eq 0 ]]; then
    echo "Result: success"
  else
    echo "Result: failed"
  fi
  echo "Backup: ${BACKUP_RESULT:-not-run}"
  echo "Restart: ${RESTART_RESULT:-not-run}"
  echo "Maintenance mode: $MAINTENANCE_MODE"
  if [[ -n "$CHECKPOINT_LOG" ]]; then
    echo "Checkpoint log: $CHECKPOINT_LOG"
  fi
  if [[ -n "$TRIAGE_DIR" ]]; then
    echo "Triage: $TRIAGE_DIR"
  else
    echo "Triage: not needed"
  fi
}

parse_args "$@"
configure_maintenance_defaults
init_checkpoint_log

step "Preflight checks"
if [[ "$USE_LIB" -eq 1 ]] && declare -F require_tools >/dev/null 2>&1; then
  require_tools openclaw python3
else
  command -v openclaw >/dev/null 2>&1 || {
    echo "Error: missing required tool: openclaw"
    false
  }
  command -v python3 >/dev/null 2>&1 || {
    echo "Error: missing required tool: python3"
    false
  }
fi
log_ok_msg "Required tools are available"

if ! acquire_update_lock; then
  false
fi

if detect_external_update_in_progress; then
  log_error_msg "Detected an existing 'openclaw update' process. Wait for it to finish before re-running safe-update."
  false
fi
log_ok_msg "No concurrent update in progress"

if [[ -z "$UPDATE_BINARY" ]]; then
  OPENCLAW_BIN="$(command -v openclaw 2>/dev/null || true)"
  if [[ "$OPENCLAW_BIN" == "/usr/local/bin/openclaw" ]] && [[ -x "/usr/bin/openclaw" ]]; then
    UPDATE_BINARY="/usr/bin/openclaw"
  else
    UPDATE_BINARY="openclaw"
  fi
fi
log_ok_msg "Update binary selected: $UPDATE_BINARY"
checkpoint "update_binary=$UPDATE_BINARY"

if [[ "$MAINTENANCE_MODE" -eq 1 ]]; then
  if "$UPDATE_BINARY" update --help >/tmp/openclaw-update-help.$$.txt 2>&1; then
    if grep -q -- '--timeout' /tmp/openclaw-update-help.$$.txt; then
      UPDATE_CMD_EXTRA_ARGS+=(--yes --no-restart --timeout "$UPDATE_TIMEOUT_SEC")
      if grep -q -- '--json' /tmp/openclaw-update-help.$$.txt; then
        UPDATE_CMD_EXTRA_ARGS+=(--json)
      fi
    fi
  fi
  rm -f /tmp/openclaw-update-help.$$.txt 2>/dev/null || true
  log_warn_msg "Maintenance mode enabled (baseline=${BASELINE_TIMEOUT_SEC}s backup=${BACKUP_TIMEOUT_SEC}s update=${UPDATE_TIMEOUT_SEC}s post=${POST_UPDATE_TIMEOUT_SEC}s heartbeat=${HEARTBEAT_SEC}s)"
  checkpoint "maintenance_defaults baseline=$BASELINE_TIMEOUT_SEC backup=$BACKUP_TIMEOUT_SEC update=$UPDATE_TIMEOUT_SEC post=$POST_UPDATE_TIMEOUT_SEC heartbeat=$HEARTBEAT_SEC"
  if [[ "${#UPDATE_CMD_EXTRA_ARGS[@]}" -gt 0 ]]; then
    checkpoint "maintenance_update_args=${UPDATE_CMD_EXTRA_ARGS[*]}"
  else
    checkpoint "maintenance_update_args=none"
  fi
fi

step "Baseline checks (best-effort)"
run_with_timeout "$BASELINE_TIMEOUT_SEC" openclaw status --all || true

if run_with_timeout "$BASELINE_TIMEOUT_SEC" openclaw health --json >/dev/null 2>&1; then
  run_with_timeout "$BASELINE_TIMEOUT_SEC" openclaw health --json || true
else
  run_with_timeout "$BASELINE_TIMEOUT_SEC" openclaw health || true
fi

if run_with_timeout "$BASELINE_TIMEOUT_SEC" openclaw channels status --probe >/dev/null 2>&1; then
  run_with_timeout "$BASELINE_TIMEOUT_SEC" openclaw channels status --probe || true
else
  run_with_timeout "$BASELINE_TIMEOUT_SEC" openclaw channels status || true
fi
log_ok_msg "Baseline checks completed"

step "Backup pre-update"
BACKUP_RESULT="failed"
if run_with_timeout "$BACKUP_TIMEOUT_SEC" openclaw backup create --verify; then
  BACKUP_RESULT="openclaw backup create --verify"
  log_ok_msg "OpenClaw backup created and verified"
else
  log_warn_msg "OpenClaw backup command failed/timed out/unavailable; creating tar fallback"
  BACKUP_DIR="$HOME/.openclaw-update-backups"
  BACKUP_FILE="$BACKUP_DIR/openclaw-home-$(timestamp_now).tar.gz"
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR" 2>/dev/null || true

  python3 - "$HOME" "$BACKUP_FILE" <<'PY'
import os
import sys
import tarfile
from datetime import datetime, timezone

home = os.path.expanduser(sys.argv[1])
archive_path = os.path.expanduser(sys.argv[2])
state_dir = os.path.join(home, ".openclaw")

if not os.path.isdir(state_dir):
    raise SystemExit("missing state directory: ~/.openclaw")

os.makedirs(os.path.dirname(archive_path), exist_ok=True)

# Keep fallback backups fast and deterministic on large hosts:
# include core config/identity/runtime files and skip heavy transcript trees.
include_rel = [
    "openclaw.json",
    "exec-approvals.json",
    "auth-profiles.json",
    "credentials",
    "cron",
    "workspace/workspaces",
    "workspace/AGENTS.md",
    "workspace/TEAM.md",
    "workspace/SOUL.md",
    "workspace/USER.md",
    "state",
    "plugins",
    "channels",
]

manifest = [
    "safe-update fallback backup",
    f"generated_at_utc={datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}",
    "source=~/.openclaw",
    "included_entries:",
]
manifest.extend(f"- {item}" for item in include_rel)
manifest.append("excluded_heavy_entries: agents/sessions, logs, workspace/external, workspace/output, workspace/node_modules")

with tarfile.open(archive_path, "w:gz") as tar:
    for rel in include_rel:
        abs_path = os.path.join(state_dir, rel)
        if os.path.exists(abs_path):
            tar.add(abs_path, arcname=os.path.join(".openclaw", rel), recursive=True)

    manifest_bytes = ("\n".join(manifest) + "\n").encode("utf-8")
    info = tarfile.TarInfo(name=".openclaw/BACKUP_MANIFEST.txt")
    info.size = len(manifest_bytes)
    info.mtime = int(datetime.now(timezone.utc).timestamp())
    info.mode = 0o600
    tar.addfile(info, fileobj=__import__("io").BytesIO(manifest_bytes))
PY
  chmod 600 "$BACKUP_FILE"
  BACKUP_RESULT="tarball $BACKUP_FILE"
  log_ok_msg "Fallback backup created: $BACKUP_FILE"
fi

step "Update OpenClaw"
if run_update_with_observability; then
  UPDATE_EXIT_CODE=0
else
  UPDATE_EXIT_CODE="$?"
fi

if [[ "$UPDATE_EXIT_CODE" -eq 124 ]]; then
  UPDATE_TIMED_OUT=1
  LAST_STEP_LABEL="Update OpenClaw (timeout)"
  log_error_msg "openclaw update timed out after ${UPDATE_TIMEOUT_SEC}s"
  false
fi

if [[ "$UPDATE_EXIT_CODE" -ne 0 ]]; then
  LAST_STEP_LABEL="Update OpenClaw (exit $UPDATE_EXIT_CODE)"
  log_error_msg "openclaw update failed with exit code $UPDATE_EXIT_CODE"
  false
fi
log_ok_msg "Update command completed"

step "Restart gateway"
if openclaw gateway restart; then
  RESTART_RESULT="openclaw gateway restart"
  log_ok_msg "Gateway restarted via openclaw"
elif command -v systemctl >/dev/null 2>&1; then
  log_warn_msg "openclaw gateway restart failed; trying systemctl --user"
  if systemctl --user restart openclaw-gateway.service; then
    RESTART_RESULT="systemctl --user restart openclaw-gateway.service"
    log_ok_msg "Gateway restarted via systemctl --user"
  else
    RESTART_RESULT="failed"
    log_error_msg "Gateway restart failed in both methods"
    false
  fi
else
  RESTART_RESULT="failed"
  log_error_msg "Gateway restart failed and systemctl is unavailable"
  false
fi

step "Verify post-update"
POST_UPDATE_SCRIPT="$SCRIPT_DIR/post-update.sh"
if [[ -f "$POST_UPDATE_SCRIPT" ]]; then
  run_with_timeout "$POST_UPDATE_TIMEOUT_SEC" bash "$POST_UPDATE_SCRIPT"
else
  log_warn_msg "post-update.sh not found; running minimal verification"
  if openclaw health --json >/dev/null 2>&1; then
    openclaw health --json || true
  else
    openclaw health || true
  fi
  openclaw status --all || true
  if openclaw channels status --probe >/dev/null 2>&1; then
    openclaw channels status --probe || true
  else
    openclaw channels status || true
  fi
fi
log_ok_msg "Post-update verification completed"

step "Final summary"
print_summary
