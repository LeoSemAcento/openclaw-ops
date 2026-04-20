#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"

require_tools git python3 grep sed tail || exit 1

BACKUP_CRON_PATH="${OPENCLAW_BACKUP_CRON_PATH:-/etc/cron.d/openclaw-backup}"
BACKUP_SCRIPT="${OPENCLAW_BACKUP_SCRIPT:-/root/.openclaw/backup/daily_backup_github.py}"
BACKUP_REPO="${OPENCLAW_BACKUP_REPO:-/root/.openclaw/backup/timestamps}"
BACKUP_LOG="${OPENCLAW_BACKUP_LOG:-/var/log/openclaw-backup.log}"

DRY_RUN=1
HISTORY_SCAN=1
LOG_LINES=40
MAX_LOG_AGE_HOURS=36
ALERT_ON_FAILURE="${OPENCLAW_BACKUP_HEALTH_ALERT_ON_FAILURE:-1}"
ALERT_TELEGRAM_TOKEN="${OPENCLAW_BACKUP_HEALTH_TELEGRAM_BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-}}"
ALERT_TELEGRAM_CHAT_ID="${OPENCLAW_BACKUP_HEALTH_TELEGRAM_CHAT_ID:-${OPENCLAW_CREDIT_NOTIFY_CHAT_ID:-}}"
VERBOSE=0

failures=()
warnings=()
passes=()

usage() {
  cat <<'USAGE'
Usage: scripts/backup-health-monthly.sh [options]

Monthly health check for the OpenClaw GitHub backup pipeline.

Options:
  --no-dry-run        Skip `daily_backup_github.py --dry --force`
  --no-history-scan   Skip full token-pattern scan across reachable history
  --log-lines N       Tail the last N log lines (default: 40)
  --max-log-age-hours N
                      Fail if backup log mtime is older than N hours (default: 36)
  --no-alert          Disable failure alert dispatch
  --verbose           Print verbose details
  -h, --help          Show this help
USAGE
}

record_pass() {
  local message="$1"
  passes+=("$message")
  log_ok "$message"
}

record_warn() {
  local message="$1"
  warnings+=("$message")
  log_warn "$message"
}

record_fail() {
  local message="$1"
  failures+=("$message")
  log_error "$message"
}

log_verbose() {
  if [[ "$VERBOSE" -eq 1 ]]; then
    printf '%s\n' "$1"
  fi
}

check_cron() {
  if [[ ! -f "$BACKUP_CRON_PATH" ]]; then
    record_fail "Cron file missing: $BACKUP_CRON_PATH"
    return
  fi

  if grep -Eq 'daily_backup_github\.py' "$BACKUP_CRON_PATH"; then
    record_pass "Cron file present and references daily_backup_github.py"
  else
    record_fail "Cron file present but missing daily_backup_github.py entry"
  fi
}

check_script_compile() {
  if [[ ! -f "$BACKUP_SCRIPT" ]]; then
    record_fail "Backup script missing: $BACKUP_SCRIPT"
    return
  fi

  if python3 -m py_compile "$BACKUP_SCRIPT" >/dev/null 2>&1; then
    record_pass "Backup script compiles: $BACKUP_SCRIPT"
  else
    record_fail "Backup script failed py_compile: $BACKUP_SCRIPT"
  fi
}

check_repo() {
  if git -C "$BACKUP_REPO" rev-parse --git-dir >/dev/null 2>&1; then
    record_pass "Backup repository is valid: $BACKUP_REPO"
  else
    record_fail "Backup repository is not a git repo: $BACKUP_REPO"
  fi
}

