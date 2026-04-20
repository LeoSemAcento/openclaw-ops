#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_SH="$SCRIPT_DIR/lib.sh"

if [[ -f "$LIB_SH" ]]; then
  # shellcheck disable=SC1091
  source "$LIB_SH"
fi

if ! declare -F log_info >/dev/null 2>&1; then
  log_info() { printf '%s\n' "$1"; }
fi
if ! declare -F log_ok >/dev/null 2>&1; then
  log_ok() { printf '[OK] %s\n' "$1"; }
fi
if ! declare -F log_warn >/dev/null 2>&1; then
  log_warn() { printf '[WARN] %s\n' "$1"; }
fi
if ! declare -F log_error >/dev/null 2>&1; then
  log_error() { printf '[ERR] %s\n' "$1"; }
fi

warnings=()
captured_files=()
successful_commands=0

usage() {
  cat <<'USAGE'
Usage: scripts/capture-triage.sh [--output <dir>]

Captura snapshots de triagem para rollback seguro do OpenClaw.

Options:
  --output <dir>   Diretório de saída (default: ~/.openclaw/triage/<timestamp>/)
  -h, --help       Exibe esta ajuda
USAGE
}

record_warning() {
  local msg="$1"
  warnings+=("$msg")
  log_warn "$msg"
}

sanitize_to_file() {
  local src="$1"
  local dst="$2"
  if declare -F sanitize_sensitive >/dev/null 2>&1; then
    if ! sanitize_sensitive <"$src" >"$dst"; then
      cat "$src" >"$dst"
      record_warning "sanitize_sensitive falhou para $(basename "$dst"); arquivo bruto mantido"
    fi
  else
    cat "$src" >"$dst"
  fi
}

has_timeout_cmd=0
if command -v timeout >/dev/null 2>&1; then
  has_timeout_cmd=1
fi

run_capture() {
  local label="$1"
  local outfile="$2"
  local timeout_secs="$3"
  shift 3
  local cmd=("$@")

  local raw_file
  raw_file="$(mktemp "${OUTPUT_DIR}/.${outfile}.raw.XXXXXX")"
  local final_file="$OUTPUT_DIR/$outfile"
  local rc=0

  {
    printf '# label: %s\n' "$label"
    printf '# captured_at_utc: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
    printf '# timeout_seconds: %s\n' "$timeout_secs"
    printf '# command:'
    printf ' %q' "${cmd[@]}"
    printf '\n\n'
  } >"$raw_file"

  set +e
  if [[ "$has_timeout_cmd" -eq 1 ]]; then
    timeout --foreground "$timeout_secs" "${cmd[@]}" >>"$raw_file" 2>&1
    rc=$?
  else
    "${cmd[@]}" >>"$raw_file" 2>&1
    rc=$?
  fi
  set -e

  sanitize_to_file "$raw_file" "$final_file"
  rm -f "$raw_file"
  captured_files+=("$final_file")

  if [[ "$rc" -eq 0 ]]; then
    successful_commands=$((successful_commands + 1))
    log_ok "$label -> $final_file"
    return 0
  fi

  if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
    record_warning "$label excedeu timeout (${timeout_secs}s); saída parcial salva em $final_file"
  else
    record_warning "$label falhou (exit=$rc); saída salva em $final_file"
  fi
  return 1
}

OUTPUT_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      if [[ $# -lt 2 ]]; then
        log_error "Flag --output requer um diretório."
        usage
        exit 1
      fi
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_error "Argumento desconhecido: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$OUTPUT_DIR" ]]; then
  timestamp="$(date +%Y%m%d-%H%M%S)"
  OUTPUT_DIR="$HOME/.openclaw/triage/$timestamp"
fi

if [[ "$OUTPUT_DIR" == "~"* ]]; then
  OUTPUT_DIR="${OUTPUT_DIR/#\~/$HOME}"
fi

mkdir -p "$OUTPUT_DIR"

log_info "Capturando triagem em: $OUTPUT_DIR"

run_capture "openclaw --version" "openclaw-version.txt" 8 openclaw --version || true
run_capture "openclaw status --all" "openclaw-status-all.txt" 12 openclaw status --all || true

if ! run_capture "openclaw health --json" "openclaw-health-json.txt" 12 openclaw health --json; then
  run_capture "openclaw health (fallback)" "openclaw-health.txt" 12 openclaw health || true
fi

if ! run_capture "openclaw channels status --probe" "openclaw-channels-status-probe.txt" 12 openclaw channels status --probe; then
  run_capture "openclaw channels status (fallback)" "openclaw-channels-status.txt" 12 openclaw channels status || true
fi

if ! run_capture "openclaw logs --limit 400" "openclaw-logs-limit-400.txt" 20 openclaw logs --limit 400; then
  run_capture "openclaw logs (fallback)" "openclaw-logs.txt" 20 openclaw logs || true
fi

run_capture "openclaw gateway status" "openclaw-gateway-status.txt" 12 openclaw gateway status || true

if command -v systemctl >/dev/null 2>&1; then
  run_capture \
    "systemctl --user status openclaw-gateway.service --no-pager" \
    "systemctl-user-openclaw-gateway-status.txt" \
    12 \
    systemctl --user status openclaw-gateway.service --no-pager || true
else
  skip_file="$OUTPUT_DIR/systemctl-user-openclaw-gateway-status.txt"
  printf 'systemctl não encontrado; captura ignorada.\n' >"$skip_file"
  captured_files+=("$skip_file")
  record_warning "systemctl indisponível; status do openclaw-gateway.service não coletado"
fi

summary_file="$OUTPUT_DIR/summary.txt"
{
  printf 'capture_dir: %s\n' "$OUTPUT_DIR"
  printf 'successful_commands: %s\n' "$successful_commands"
  printf 'artifacts: %s\n' "${#captured_files[@]}"
  printf 'warnings: %s\n' "${#warnings[@]}"
  if [[ ${#warnings[@]} -gt 0 ]]; then
    printf '\nwarning_list:\n'
    for warning in "${warnings[@]}"; do
      printf -- '- %s\n' "$warning"
    done
  fi
} >"$summary_file"
captured_files+=("$summary_file")

log_info ""
log_info "Resumo final:"
log_info "  Diretório: $OUTPUT_DIR"
log_info "  Sucessos: $successful_commands"
log_info "  Artefatos: ${#captured_files[@]}"
log_info "  Warnings: ${#warnings[@]}"
log_info "  Summary: $summary_file"

if [[ "$successful_commands" -gt 0 || "${#captured_files[@]}" -gt 0 ]]; then
  exit 0
fi

exit 1
