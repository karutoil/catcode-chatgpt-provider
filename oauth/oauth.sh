#!/usr/bin/env bash
#
# ChatGPT Plus/Pro (Codex) OAuth plugin for Catalyst Code / catcode.
#
# Uses OpenAI's public Codex CLI client_id and the device-code flow
# (works locally and over SSH). Codex's registered loopback redirect ports
# (1455/1457 + /auth/callback) do not match the harness ephemeral /callback,
# so this plugin always uses device-code (flow=manual).
#
# Actions: login | complete | token | clear
# Requires: curl, jq, python3
#
set -euo pipefail

CLIENT_ID="app_EMoamEEZ73f0CkXaXp7hrann"
TOKEN_URL="https://auth.openai.com/oauth/token"
DEVICE_VERIFY_URL="https://auth.openai.com/codex/device"
DEVICE_USERCODE_URL="https://auth.openai.com/api/accounts/deviceauth/usercode"
DEVICE_TOKEN_URL="https://auth.openai.com/api/accounts/deviceauth/token"
DEVICE_CALLBACK="https://auth.openai.com/deviceauth/callback"

input="$(cat)"
action="$(printf '%s' "$input" | jq -r '.action')"
token_path="$(printf '%s' "$input" | jq -r '.token_path')"

mkdir -p "$(dirname "$token_path")"

# Decode chatgpt_account_id from a JWT id_token (OpenAI auth claim).
jwt_account_id() {
  local jwt="$1"
  python3 - "$jwt" <<'PY'
import json, sys, base64
jwt = sys.argv[1]
try:
    payload = jwt.split(".")[1]
    pad = "=" * (-len(payload) % 4)
    data = json.loads(base64.urlsafe_b64decode(payload + pad))
    aid = (data.get("https://api.openai.com/auth") or {}).get("chatgpt_account_id") or ""
    print(aid)
except Exception:
    print("")
PY
}

jwt_exp() {
  local jwt="$1"
  python3 - "$jwt" <<'PY'
import json, sys, base64
jwt = sys.argv[1]
try:
    payload = jwt.split(".")[1]
    pad = "=" * (-len(payload) % 4)
    data = json.loads(base64.urlsafe_b64decode(payload + pad))
    print(int(data.get("exp") or 0))
except Exception:
    print(0)
PY
}

persist_tokens() {
  # stdin: token endpoint JSON; writes $token_path
  local resp
  resp="$(cat)"
  local access refresh id_token exp account
  access="$(printf '%s' "$resp" | jq -r '.access_token // empty')"
  refresh="$(printf '%s' "$resp" | jq -r '.refresh_token // empty')"
  id_token="$(printf '%s' "$resp" | jq -r '.id_token // empty')"
  if [ -z "$access" ]; then
    echo '{"ok":false,"error":"no access_token in response"}'
    return 1
  fi
  exp="$(jwt_exp "$id_token")"
  if [ "$exp" = "0" ] || [ -z "$exp" ]; then
    exp="$(( $(date +%s) + 3600 ))"
  fi
  account="$(jwt_account_id "$id_token")"
  jq -n \
    --arg access "$access" \
    --arg refresh "$refresh" \
    --arg id_token "$id_token" \
    --arg account "$account" \
    --argjson exp "$exp" \
    '{
      access_token: $access,
      refresh_token: (if $refresh == "" then null else $refresh end),
      id_token: (if $id_token == "" then null else $id_token end),
      account_id: (if $account == "" then null else $account end),
      expires_at: $exp,
      client_id: "app_EMoamEEZ73f0CkXaXp7hrann"
    }' >"$token_path"
}

exchange_code() {
  local code="$1" redirect="$2" verifier="$3"
  curl -fsS -X POST "$TOKEN_URL" \
    -d "grant_type=authorization_code" \
    -d "code=$code" \
    -d "redirect_uri=$redirect" \
    -d "client_id=$CLIENT_ID" \
    -d "code_verifier=$verifier"
}