check_origin_tokenless() {
  local origin
  origin="$(git -C "$BACKUP_REPO" remote get-url origin 2>/dev/null || true)"

  if [[ -z "$origin" ]]; then
    record_fail "origin remote is missing"
    return
  fi

  if echo "$origin" | grep -qiE '(x-access-token|gh[pousr]_|github_pat_|oauth|://[^/]+:[^/]+@|://[^/]+@)'; then
    record_fail "origin contains credential-like data: $origin"
    return
  fi

  if [[ "$origin" != https://github.com/* ]]; then
    record_warn "origin is tokenless but non-standard host: $origin"
  else
    record_pass "origin is tokenless and points to GitHub"
  fi
}

run_dry_run() {
  local output
  local rc=0

  if [[ "$DRY_RUN" -ne 1 ]]; then
    record_warn "Dry-run check skipped (--no-dry-run)"
    return
  fi

  set +e
  output="$(python3 "$BACKUP_SCRIPT" --dry --force 2>&1)"
  rc=$?
  set -e

  if [[ "$VERBOSE" -eq 1 ]]; then
    printf '%s\n' "$output" | sanitize_sensitive
  fi

  if [[ "$rc" -ne 0 ]]; then
    record_fail "Dry-run execution failed (exit=$rc)"
    return
  fi

  if echo "$output" | grep -Fq 'Backup completed successfully'; then
    record_pass "Dry-run completed successfully"
  else
    record_warn "Dry-run exited 0 but success marker not found"
  fi
}

scan_history_for_tokens() {
  local patterns
  local count=0
  local rev

  if [[ "$HISTORY_SCAN" -ne 1 ]]; then
    record_warn "History token scan skipped (--no-history-scan)"
    return
  fi

  patterns='gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-or-v1-[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|gsk_[A-Za-z0-9]{20,}|\b[0-9]{6,}:[A-Za-z0-9_-]{20,}\b'

  while read -r rev; do
    if git -C "$BACKUP_REPO" grep -I -n -E "$patterns" "$rev" -- snapshots >/dev/null 2>&1; then
      count=$((count + 1))
    fi
  done < <(git -C "$BACKUP_REPO" rev-list --all)

  if [[ "$count" -eq 0 ]]; then
    record_pass "History token-pattern scan clean across reachable commits"
  else
    record_fail "History token-pattern scan found matches in $count commit(s)"
  fi
}

inspect_log_tail() {
  local tail_output

  if [[ ! -f "$BACKUP_LOG" ]]; then
    record_warn "Backup log missing: $BACKUP_LOG"
    return
  fi

  tail_output="$(tail -n "$LOG_LINES" "$BACKUP_LOG" 2>/dev/null || true)"
  if [[ -z "$tail_output" ]]; then
    record_warn "Backup log is empty: $BACKUP_LOG"
    return
  fi

  if echo "$tail_output" | grep -Fq 'Backup completed successfully'; then
    record_pass "Recent backup log includes success marker"
  else
    record_warn "Recent backup log has no success marker"
  fi

  log_verbose "Last $LOG_LINES lines from $BACKUP_LOG:"
  if [[ "$VERBOSE" -eq 1 ]]; then
    printf '%s\n' "$tail_output" | sanitize_sensitive
  fi
}

check_log_freshness() {
  local mtime now max_age_seconds age_seconds

  if [[ ! -f "$BACKUP_LOG" ]]; then
    record_fail "Backup log missing for freshness check: $BACKUP_LOG"
    return
  fi

  mtime="$(file_mtime "$BACKUP_LOG" || true)"
  now="$(epoch_now || true)"
  if [[ -z "$mtime" || -z "$now" || ! "$mtime" =~ ^[0-9]+$ || ! "$now" =~ ^[0-9]+$ ]]; then
    record_warn "Could not compute log freshness (mtime/now unavailable)"
    return
  fi

  max_age_seconds=$((MAX_LOG_AGE_HOURS * 3600))
  age_seconds=$((now - mtime))
  if (( age_seconds < 0 )); then
    age_seconds=0
  fi

  if (( age_seconds <= max_age_seconds )); then
    record_pass "Backup log freshness OK (${age_seconds}s <= ${max_age_seconds}s)"
  else
    record_fail "Backup log too old (${age_seconds}s > ${max_age_seconds}s)"
  fi
}

send_failure_alert() {
  local host short_host message detail_lines line

  if [[ "$ALERT_ON_FAILURE" -ne 1 ]]; then
    log_verbose "Failure alert disabled"
    return
  fi

  host="$(hostname 2>/dev/null || echo unknown-host)"
  short_host="${host%%.*}"
  message="openclaw backup health FAILED on ${short_host}: failures=${#failures[@]}, warnings=${#warnings[@]}"

  detail_lines=""
  for line in "${failures[@]}"; do
    detail_lines+=$'\n'"- ${line}"
  done
  message+="${detail_lines}"

  if command -v openclaw >/dev/null 2>&1; then
    if openclaw system event --mode now --text "$message" >/dev/null 2>&1; then
      log_ok "Failure alert sent via openclaw system event"
    else
      log_warn "Failed to send failure alert via openclaw system event"
    fi
  else
    log_warn "openclaw CLI not found; system-event alert skipped"
  fi

  if [[ -n "$ALERT_TELEGRAM_TOKEN" && -n "$ALERT_TELEGRAM_CHAT_ID" ]]; then
    if curl -fsS -X POST \
      "https://api.telegram.org/bot${ALERT_TELEGRAM_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${ALERT_TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${message}" \
      >/dev/null 2>&1; then
      log_ok "Failure alert sent to Telegram"
    else
      log_warn "Failed to send failure alert to Telegram"
    fi
  else
    log_verbose "Telegram alert skipped (token/chat_id not configured)"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-dry-run)
      DRY_RUN=0
      shift
      ;;
    --no-history-scan)
      HISTORY_SCAN=0
      shift
      ;;
    --log-lines)
      LOG_LINES="${2:-}"
      if [[ -z "$LOG_LINES" || ! "$LOG_LINES" =~ ^[0-9]+$ || "$LOG_LINES" -lt 1 ]]; then
        printf 'Invalid --log-lines value: %s\n' "${2:-}" >&2
        exit 1
      fi
      shift 2
      ;;
    --max-log-age-hours)
      MAX_LOG_AGE_HOURS="${2:-}"
      if [[ -z "$MAX_LOG_AGE_HOURS" || ! "$MAX_LOG_AGE_HOURS" =~ ^[0-9]+$ || "$MAX_LOG_AGE_HOURS" -lt 1 ]]; then
        printf 'Invalid --max-log-age-hours value: %s\n' "${2:-}" >&2
        exit 1
      fi
      shift 2
      ;;
    --no-alert)
      ALERT_ON_FAILURE=0
      shift
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage
      exit 1
      ;;
  esac
done

echo -e "${BLD}OpenClaw GitHub Backup Monthly Health Check${RST}"
echo "Cron path:   $BACKUP_CRON_PATH"
echo "Script path: $BACKUP_SCRIPT"
echo "Repo path:   $BACKUP_REPO"
echo "Log path:    $BACKUP_LOG"
echo

if [[ -z "$ALERT_ON_FAILURE" || ! "$ALERT_ON_FAILURE" =~ ^[01]$ ]]; then
  printf 'Invalid OPENCLAW_BACKUP_HEALTH_ALERT_ON_FAILURE value: %s\n' "$ALERT_ON_FAILURE" >&2
  exit 1
fi

check_cron
check_script_compile
check_repo
check_origin_tokenless
run_dry_run
scan_history_for_tokens
inspect_log_tail
check_log_freshness

echo
echo -e "${BLD}Summary${RST}"
echo "Passed:  ${#passes[@]}"
echo "Warnings:${#warnings[@]}"
echo "Failed:  ${#failures[@]}"

if [[ "${#failures[@]}" -gt 0 ]]; then
  send_failure_alert
  exit 1
fi

exit 0
