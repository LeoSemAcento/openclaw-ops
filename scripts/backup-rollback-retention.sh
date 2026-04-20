#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"

require_tools find rm || exit 1

BACKUP_ROOT="${OPENCLAW_BACKUP_ROOT:-/root/.openclaw/backup}"
RETENTION_DAYS=30
APPLY=0
VERBOSE=0

usage() {
  cat <<'USAGE'
Usage: scripts/backup-rollback-retention.sh [options]

Cleanup policy for pre-rewrite rollback artifacts:
- timestamps-pre-rewrite-*.git
- timestamps-pre-rewrite-*.bundle

Options:
  --days N     Retention in days (default: 30)
  --apply      Perform deletion (default is dry-run)
  --verbose    Print every candidate path
  -h, --help   Show this help
USAGE
}

log_verbose() {
  if [[ "$VERBOSE" -eq 1 ]]; then
    printf '%s\n' "$1"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)
      RETENTION_DAYS="${2:-}"
      if [[ -z "$RETENTION_DAYS" || ! "$RETENTION_DAYS" =~ ^[0-9]+$ || "$RETENTION_DAYS" -lt 1 ]]; then
        printf 'Invalid --days value: %s\n' "${2:-}" >&2
        exit 1
      fi
      shift 2
      ;;
    --apply)
      APPLY=1
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

if [[ ! -d "$BACKUP_ROOT" ]]; then
  printf 'Backup root missing: %s\n' "$BACKUP_ROOT" >&2
  exit 1
fi

resolved_root="$(cd "$BACKUP_ROOT" && pwd)"
echo "Rollback retention root: $resolved_root"
echo "Retention days: $RETENTION_DAYS"
echo "Mode: $([[ "$APPLY" -eq 1 ]] && echo apply || echo dry-run)"

declare -a candidates=()

while IFS= read -r path; do
  [[ -n "$path" ]] && candidates+=("$path")
done < <(
  find "$resolved_root" -maxdepth 1 \
    \( -type d -name 'timestamps-pre-rewrite-*.git' -o -type f -name 'timestamps-pre-rewrite-*.bundle' \) \
    -mtime +"$RETENTION_DAYS" | sort
)

if [[ "${#candidates[@]}" -eq 0 ]]; then
  log_ok "No rollback artifacts older than ${RETENTION_DAYS} day(s)"
  exit 0
fi

echo "Candidates: ${#candidates[@]}"
for candidate in "${candidates[@]}"; do
  log_verbose "candidate=$candidate"
done

if [[ "$APPLY" -ne 1 ]]; then
  log_warn "Dry-run only. Re-run with --apply to delete candidates."
  exit 0
fi

removed=0
for candidate in "${candidates[@]}"; do
  if [[ -d "$candidate" ]]; then
    rm -rf -- "$candidate"
  else
    rm -f -- "$candidate"
  fi
  removed=$((removed + 1))
done

log_ok "Removed rollback artifacts: $removed"
exit 0
