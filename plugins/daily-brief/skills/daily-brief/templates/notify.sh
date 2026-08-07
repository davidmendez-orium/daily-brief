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
# WHY THESE TRANSPORTS AND NOT THE MCP SERVERS. The thing this exists to announce
# is usually the credential the MCP servers share. When the bridge token dies, the
# Chat MCP, the Gmail MCP and the Slack connector all die with it, so announcing a
# dead token through them cannot work. Every channel here carries its OWN
# credential — a webhook key in the URL, or an SMTP login — so it keeps working
# precisely when everything else does not.
#
# That is also why this is a separate path from delivery. Delivery goes over MCP
# because it needs to read a channel back to detect duplicates; alerts go over
# self-credentialed transports because they must survive a broken MCP.
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
SMTP_PASS="$(resolve "${BRIEF_ALERT_SMTP_PASS:-}" "${BRIEF_ALERT_SMTP_PASS_FILE:-}" \
              "$BASE/smtp-password")"

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

# Email over SMTP, NOT the Gmail MCP. The MCP authenticates with the bridge token
# that is usually the thing being reported; an SMTP login is independent of it.
# Gmail needs an App Password here, not the account password.
post_email() {
  local to="${BRIEF_ALERT_EMAIL_TO:-}"
  local url="${BRIEF_ALERT_SMTP_URL:-}"
  local user="${BRIEF_ALERT_SMTP_USER:-}"
  local from="${BRIEF_ALERT_EMAIL_FROM:-$user}"
  [ -n "$to" ] && [ -n "$url" ] || return 0
  CONFIGURED=$((CONFIGURED + 1))
  if [ -z "$user" ] || [ -z "$SMTP_PASS" ]; then
    echo "  email: FAILED (BRIEF_ALERT_SMTP_USER or the SMTP password is missing)"
    return 0
  fi

  local body rc
  body="$(mktemp)"
  # A bare LF body is accepted by every SMTP server in practice; headers must come
  # first, then one blank line, then the text.
  {
    printf 'From: %s\n' "$from"
    printf 'To: %s\n' "$to"
    printf 'Subject: %s\n' "$SUBJECT"
    printf 'Date: %s\n' "$(date -R 2>/dev/null || date)"
    printf 'Content-Type: text/plain; charset=UTF-8\n'
    printf '\n%s\n' "$MSG"
  } > "$body"

  # TLS is required by default. BRIEF_ALERT_SMTP_INSECURE=1 drops that for a
  # trusted local relay or a test stub — it sends the SMTP login in the clear, so
  # never point it at a remote server.
  local tls_args
  if [ -n "${BRIEF_ALERT_SMTP_INSECURE:-}" ]; then tls_args="-k"; else tls_args="--ssl-reqd"; fi

  rc=0
  # shellcheck disable=SC2086
  curl -s --show-error --max-time 30 $tls_args --url "$url" \
    --user "$user:$SMTP_PASS" \
    --mail-from "$from" \
    $(for r in $to; do printf -- '--mail-rcpt %s ' "$r"; done) \
    --upload-file "$body" >/dev/null 2>&1 || rc=$?
  rm -f "$body"

  if [ "$rc" -eq 0 ]; then
    echo "  email: sent to $to"
    OK=$((OK + 1))
  else
    echo "  email: FAILED (curl exit $rc)"
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
