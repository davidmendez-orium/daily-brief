#!/usr/bin/env bash
# Out-of-band alerting for the daily brief.
#
#   bash notify.sh "<message>" ["<subject>"]
#
# Fans a short message out to every alert channel that is configured — Google
# Chat, Slack, email — and prints one line per channel. Exits 0 if any channel
# took it, 1 if none did.
#
# There is deliberately NO desktop notification. It carried no useful detail, it
# fired on a machine nobody is looking at, and it doubled up on alerts that had
# already arrived somewhere real. Chat, Slack, email — that is the whole list.
#
# THE CHANNELS ARE NOT EQUALLY ROBUST, AND THAT MATTERS.
#
#   gchat / slack — incoming webhooks. The key lives in the URL, so they keep
#                   working when everything else is broken. These are the only
#                   channels that can report a DEAD BRIDGE TOKEN, because that is
#                   the credential every MCP server shares.
#   email         — the Gmail MCP over the HTTP bridge. Reuses the credential you
#                   already have, so there is nothing new to configure — but it
#                   authenticates with the very token whose death is the most
#                   common thing worth alerting about, and fails in that case.
#
# So email alone is a partial safety net: it covers a failed model run, a bad
# compose, an unreachable delivery channel — not an expired token and not a
# network outage. Pair it with a webhook if you want full coverage.
set -eu

BASE="${BRIEF_BASE:-$HOME/daily-brief}"
CONFIG="$BASE/config.env"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"

MSG="${1:?usage: notify.sh <message> [subject]}"
SUBJECT="${2:-Daily brief}"

# Resolve a secret: explicit value wins, then an explicit file, then conventional
# paths. Files are preferred — a webhook URL or SMTP password is a credential, and
# config.env is a config file people read over each other's shoulders.
resolve() {   # <inline-value> <file-path> <default-file>...
  local v="$1"; shift
  local f="$1"; shift
  if [ -n "$v" ]; then printf '%s' "$v"; return; fi
  if [ -n "$f" ] && [ -f "$f" ]; then tr -d '[:space:]' < "$f"; return; fi
  local d
  for d in "$@"; do
    [ -f "$d" ] && { tr -d '[:space:]' < "$d"; return; }
  done
  printf ''
}

GCHAT_HOOK="$(resolve "${BRIEF_GCHAT_WEBHOOK_URL:-}" "${BRIEF_GCHAT_WEBHOOK_FILE:-}" \
              "$BASE/gchat-webhook.url" "$BASE/chat-webhook.url")"
SLACK_HOOK="$(resolve "${BRIEF_SLACK_WEBHOOK_URL:-}" "${BRIEF_SLACK_WEBHOOK_FILE:-}" \
              "$BASE/slack-webhook.url")"

OK=0
CONFIGURED=0

# Google Chat and Slack incoming webhooks both accept {"text": "..."} and render
# *bold* / `code` the same way, so one payload serves both.
post_hook() {   # <label> <url> <expected-host-fragment>
  local label="$1" url="$2" want="$3"
  [ -n "$url" ] || return 0
  CONFIGURED=$((CONFIGURED + 1))
  case "$url" in
    *"$want"*) ;;
    *) echo "  $label: WARNING url does not look like a $label webhook ($want expected)" ;;
  esac
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X POST "$url" \
    -H 'Content-Type: application/json; charset=UTF-8' \
    --data "$(jq -nc --arg t "$MSG" '{text: $t}')" 2>/dev/null || true)"
  if [ "$code" = "200" ] || [ "$code" = "204" ]; then
    echo "  $label: sent"
    OK=$((OK + 1))
  else
    echo "  $label: FAILED (http ${code:-000})"
  fi
}

# Email through the Gmail MCP, driven over the HTTP bridge with plain JSON-RPC —
# the same transport run.sh probes for token validity. No new credential: it reuses
# the bridge token already in mcp.json.
#
# The catch, stated plainly because it decides whether this channel is enough on
# its own: that token IS the thing most alerts are about. When it expires, this
# send fails with it. Webhooks are the only channels that survive that.
post_email() {
  local to="${BRIEF_ALERT_EMAIL_TO:-}"
  [ -n "$to" ] || return 0
  CONFIGURED=$((CONFIGURED + 1))

  local mcp="$BASE/mcp.json"
  if [ ! -f "$mcp" ]; then
    echo "  email: FAILED (no $mcp — run install.sh, or set BRIEF_MCP_SOURCE_DIR)"
    return 0
  fi
  local bridge tok
  bridge="$(jq -r '[.mcpServers[].env.TELEOS_MCP_BRIDGE_BASE // empty] | first // ""' "$mcp")"
  tok="$(jq -r '[.mcpServers[].env.MCP_BRIDGE_TOKEN // empty] | first // ""' "$mcp")"
  if [ -z "$bridge" ] || [ -z "$tok" ]; then
    echo "  email: FAILED (no Gmail MCP bridge or token in $mcp)"
    return 0
  fi

  local payload resp errmsg
  payload="$(jq -nc \
    --arg s "$SUBJECT" --arg b "$MSG" \
    --argjson to "$(printf '%s' "$to" | jq -R -c 'split(" ") | map(select(length>0))')" \
    '{jsonrpc:"2.0", id:1, method:"tools/call",
      params:{name:"gmail_send_email_as_agent",
              arguments:{to:$to, subject:$s, body:$b}}}')"

  resp="$(curl -s -X POST "$bridge/gmail" --max-time 30 \
    -H 'Content-Type: application/json' -H 'Accept: application/json' \
    -H "X-Mcp-Bridge-Token: $tok" \
    -d "$payload" 2>/dev/null || true)"

  # Two shapes of failure: a JSON-RPC error, or a result flagged isError.
  errmsg="$(printf '%s' "$resp" | jq -r '
      .error.message // (if (.result.isError // false) then ((.result.content[0].text) // "tool error") else empty end)
    ' 2>/dev/null || true)"
  if [ -z "$resp" ]; then
    echo "  email: FAILED (no response from the bridge)"
  elif [ -n "$errmsg" ]; then
    echo "  email: FAILED ($(printf '%s' "$errmsg" | head -c 120))"
  elif printf '%s' "$resp" | jq -e '.result' >/dev/null 2>&1; then
    echo "  email: sent to $to"
    OK=$((OK + 1))
  else
    echo "  email: FAILED (unrecognised response: $(printf '%s' "$resp" | head -c 120))"
  fi
}

post_hook gchat "$GCHAT_HOOK" "chat.googleapis.com"
post_hook slack "$SLACK_HOOK" "hooks.slack.com"
post_email

if [ "$CONFIGURED" -eq 0 ]; then
  echo "  NO ALERT CHANNEL CONFIGURED — a failed run can only be found in the log."
  echo "  Configure at least one of:"
  echo "    $BASE/gchat-webhook.url    (Chat space → Apps & integrations → Webhooks)"
  echo "    $BASE/slack-webhook.url    (api.slack.com/apps → Incoming Webhooks)"
  echo "    BRIEF_ALERT_EMAIL_TO + BRIEF_ALERT_SMTP_* in config.env"
fi

[ "$OK" -gt 0 ] && exit 0 || exit 1
