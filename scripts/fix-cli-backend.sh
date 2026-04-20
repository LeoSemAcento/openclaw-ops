#!/usr/bin/env bash
# fix-cli-backend.sh — configure Claude CLI as a subprocess backend for OpenClaw
#
# The onboarding wizard (models auth login --provider anthropic --method cli)
# sets the cliBackends key to "claude" instead of "claude-cli", which silently
# fails because model IDs use the "claude-cli/" prefix. This script detects and
# fixes that mismatch, and ensures no claude-cli API provider entry exists
# (the CLI subprocess handles its own auth — adding it as an API provider
# creates a broken HTTP path that bypasses the subprocess).
#
# Run: bash fix-cli-backend.sh
# Safe to re-run — idempotent.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/lib.sh"

FIXED=()
WARNINGS=()
OK=()

CONFIG="$HOME/.openclaw/openclaw.json"
AUTH_PROFILES="$HOME/.openclaw/auth-profiles.json"
AGENTS_DIR="$HOME/.openclaw/agents"

echo ""
echo -e "${BLD}OpenClaw CLI Backend Fix${RST}"
echo "────────────────────────────────"

# ── Preflight ────────────────────────────────────────────────────────────────
require_tools python3 || exit 1

if [[ ! -f "$CONFIG" ]]; then
  log_error "Missing $CONFIG — run openclaw onboard first"
  exit 1
fi

# ── Step 1: Claude CLI auth ──────────────────────────────────────────────────
echo ""
echo -e "${BLD}[1] Claude CLI auth${RST}"
if command -v claude &>/dev/null; then
  AUTH_JSON="$(claude auth status 2>&1 || true)"
  API_PROVIDER="$(echo "$AUTH_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('apiProvider',''))" 2>/dev/null || echo "")"
  SUB_TYPE="$(echo "$AUTH_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('subscriptionType',''))" 2>/dev/null || echo "")"

  if [[ "$API_PROVIDER" == "firstParty" ]]; then
    log_ok "Claude CLI authenticated (apiProvider=firstParty, subscriptionType=$SUB_TYPE)"
  else
    log_warn "Claude CLI not authenticated as firstParty (got: $API_PROVIDER)"
    log_warn "Run: claude auth login"
    WARNINGS+=("Claude CLI auth not firstParty — run: claude auth login")
  fi
else
  log_error "claude CLI not found in PATH"
  log_warn "Install: npm install -g @anthropic-ai/claude-code"
  WARNINGS+=("claude CLI not installed")
fi

# ── Step 2: auth-profiles.json — ensure anthropic:claude-cli profile ─────────
echo ""
echo -e "${BLD}[2] Auth profile: anthropic:claude-cli${RST}"
if [[ -f "$AUTH_PROFILES" ]]; then
  HAS_CLI_PROFILE="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print('yes' if 'anthropic:claude-cli' in d.get('profiles', {}) else 'no')
" "$AUTH_PROFILES" 2>/dev/null || echo "error")"

  if [[ "$HAS_CLI_PROFILE" == "yes" ]]; then
    log_ok "anthropic:claude-cli profile exists"
    OK+=("auth profile")
  else
    log_warn "Missing anthropic:claude-cli profile — adding"
    python3 -c "
import json, sys
f = sys.argv[1]
d = json.load(open(f))
d.setdefault('profiles', {})
d['profiles']['anthropic:claude-cli'] = {'type': 'claude-cli', 'provider': 'anthropic'}
with open(f, 'w') as out:
    json.dump(d, out, indent=2)
print('added')
" "$AUTH_PROFILES" 2>/dev/null && log_ok "Added anthropic:claude-cli profile" && FIXED+=("auth profile added") || \
      log_error "Failed to add profile"
  fi
else
  log_warn "No auth-profiles.json found — creating"
  python3 -c "
import json
d = {'version': 1, 'profiles': {'anthropic:claude-cli': {'type': 'claude-cli', 'provider': 'anthropic'}}}
with open('$AUTH_PROFILES', 'w') as f:
    json.dump(d, f, indent=2)
" 2>/dev/null && FIXED+=("auth-profiles.json created") || log_error "Failed to create auth-profiles.json"
fi

# ── Step 3: cliBackends — must use key "claude-cli", not "claude" ────────────
echo ""
echo -e "${BLD}[3] cliBackends config${RST}"

CLI_BACKEND_STATUS="$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
backends = cfg.get('agents', {}).get('defaults', {}).get('cliBackends', {})
if 'claude-cli' in backends:
    print('ok')
