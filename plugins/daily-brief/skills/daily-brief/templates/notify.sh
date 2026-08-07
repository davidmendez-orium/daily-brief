#!/usr/bin/env bash
# Out-of-band alerting for the daily brief.
#
#   bash notify.sh "<message>" ["<title>"]
#
# Fans a short message out to every messaging service that has an INCOMING
# WEBHOOK configured. If none of them took it, falls back to a desktop
# notification. Prints one line per channel; exits 0 if anyone was told.
#
# The desktop notification is a FALLBACK, not an addition. Once a webhook is
# configured the alert belongs in the space where you will actually see it, and
# popping a system notification as well is just noise on the machine.
# BRIEF_NOTIFY_NO_DESKTOP=1 suppresses it entirely — use it when testing the
# webhook path so a test run cannot spam the desktop.
#
# WHY WEBHOOKS AND NOT THE MCP SERVERS. The thing this exists to announce is
# usually the credential the MCP servers share. When the bridge token dies, the
# Chat MCP, the Gmail MCP and the Slack connector all die with it — announcing a
# dead token through them cannot work. An incoming webhook carries its own key in
# its URL, so it keeps working precisely when everything else does not.
#
# That is also why this is a separate path from delivery. Delivery goes over MCP
# because it needs to read a channel back to avoid duplicates; alerts go over
# webhooks because they need to survive a broken MCP. Neither substitutes for the
# other.
#
# EMAIL IS NOT AN ALERT CHANNEL. Sending mail goes through the Gmail MCP, which
# authenticates with the same bridge token, so it fails in exactly the case that
# matters. There is no webhook equivalent. If email is your only delivery channel,
# configure a Chat or Slack webhook anyway — otherwise a dead token is silent.
set -eu

BASE="${BRIEF_BASE:-$HOME/daily-brief}"
CONFIG="$BASE/config.env"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"

MSG="${1:?usage: notify.sh <message> [title]}"
TITLE="${2:-Daily brief}"

# Resolve a channel's webhook: explicit URL var wins, then an explicit file, then
# the conventional filename. Keeping URLs in files rather than config.env is
# deliberate — a webhook URL is a credential, and anyone holding it can post.
resolve_hook() {   # <URL-var-value> <FILE-var-value> <default-file>...
  local url="$1"; shift
  local f="$1"; shift
  if [ -n "$url" ]; then printf '%s' "$url"; return; fi
  if [ -n "$f" ] && [ -f "$f" ]; then tr -d '[:space:]' < "$f"; return; fi
  local d
  for d in "$@"; do
    [ -f "$d" ] && { tr -d '[:space:]' < "$d"; return; }
  done
  printf ''
}

GCHAT_HOOK="$(resolve_hook "${BRIEF_GCHAT_WEBHOOK_URL:-}" "${BRIEF_GCHAT_WEBHOOK_FILE:-}" \
              "$BASE/gchat-webhook.url" "$BASE/chat-webhook.url")"
SLACK_HOOK="$(resolve_hook "${BRIEF_SLACK_WEBHOOK_URL:-}" "${BRIEF_SLACK_WEBHOOK_FILE:-}" \
              "$BASE/slack-webhook.url")"

OK=0
CONFIGURED=0

# Google Chat and Slack incoming webhooks both accept {"text": "..."} and both
# render *bold* / `code` the same way, so one payload serves both.
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

post_hook gchat "$GCHAT_HOOK" "chat.googleapis.com"
post_hook slack "$SLACK_HOOK" "hooks.slack.com"

# Fallback only: no webhook took it, so try the machine in front of you.
DESKTOP_OK=0
if [ "$OK" -eq 0 ] && [ -z "${BRIEF_NOTIFY_NO_DESKTOP:-}" ]; then
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$MSG\" with title \"$TITLE\"" >/dev/null 2>&1 \
      && { echo "  desktop: shown (fallback)"; DESKTOP_OK=1; } || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "$TITLE" "$MSG" >/dev/null 2>&1 \
      && { echo "  desktop: shown (fallback)"; DESKTOP_OK=1; } || true
  fi
fi

if [ "$CONFIGURED" -eq 0 ]; then
  echo "  no webhooks configured — alerts can only reach this desktop, which nobody"
  echo "  sees on a closed laptop. Set one up: $BASE/gchat-webhook.url or $BASE/slack-webhook.url"
fi

[ "$OK" -gt 0 ] || [ "$DESKTOP_OK" -eq 1 ] && exit 0 || exit 1
