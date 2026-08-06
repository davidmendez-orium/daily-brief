#!/usr/bin/env bash
# Dependency check for the daily brief.
#
# Works out which MCP servers this config actually needs — from the delivery
# channels and the enabled sources — and reports whether each one is present and
# authenticated. Read-only: it installs nothing and authenticates nothing.
#
#   bash check-deps.sh            # human-readable report + next steps
#   bash check-deps.sh --porcelain # one "KEY<TAB>STATUS<TAB>SERVER<TAB>WHY" line each
#
# Exit codes: 0 all satisfied · 3 something unmet · 4 cannot tell (no agent CLI)
#
# WHAT THIS CANNOT SEE. It asks the local agent CLI what is configured. That is
# authoritative for Claude Code, and blind to connectors enabled in a client UI
# (Cowork) or to a session's live tool list. An agent session can see its own
# tools directly and should trust that over this script.
set -eu

BASE="${BRIEF_BASE:-$HOME/daily-brief}"
CONFIG="$BASE/config.env"
PORCELAIN=0
[ "${1:-}" = "--porcelain" ] && PORCELAIN=1

[ -f "$CONFIG" ] || { echo "missing $CONFIG" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONFIG"

AGENT_CLI="${BRIEF_AGENT_CLI:-claude}"

# ---- what does this config need? ---------------------------------------------
# key | name-match regex (case-insensitive) | why it is needed
REQ_KEYS=(); REQ_RX=(); REQ_WHY=()
need() { REQ_KEYS+=("$1"); REQ_RX+=("$2"); REQ_WHY+=("$3"); }

for ch in ${BRIEF_DELIVERY:-}; do
  case "$ch" in
    gchat) need chat  'chat'  'deliver to Google Chat' ;;
    slack) need slack 'slack' 'deliver to Slack' ;;
    email) need gmail 'gmail|mail' 'deliver by email' ;;
  esac
done
[ "${BRIEF_SOURCE_GCHAT:-true}"    = true ] && need chat      'chat'          'scan Google Chat mentions'
[ "${BRIEF_SOURCE_GMAIL:-true}"    = true ] && need gmail     'gmail|mail'    'scan mail needing a reply'
[ "${BRIEF_SOURCE_GITHUB:-true}"   = true ] && need github    'github'        'find your PRs and reviews'
[ "${BRIEF_SOURCE_JIRA:-true}"     = true ] && need atlassian 'atlassian|jira' 'find your tickets'
[ "${BRIEF_SOURCE_CALENDAR:-true}" = true ] && need calendar  'calendar'      "list today's events"

# De-duplicate, merging the reasons — chat is commonly both a source and a target.
DEDUP_KEYS=(); DEDUP_RX=(); DEDUP_WHY=()
for i in "${!REQ_KEYS[@]}"; do
  k="${REQ_KEYS[$i]}"; hit=-1
  for j in "${!DEDUP_KEYS[@]}"; do [ "${DEDUP_KEYS[$j]}" = "$k" ] && hit=$j; done
  if [ "$hit" -ge 0 ]; then
    DEDUP_WHY[$hit]="${DEDUP_WHY[$hit]}; ${REQ_WHY[$i]}"
  else
    DEDUP_KEYS+=("$k"); DEDUP_RX+=("${REQ_RX[$i]}"); DEDUP_WHY+=("${REQ_WHY[$i]}")
  fi
done

# ---- what is actually configured? --------------------------------------------
INVENTORY=""
HAVE_CLI=0
if command -v "$AGENT_CLI" >/dev/null 2>&1; then
  # Lines look like:  <name>: <command-or-url> - <status>
  # Names contain spaces and dots, so split on the FIRST ": " and take the status
  # after the LAST " - ".
  INVENTORY="$("$AGENT_CLI" mcp list 2>/dev/null \
    | sed -n 's/^\([^:]*\): \(.*\) - \([^-]*\)$/\1\t\3/p' || true)"
  [ -n "$INVENTORY" ] && HAVE_CLI=1
fi

if [ "$HAVE_CLI" -eq 0 ]; then
  if [ "$PORCELAIN" -eq 1 ]; then
    for i in "${!DEDUP_KEYS[@]}"; do
      printf '%s\tUNKNOWN\t-\t%s\n' "${DEDUP_KEYS[$i]}" "${DEDUP_WHY[$i]}"
    done
  else
    echo "Cannot check MCP servers from here: no '$AGENT_CLI' CLI on PATH."
    echo "That is normal in a hosted agent (Cowork) — connectors live in the client UI."
    echo "The agent running this skill can see its own tools; ask it to verify these:"
    for i in "${!DEDUP_KEYS[@]}"; do
      printf '  - %-10s %s\n' "${DEDUP_KEYS[$i]}" "${DEDUP_WHY[$i]}"
    done
  fi
  exit 4