case "$action" in

  login)
    # Always device-code — Codex allow-lists only localhost:1455|1457/auth/callback.
    resp="$(curl -fsS -X POST "$DEVICE_USERCODE_URL" \
      -H 'Content-Type: application/json' \
      -d "{\"client_id\":\"$CLIENT_ID\"}")"
    device_auth_id="$(printf '%s' "$resp" | jq -r '.device_auth_id // empty')"
    user_code="$(printf '%s' "$resp" | jq -r '.user_code // empty')"
    interval="$(printf '%s' "$resp" | jq -r '.interval // 5')"
    if [ -z "$device_auth_id" ] || [ -z "$user_code" ]; then
      echo '{"ok":false,"error":"deviceauth/usercode failed"}'
      exit 0
    fi
    jq -n \
      --arg url "$DEVICE_VERIFY_URL" \
      --arg code "$user_code" \
      --arg daid "$device_auth_id" \
      --argjson interval "$interval" \
      '{
        url: $url,
        code: $code,
        flow: "manual",
        message: ("Open " + $url + " on any device, sign in to ChatGPT, and enter code " + $code + ". Then run /oauth-code done (or paste the user code)."),
        pending: { device_auth_id: $daid, user_code: $code, interval: $interval }
      }'
    ;;

  complete)
    device_auth_id="$(printf '%s' "$input" | jq -r '.pending.device_auth_id // empty')"
    user_code="$(printf '%s' "$input" | jq -r '.pending.user_code // .code // empty')"
    interval="$(printf '%s' "$input" | jq -r '.pending.interval // 5')"
    if [ -z "$device_auth_id" ] || [ -z "$user_code" ]; then
      echo '{"ok":false,"error":"missing device_auth_id/user_code in pending — re-run /login chatgpt"}'
      exit 0
    fi
    # Poll until approved (403/404 = pending), then exchange authorization_code.
    auth_code=""
    code_verifier=""
    poll_file="$(mktemp)"
    deadline=$(( $(date +%s) + 900 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      http_code="$(curl -sS -o "$poll_file" -w '%{http_code}' -X POST "$DEVICE_TOKEN_URL" \
        -H 'Content-Type: application/json' \
        -d "$(jq -n --arg d "$device_auth_id" --arg u "$user_code" \
              '{device_auth_id:$d, user_code:$u}')" || echo "000")"
      if [ "$http_code" = "403" ] || [ "$http_code" = "404" ]; then
        sleep "$interval"
        continue
      fi
      if [ "$http_code" != "200" ]; then
        err="$(jq -r '.error // .message // empty' "$poll_file" 2>/dev/null || true)"
        rm -f "$poll_file"
        jq -n --arg e "${err:-HTTP $http_code}" '{ok:false, error:("device poll failed: "+$e)}'
        exit 0
      fi
      auth_code="$(jq -r '.authorization_code // empty' "$poll_file")"
      code_verifier="$(jq -r '.code_verifier // empty' "$poll_file")"
      rm -f "$poll_file"
      break
    done
    rm -f "$poll_file"
    if [ -z "$auth_code" ] || [ -z "$code_verifier" ]; then
      echo '{"ok":false,"error":"device-code login timed out or incomplete"}'
      exit 0
    fi
    if ! tok="$(exchange_code "$auth_code" "$DEVICE_CALLBACK" "$code_verifier")"; then
      echo '{"ok":false,"error":"token exchange failed"}'
      exit 0
    fi
    if ! printf '%s' "$tok" | persist_tokens; then
      exit 0
    fi
    echo '{"ok":true}'
    ;;

  token)
    if [ ! -f "$token_path" ]; then
      echo '{"access_token":null}'
      exit 0
    fi
    access="$(jq -r '.access_token // empty' "$token_path")"
    expires_at="$(jq -r '.expires_at // 0' "$token_path")"
    account="$(jq -r '.account_id // empty' "$token_path")"
    now="$(date +%s)"
    if [ -z "$access" ] || [ "$expires_at" -le "$((now + 60))" ]; then
      refresh="$(jq -r '.refresh_token // empty' "$token_path")"
      if [ -z "$refresh" ]; then
        echo '{"access_token":null}'
        exit 0
      fi
      resp="$(curl -fsS -X POST "$TOKEN_URL" \
        -H 'Content-Type: application/json' \
        -d "$(jq -n --arg r "$refresh" --arg c "$CLIENT_ID" \
              '{grant_type:"refresh_token", refresh_token:$r, client_id:$c}')" \
        )" || { echo '{"access_token":null}'; exit 0; }
      if ! printf '%s' "$resp" | persist_tokens; then
        echo '{"access_token":null}'
        exit 0
      fi
      # Preserve refresh_token if the response omitted it.
      if [ -z "$(jq -r '.refresh_token // empty' "$token_path")" ] && [ -n "$refresh" ]; then
        jq --arg r "$refresh" '.refresh_token = $r' "$token_path" >"$token_path.tmp" \
          && mv "$token_path.tmp" "$token_path"
      fi
      access="$(jq -r '.access_token' "$token_path")"
      expires_at="$(jq -r '.expires_at // 0' "$token_path")"
      account="$(jq -r '.account_id // empty' "$token_path")"
      if [ -z "$account" ]; then
        idt="$(jq -r '.id_token // empty' "$token_path")"
        account="$(jwt_account_id "$idt")"
      fi
    fi
    if [ -n "$account" ]; then
      jq -n --arg t "$access" --argjson e "$expires_at" --arg a "$account" \
        '{access_token:$t, expires_at:$e, headers:[["chatgpt-account-id",$a]]}'
    else
      jq -n --arg t "$access" --argjson e "$expires_at" \
        '{access_token:$t, expires_at:$e}'
    fi
    ;;

  clear)
    rm -f "$token_path"
    echo '{"ok":true}'
    ;;

  *)
    echo "{\"ok\":false,\"error\":\"unknown action: $action\"}"
    ;;
esac