elif 'claude' in backends:
    print('wrong-key')
else:
    print('missing')
" "$CONFIG" 2>/dev/null || echo "error")"

case "$CLI_BACKEND_STATUS" in
  ok)
    log_ok "cliBackends has correct 'claude-cli' key"
    OK+=("cliBackends key")
    ;;
  wrong-key)
    log_warn "cliBackends uses 'claude' key — renaming to 'claude-cli'"
    python3 -c "
import json, sys
f = sys.argv[1]
cfg = json.load(open(f))
backends = cfg['agents']['defaults']['cliBackends']
backends['claude-cli'] = backends.pop('claude')
with open(f, 'w') as out:
    json.dump(cfg, out, indent=2)
print('renamed')
" "$CONFIG" 2>/dev/null && log_ok "Renamed cliBackends key: claude -> claude-cli" && FIXED+=("cliBackends key renamed") || \
      log_error "Failed to rename cliBackends key"
    ;;
  missing)
    log_warn "No cliBackends section — adding"
    python3 -c "
import json, sys
f = sys.argv[1]
cfg = json.load(open(f))
cfg.setdefault('agents', {}).setdefault('defaults', {})
cfg['agents']['defaults']['cliBackends'] = {
    'claude-cli': {
        'command': 'claude',
        'args': ['-p', '--output-format', 'stream-json', '--verbose', '--permission-mode', 'bypassPermissions'],
        'output': 'jsonl',
        'modelArg': '--model',
        'sessionArg': '--session-id',
        'serialize': True
    }
}
with open(f, 'w') as out:
    json.dump(cfg, out, indent=2)
print('added')
" "$CONFIG" 2>/dev/null && log_ok "Added cliBackends.claude-cli config" && FIXED+=("cliBackends section added") || \
      log_error "Failed to add cliBackends"
    ;;
  *)
    log_error "Could not read cliBackends config"
    ;;
esac

# ── Step 4: models.providers must NOT have claude-cli ────────────────────────
echo ""
echo -e "${BLD}[4] Checking models.providers for stale claude-cli entry${RST}"

HAS_PROVIDER="$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
providers = cfg.get('models', {}).get('providers', {})
print('yes' if 'claude-cli' in providers else 'no')
" "$CONFIG" 2>/dev/null || echo "error")"

if [[ "$HAS_PROVIDER" == "yes" ]]; then
  log_warn "claude-cli found in models.providers — removing (CLI is a subprocess, not an API provider)"
  python3 -c "
import json, sys
f = sys.argv[1]
cfg = json.load(open(f))
del cfg['models']['providers']['claude-cli']
with open(f, 'w') as out:
    json.dump(cfg, out, indent=2)
print('removed')
" "$CONFIG" 2>/dev/null && log_ok "Removed claude-cli from models.providers" && FIXED+=("removed claude-cli API provider") || \
    log_error "Failed to remove"
elif [[ "$HAS_PROVIDER" == "no" ]]; then
  log_ok "No claude-cli in models.providers (correct)"
  OK+=("no API provider conflict")
else
  log_error "Could not check models.providers"
fi

# ── Step 5: Agent-level models.json cleanup ──────────────────────────────────
echo ""
echo -e "${BLD}[5] Agent-level models.json cleanup${RST}"

AGENT_MODEL_FIXES=0
if [[ -d "$AGENTS_DIR" ]]; then
  for models_file in "$AGENTS_DIR"/*/agent/models.json; do
    [[ -f "$models_file" ]] || continue
    HAS_CLI="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
providers = d.get('providers', {})
matches = [k for k in providers if 'claude-cli' in k.lower()]
print(' '.join(matches) if matches else 'clean')
" "$models_file" 2>/dev/null || echo "error")"

    if [[ "$HAS_CLI" != "clean" && "$HAS_CLI" != "error" ]]; then
      agent="$(basename "$(dirname "$(dirname "$models_file")")")"
      log_warn "Agent $agent models.json has claude-cli provider: $HAS_CLI — removing"
      python3 -c "
import json, sys
f = sys.argv[1]
d = json.load(open(f))
providers = d.get('providers', {})
for key in list(providers.keys()):
    if 'claude-cli' in key.lower():
        del providers[key]
with open(f, 'w') as out:
    json.dump(d, out, indent=2)
" "$models_file" 2>/dev/null && FIXED+=("removed provider from $agent/models.json") || log_error "Failed: $models_file"
      AGENT_MODEL_FIXES=$((AGENT_MODEL_FIXES + 1))
    fi
  done
  [[ "$AGENT_MODEL_FIXES" -eq 0 ]] && log_ok "All agent models.json clean"
fi

# ── Step 6: Agent-level auth-profiles.json cleanup ───────────────────────────
echo ""
echo -e "${BLD}[6] Agent-level auth-profiles.json cleanup${RST}"

AGENT_AUTH_FIXES=0
if [[ -d "$AGENTS_DIR" ]]; then
  for auth_file in "$AGENTS_DIR"/*/agent/auth-profiles.json; do
    [[ -f "$auth_file" ]] || continue
    HAS_CLI_AUTH="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