fi

# Best status wins: a requirement met by any connected server is satisfied, even
# if some other server matching the same pattern is unauthenticated.
lookup() {   # <regex> -> "STATUS<TAB>SERVER"
  local rx="$1" best="MISSING" best_srv="-" name status
  while IFS="$(printf '\t')" read -r name status; do
    [ -n "$name" ] || continue
    printf '%s' "$name" | grep -qiE "$rx" || continue
    case "$status" in
      *Connected*)          echo "OK	$name"; return ;;
      *authentication*|*Auth*|*auth*)
        if [ "$best" != "NEEDS_AUTH" ]; then best="NEEDS_AUTH"; best_srv="$name"; fi ;;
      *)
        if [ "$best" = "MISSING" ]; then best="FOUND_UNHEALTHY"; best_srv="$name"; fi ;;
    esac
  done <<EOF
$INVENTORY
EOF
  echo "$best	$best_srv"
}

UNMET=0
declare -a ROWS=()
for i in "${!DEDUP_KEYS[@]}"; do
  res="$(lookup "${DEDUP_RX[$i]}")"
  st="${res%%	*}"; srv="${res#*	}"
  [ "$st" = "OK" ] || UNMET=1
  ROWS+=("${DEDUP_KEYS[$i]}	$st	$srv	${DEDUP_WHY[$i]}")
done

if [ "$PORCELAIN" -eq 1 ]; then
  printf '%s\n' "${ROWS[@]}"
  [ "$UNMET" -eq 0 ] && exit 0 || exit 3
fi

# ---- human report ------------------------------------------------------------
echo "MCP dependencies for delivery=[${BRIEF_DELIVERY:-}]:"
for row in "${ROWS[@]}"; do
  key="$(printf '%s' "$row" | cut -f1)"
  st="$(printf '%s' "$row"  | cut -f2)"
  srv="$(printf '%s' "$row" | cut -f3)"
  why="$(printf '%s' "$row" | cut -f4)"
  case "$st" in
    OK)              mark="  ok  " ;;
    NEEDS_AUTH)      mark=" auth " ;;
    FOUND_UNHEALTHY) mark=" sick " ;;
    *)               mark="MISSING" ;;
  esac
  printf '  [%s] %-10s %-34s %s\n' "$mark" "$key" "$(printf '%.34s' "$srv")" "$why"
done

[ "$UNMET" -eq 0 ] && { echo; echo "All required MCP servers are connected."; exit 0; }

# ---- remedies ----------------------------------------------------------------
echo
echo "NEXT STEPS — the brief will fail on these until they are resolved:"
echo
for row in "${ROWS[@]}"; do
  key="$(printf '%s' "$row" | cut -f1)"
  st="$(printf '%s' "$row"  | cut -f2)"
  srv="$(printf '%s' "$row" | cut -f3)"
  case "$st" in
    OK) continue ;;
    NEEDS_AUTH|FOUND_UNHEALTHY)
      echo "  $key — '$srv' is configured but not usable. Authenticate it:"
      echo "      claude mcp login \"$srv\""
      echo "      (opens a browser; it cannot be done unattended)"
      ;;
    MISSING)
      echo "  $key — no configured server matches. Either:"
      # If the same server is declared in the config source, offer to copy it over.
      if [ -n "${BRIEF_MCP_SOURCE_DIR:-}" ] && [ -f "$BRIEF_MCP_SOURCE_DIR/.mcp.json" ] \
         && jq -e --arg k "$key" '.mcpServers | has($k)' "$BRIEF_MCP_SOURCE_DIR/.mcp.json" >/dev/null 2>&1; then
        echo "      • copy the definition already in $BRIEF_MCP_SOURCE_DIR/.mcp.json:"
        echo "          claude mcp add-json $key \"\$(jq -c '.mcpServers.$key' $BRIEF_MCP_SOURCE_DIR/.mcp.json)\""
      fi
      echo "      • add a connector for it in your client, then re-run this check"
      echo "      • or switch it off in config.env if you do not want it"
      ;;
  esac
  echo
done
echo "Re-check with:  bash \"\$SKILL/check-deps.sh\""
exit 3
