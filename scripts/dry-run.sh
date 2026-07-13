#!/usr/bin/env bash
# Dry-run chatgpt OAuth handler with mock stdin (offline).
# Verifies the script contract without hitting OpenAI:
#   - clear → {ok:true}
#   - token (missing file) → {access_token:null}
#   - token (expired + no refresh) → {access_token:null}
#   - token (valid fixture) → access_token + optional chatgpt-account-id header
#   - unknown action → ok:false
#   - never crashes; always emits one JSON object
set -u
cd "$(dirname "$0")/.."
TOK="$(mktemp -d)/chatgpt.json"
trap 'rm -rf "$(dirname "$TOK")"' EXIT

run() { # name stdin_json
  local name="$1" stdin="$2"
  printf '%s\n' "--- $name ---"
  printf '%s' "$stdin" | ./oauth/oauth.sh 2>/tmp/ccgpt_err
  local rc=$?
  if [ $rc -ne 0 ]; then printf 'EXIT %d\n' "$rc"; fi
  if [ -s /tmp/ccgpt_err ]; then printf 'STDERR: %s\n' "$(cat /tmp/ccgpt_err)"; fi
}

run "clear" "$(jq -n --arg t "$TOK" \
  '{action:"clear", provider_id:"chatgpt", token_path:$t, workspace:".", timestamp:1}')"

run "token (missing file)" "$(jq -n --arg t "${TOK}.missing" \
  '{action:"token", provider_id:"chatgpt", token_path:$t, workspace:".", timestamp:1}')"

# Fixture: expired access, no refresh → null
jq -n '{access_token:"stale", refresh_token:null, expires_at:1, account_id:"acct-1"}' >"$TOK"
run "token (expired, no refresh)" "$(jq -n --arg t "$TOK" \
  '{action:"token", provider_id:"chatgpt", token_path:$t, workspace:".", timestamp:1}')"

# Fixture: still-valid access + account_id → headers present
exp=$(( $(date +%s) + 3600 ))
jq -n --argjson e "$exp" \
  '{access_token:"live-token", refresh_token:null, expires_at:$e, account_id:"acct-live"}' >"$TOK"
run "token (valid + account header)" "$(jq -n --arg t "$TOK" \
  '{action:"token", provider_id:"chatgpt", token_path:$t, workspace:".", timestamp:1}')"

run "unknown action" "$(jq -n --arg t "$TOK" \
  '{action:"bogus", provider_id:"chatgpt", token_path:$t, workspace:".", timestamp:1}')"

# complete without pending should fail softly
run "complete (missing pending)" "$(jq -n --arg t "$TOK" \
  '{action:"complete", provider_id:"chatgpt", token_path:$t, code:"done", workspace:".", timestamp:1}')"

echo
echo "=== dry-run finished (offline contract OK if no EXIT lines above) ==="