profiles = d.get('profiles', {})
stats = d.get('usageStats', {})
matches = []
for k in profiles:
    if 'claude-cli' in k.lower():
        matches.append('profile:' + k)
for k in stats:
    if 'claude-cli' in k.lower():
        matches.append('stats:' + k)
print(' '.join(matches) if matches else 'clean')
" "$auth_file" 2>/dev/null || echo "error")"

    if [[ "$HAS_CLI_AUTH" != "clean" && "$HAS_CLI_AUTH" != "error" ]]; then
      agent="$(basename "$(dirname "$(dirname "$auth_file")")")"
      log_warn "Agent $agent auth-profiles.json has claude-cli entries: $HAS_CLI_AUTH — removing"
      python3 -c "
import json, sys
f = sys.argv[1]
d = json.load(open(f))
for section in ['profiles', 'usageStats']:
    if section in d:
        for key in list(d[section].keys()):
            if 'claude-cli' in key.lower():
                del d[section][key]
with open(f, 'w') as out:
    json.dump(d, out, indent=2)
" "$auth_file" 2>/dev/null && FIXED+=("cleaned $agent/auth-profiles.json") || log_error "Failed: $auth_file"
      AGENT_AUTH_FIXES=$((AGENT_AUTH_FIXES + 1))
    fi
  done
  [[ "$AGENT_AUTH_FIXES" -eq 0 ]] && log_ok "All agent auth-profiles.json clean"
fi

# ── Step 7: Model ID prefix check ───────────────────────────────────────────
echo ""
echo -e "${BLD}[7] Model ID prefix check${RST}"

MODEL_PREFIX_STATUS="$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
defaults = cfg.get('agents', {}).get('defaults', {})
model = defaults.get('model', {})
primary = model.get('primary', '') if isinstance(model, dict) else str(model)
uses_cli = primary.startswith('claude-cli/')
print(f'primary={primary} uses_cli={uses_cli}')
" "$CONFIG" 2>/dev/null || echo "error")"

log_info "$MODEL_PREFIX_STATUS"

# ── Summary + restart ────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════"
echo -e "${BLD}Summary${RST}"
echo "════════════════════════════════"

if [[ ${#FIXED[@]} -gt 0 ]]; then
  echo -e "${GRN}Fixed (${#FIXED[@]}):${RST}"
  for item in "${FIXED[@]}"; do echo "  + $item"; done
fi

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  echo -e "${YLW}Warnings (${#WARNINGS[@]}):${RST}"
  for item in "${WARNINGS[@]}"; do echo "  ! $item"; done
fi

if [[ ${#OK[@]} -gt 0 ]]; then
  echo -e "${GRN}Already correct (${#OK[@]}):${RST}"
  for item in "${OK[@]}"; do echo "  = $item"; done
fi

if [[ ${#FIXED[@]} -gt 0 ]]; then
  echo ""
  echo -e "${CYN}Restarting gateway to apply changes...${RST}"
  openclaw gateway restart 2>/dev/null && log_ok "Gateway restarted" || log_error "Gateway restart failed"

  # Check for startup warmup error (expected — non-fatal)
  sleep 3
  WARMUP_ERR="$(tail -5 ~/.openclaw/logs/gateway.err.log 2>/dev/null | grep -c "startup model warmup failed" || true)"
  if [[ "$WARMUP_ERR" -gt 0 ]]; then
    log_info "Note: startup warmup warning is expected — CLI backends use a runtime path, not static model resolution"
  fi

  echo ""
  echo -e "${GRN}Done. Send a test message to verify.${RST}"
elif [[ ${#WARNINGS[@]} -gt 0 ]]; then
  echo ""
  echo -e "${YLW}Fix warnings above before testing.${RST}"
else
  echo ""
  echo -e "${GRN}Everything looks correct. No changes needed.${RST}"
fi
