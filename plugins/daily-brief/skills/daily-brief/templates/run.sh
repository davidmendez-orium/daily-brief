#!/usr/bin/env bash
# Headless entry point for the daily brief — for a terminal or a cron/launchd job.
# Inside an agent session, don't use this: the session can run collect.sh and
# follow brief-prompt.md itself, without paying for a second model.
#
# 0) optional MCP preflight, 1) deterministic local collection, 2) a headless
# agent run that gathers the cloud halves, composes, and delivers.
#
# The preflight exists because a launchd-fired run usually starts on a wake with
# no network, and because an expired bridge token fails every attempt the same
# way — both burned the full retry budget before this gate existed. It is skipped
# entirely when BRIEF_MCP_SOURCE_DIR is unset, since there is then nothing to
# preflight.
#
# Resilience: one attempt per entry in BRIEF_MODELS, falling across models when
# one is capacity-blocked. Exits non-zero if every attempt fails, so a missing
# brief is visible instead of silent. Retries are safe because each delivery card
# checks for an already-delivered brief first.
set -eu

BASE="${BRIEF_BASE:-$HOME/daily-brief}"
CONFIG="$BASE/config.env"
LOG="$BASE/logs/$(date +%F).log"
COST_CSV="$BASE/logs/cost.csv"
RUNS_DB="${BRIEF_RUNS_DB:-$BASE/logs/runs.db}"

# Stamped before anything can fail, so even an aborted run records how long it
# waited. A gate can hold for hours, and that time is the interesting part.
RUN_START_EPOCH="$(date +%s)"
RUN_START_ISO="$(date '+%F %T')"
TOTAL_TOOL_CALLS=0

mkdir -p "$BASE/logs"

[ -f "$CONFIG" ] || { echo "missing $CONFIG — copy config.env.example and fill it in" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONFIG"

MCP_SRC="${BRIEF_MCP_SOURCE_DIR:-}"
SERVERS="${BRIEF_SERVERS:-}"
MODEL_LADDER="${BRIEF_MODELS:-sonnet:0 sonnet:45 opus:60 haiku:60}"
AGENT_CLI="${BRIEF_AGENT_CLI:-claude}"

GATE_POLL="${BRIEF_GATE_POLL:-60}"
GATE_MAX="${BRIEF_GATE_MAX:-28800}"   # 8h, then give up rather than block tomorrow's run
REGATE_MAX="${BRIEF_REGATE_MAX:-1800}" # 30m for the re-check before each attempt
TOKEN_POLL="${BRIEF_TOKEN_POLL:-900}" # 15m between token re-checks
START_DAY="$(date +%F)"

ALERT_STATE="$BASE/logs/.token-alert-fingerprint"

# launchd gives us a bare env — rebuild PATH. node is often under nvm; pick newest.
NODE_BIN="$(/bin/ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -1 || true)"
export PATH="${NODE_BIN:+$NODE_BIN:}$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Always log to the file; also mirror to the terminal when there IS one. A launchd
# run has no tty and logs silently as before; a hand-run shows its work instead of
# looking like it did nothing. BRIEF_QUIET=1 forces file-only.
if [ -t 1 ] && [ -z "${BRIEF_QUIET:-}" ]; then
  exec > >(tee -a "$LOG") 2>&1
else
  exec >>"$LOG" 2>&1
fi

echo "===== $(date '+%F %T %Z') daily-brief START ====="
echo "  log: $LOG"

# One row per run, to the CSV and to SQLite. Duration and tool calls come from
# globals rather than arguments because every call site already passes the same
# six and both numbers are run-wide, not per-attempt.
# Called on every exit path, including the aborted ones — a run that waited four
# hours on a dead network and delivered nothing is exactly the row worth having.
record_run() {   # <attempts> <model> <tokens> <cost_usd> <brief_chars> <outcome>
  if [ ! -f "$COST_CSV" ]; then
    echo "date,attempts,model,tokens,cost_usd,brief_chars,outcome" > "$COST_CSV"
  fi
  echo "$(date +%F),$1,$2,$3,$4,$5,$6" >> "$COST_CSV"

  command -v sqlite3 >/dev/null 2>&1 || return 0
  # Never let bookkeeping fail a run that otherwise worked.
  sqlite3 "$RUNS_DB" <<SQL 2>&1 | sed 's/^/  sqlite: /' || true
CREATE TABLE IF NOT EXISTS runs (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  date         TEXT    NOT NULL,   -- YYYY-MM-DD the run started
  started_at   TEXT    NOT NULL,   -- local 'YYYY-MM-DD HH:MM:SS'
  duration_s   INTEGER NOT NULL,   -- wall clock, gate waiting included
  attempts     INTEGER NOT NULL,
  model        TEXT    NOT NULL,   -- model that produced the delivered brief
  tool_calls   INTEGER NOT NULL,   -- summed across attempts, from the transcripts
  tokens       INTEGER NOT NULL,   -- input + output + cache read + cache write
  cost_usd     REAL    NOT NULL,
  brief_chars  INTEGER NOT NULL,
  outcome      TEXT    NOT NULL
);
INSERT INTO runs (date, started_at, duration_s, attempts, model, tool_calls, tokens, cost_usd, brief_chars, outcome)
VALUES ('$(date +%F)', '$RUN_START_ISO', $(( $(date +%s) - RUN_START_EPOCH )), $1, '$2', $TOTAL_TOOL_CALLS, $3, $4, $5, '$6');
SQL
}

# The CLI reports turns, not tool calls, so count them in the transcript it wrote.
# Matching on the parsed block type rather than grepping the raw line keeps a tool
# name quoted inside message text from inflating the count.
count_tool_calls() {   # <session-id>
  local sid="$1" f
  [ -n "$sid" ] && [ "$sid" != null ] || { echo 0; return; }
  f="$(find "$HOME/.claude/projects" -maxdepth 2 -name "$sid.jsonl" 2>/dev/null | head -1)"
  [ -n "$f" ] || { echo 0; return; }
  jq -r '[.message.content[]? | select(.type == "tool_use")] | length' "$f" 2>/dev/null |
    awk '{s += $1} END {print s + 0}'
}

# Every alert goes through notify.sh, which fans out to every configured alert
# channel — Google Chat, Slack, email.
# Webhooks specifically, not the MCP servers: the failure being announced is
# usually the shared credential those servers authenticate with, so they are down
# in exactly the case that matters.
notify() {
  echo "  ALERT: $1"
  BRIEF_BASE="$BASE" bash "$BASE/notify.sh" "$1" "Daily brief" 2>&1 | sed 's/^/  /' || true
}

die_out() {   # <reason-for-log> <notification> <outcome>
  echo "!!!!! $(date '+%F %T %Z') $1"
  notify "$2"
  record_run 0 none 0 0 0 "$3"
  echo "===== $(date '+%F %T %Z') daily-brief DONE (failed) ====="
  exit 1
}

MCP_ARGS=()

if [ -z "$MCP_SRC" ]; then
  echo "--- no BRIEF_MCP_SOURCE_DIR — skipping MCP preflight, using the agent's own config ---"
else

# ---- derive mcp.json from the source config ----------------------------------
# Re-derive rather than keep a second copy of the token — a hand-maintained copy
# silently goes stale after a refresh. Pure local jq, so it runs before the
# network gate; the bridge URL to poll comes out of it.
sync_mcp_json() {
  local keep
  keep="$(printf '%s' "$SERVERS" | jq -R -c 'split(" ") | map(select(length>0))')"
  if [ ! -f "$MCP_SRC/.mcp.json" ] || ! jq -e . "$MCP_SRC/.mcp.json" >/dev/null 2>&1; then
    echo "  WARNING: $MCP_SRC/.mcp.json missing or unparseable — keeping existing mcp.json"
    return
  fi
  if [ "$keep" = "[]" ]; then
    jq '{mcpServers: .mcpServers}' "$MCP_SRC/.mcp.json" > "$BASE/mcp.json.tmp"
    mv "$BASE/mcp.json.tmp" "$BASE/mcp.json"
    return
  fi
  jq --argjson keep "$keep" \
     '{mcpServers: (.mcpServers | with_entries(select(.key as $k | $keep | index($k))))}' \
     "$MCP_SRC/.mcp.json" > "$BASE/mcp.json.tmp"
  local found want
  found="$(jq -r '.mcpServers | length' "$BASE/mcp.json.tmp")"
  want="$(printf '%s' "$keep" | jq -r 'length')"
  if [ "$found" -eq "$want" ]; then
    mv "$BASE/mcp.json.tmp" "$BASE/mcp.json"
  else
    rm -f "$BASE/mcp.json.tmp"
    echo "  WARNING: source had $found/$want brief servers — keeping existing mcp.json"
  fi
}

echo "--- mcp.json sync ---"
sync_mcp_json
[ -f "$BASE/mcp.json" ] || die_out "no mcp.json and none could be derived from $MCP_SRC" \
                                   "Daily brief has no MCP config." NO_MCP_CONFIG
# --strict-mcp-config so the brief's own servers are the only ones in play. Without
# it any interactively-authenticated connector in the user config is merged in too,
# and a run whose own gmail/calendar servers came up empty silently composes from
# those instead — a half-sourced brief that reports itself as complete.
MCP_ARGS=(--mcp-config "$BASE/mcp.json" --strict-mcp-config)

read_mcp() {   # <env-var-name> — first server that has it wins
  jq -r "[.mcpServers[].env.$1 // empty] | map(select(length>0)) | first // \"\"" "$BASE/mcp.json"
}

BRIDGE_BASE="$(read_mcp TELEOS_MCP_BRIDGE_BASE)"
TOKEN="$(read_mcp MCP_BRIDGE_TOKEN)"
REFRESH_URL="${BRIEF_REFRESH_URL:-}"

if [ -z "$BRIDGE_BASE" ] || [ -z "$TOKEN" ]; then
  # A perfectly normal setup: plain local MCP servers with no remote bridge.
  echo "--- no bridge token in mcp.json — skipping network and token gates ---"
else

BRIDGE_HOST="$(printf '%s' "$BRIDGE_BASE" | sed -E 's#^(https?://[^/]+).*#\1#')"

bridge_up() {
  # curl itself writes 000 on a failed connection, so do not add a fallback here
  # — a second 000 would concatenate and read as a real status code.
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BRIDGE_HOST" 2>/dev/null || true)"
  [ -n "$CODE" ] && [ "$CODE" != "000" ]
}

# Announce an expiry exactly once. The chat MCP authenticates with the very token
# that is broken, so this cannot go through the bridge — it needs a webhook, which
# carries its own credential. With no alert channel configured, a failed run is
# only discoverable in the log.
# Announce once per distinct token, not once per poll — the latch is what keeps a
# 15-minute retry loop from becoming a 15-minute spam loop.
alert_token_expired() {   # <error_code>
  FP="$(printf '%s' "$TOKEN" | shasum -a 256 2>/dev/null | cut -c1-12 || printf 'nohash')"
  [ -f "$ALERT_STATE" ] && [ "$(cat "$ALERT_STATE")" = "$FP" ] && return
  if [ "$TOKEN_POLL" -ge 60 ]; then EVERY="$((TOKEN_POLL / 60)) min"; else EVERY="${TOKEN_POLL}s"; fi
  notify "⚠️ *Daily brief blocked* — the MCP bridge token is \`$1\`. Renew it${REFRESH_URL:+ at $REFRESH_URL}; I re-check every ${EVERY} and deliver as soon as it is valid."
  printf '%s\n' "$FP" > "$ALERT_STATE"
}

# tools/list against every configured service, which is exactly the call the stdio
# client makes when the agent connects — and it makes that call once, live, with no
# retry and no cache. One failed fetch leaves that server contributing zero tools
# for the whole attempt, and the agent then reports the source as "not connected"
# instead of as a network failure. initialize alone does not catch this: the bridge
# answers it without exercising the service.
bridge_ready() {
  GATE_FAIL_SVC=""
  GATE_FAIL_BODY=""
  for SVC in $(jq -r '.mcpServers | keys[]' "$BASE/mcp.json"); do
    PROBE="$(curl -s -X POST "$BRIDGE_BASE/$SVC" --max-time 20 \
      -H 'Content-Type: application/json' -H 'Accept: application/json' \
      -H "X-Mcp-Bridge-Token: $TOKEN" \
      -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
      2>/dev/null || true)"
    printf '%s' "$PROBE" | jq -e '(.result.tools | length) > 0' >/dev/null 2>&1 && continue
    GATE_FAIL_SVC="$SVC"
    GATE_FAIL_BODY="$PROBE"
    return 1
  done
  return 0
}

# 0. readiness gate: network, then every MCP service, polled.
# launchd fires a missed calendar interval on the next DarkWake, where the machine
# has no usable network and re-sleeps seconds later. Every attempt then fails with
# "MCP servers unavailable" at full token cost. Polling here costs nothing and the
# wall clock keeps advancing across sleep, so the run resumes on wake.
# An expired token fails every attempt identically, so waiting beats retrying: the
# source config is re-read each pass so a renewal done in a normal session is
# picked up without a nudge.
# Called again before every attempt, because a run routinely straddles a sleep and
# a gate that passed at 07:45 says nothing about the network at 09:40.
bridge_gate() {   # <max-wait-seconds> <hard|soft> — soft returns non-zero instead of aborting
  GATE_MAX_WAIT="$1"
  GATE_MODE="$2"
  GATE_START="$(date +%s)"
  POLLS=0
  echo "--- readiness gate ($BRIDGE_HOST, up to ${GATE_MAX_WAIT}s) ---"
  while :; do
    sync_mcp_json
    TOKEN="$(read_mcp MCP_BRIDGE_TOKEN)"
    BRIDGE_BASE="$(read_mcp TELEOS_MCP_BRIDGE_BASE)"
    [ -n "$TOKEN" ] && [ -n "$BRIDGE_BASE" ] || \
      die_out "bridge token vanished from $BASE/mcp.json" "Daily brief lost its MCP bridge token." NO_TOKEN

    if ! bridge_up; then
      GATE_CAUSE=NO_NETWORK
      GATE_WAIT="$GATE_POLL"
      POLLS=$((POLLS + 1))
      [ $((POLLS % 5)) -eq 1 ] && echo "  bridge unreachable — still waiting"
    elif bridge_ready; then
      rm -f "$ALERT_STATE"    # so the NEXT expiry announces itself again
      echo "  network + all $(jq -r '.mcpServers | length' "$BASE/mcp.json") MCP services ready after $(( $(date +%s) - GATE_START ))s"
      return 0
    else
      GATE_CAUSE=MCP_NOT_READY
      GATE_WAIT="$GATE_POLL"
      TOKEN_ERR="$(printf '%s' "$GATE_FAIL_BODY" | jq -r '.error.data.error_code // ""' 2>/dev/null || true)"
      if [ -n "$TOKEN_ERR" ]; then
        # Renewal is a browser SSO flow — it cannot be automated from a headless run.
        GATE_CAUSE=TOKEN_INVALID
        GATE_WAIT="$TOKEN_POLL"
        if [ "$TOKEN_ERR" = "bridge_token_superseded" ]; then
          echo "  $GATE_FAIL_SVC: token $TOKEN_ERR — a newer export replaced it; reinstall from your latest plugin build"
        else
          echo "  $GATE_FAIL_SVC: token $TOKEN_ERR — renew it${REFRESH_URL:+ at $REFRESH_URL}"
        fi
        alert_token_expired "$TOKEN_ERR"
      else
        echo "  $GATE_FAIL_SVC: no usable tools/list — $(printf '%s' "$GATE_FAIL_BODY" | head -c 200)"
      fi
    fi

    ELAPSED=$(( $(date +%s) - GATE_START ))
    if [ "$(date +%F)" != "$START_DAY" ]; then
      die_out "date rolled over waiting on the readiness gate — abandoning stale $START_DAY run" \
              "The $START_DAY brief was abandoned — the bridge never became usable before midnight." STALE_ABANDONED
    fi
    if [ "$ELAPSED" -ge "$GATE_MAX_WAIT" ]; then
      if [ "$GATE_MODE" = soft ]; then
        echo "  gate gave up after ${ELAPSED}s ($GATE_CAUSE)"
        return 1
      fi
      case "$GATE_CAUSE" in
        NO_NETWORK)
          die_out "no network after ${ELAPSED}s — NO BRIEF DELIVERED" \
                  "No network for ${GATE_MAX_WAIT}s after wake — today's brief was skipped." SKIPPED_NO_NETWORK ;;
        TOKEN_INVALID)
          die_out "bridge token still invalid after ${ELAPSED}s — NO BRIEF DELIVERED" \
                  "Bridge token never became valid today — brief skipped." TOKEN_WAIT_EXHAUSTED ;;
        *)
          die_out "$GATE_FAIL_SVC still not serving tools/list after ${ELAPSED}s — NO BRIEF DELIVERED" \
                  "The MCP bridge never served its tools today — brief skipped." MCP_WAIT_EXHAUSTED ;;
      esac
    fi
    echo "  retrying in ${GATE_WAIT}s (${ELAPSED}s elapsed)"
    sleep "$GATE_WAIT"
  done
}

GATES_ON=1
bridge_gate "$GATE_MAX" hard

fi   # bridge token present
fi   # MCP_SRC set

# Hold off idle sleep only now that real work is about to start, so an attempt is
# not frozen mid-flight. Never forces a wake — it only keeps an awake machine
# awake, and the assertion dies with this shell. Waiting above deliberately runs
# without it: polling should not cost battery, and a sleeping machine simply
# resumes the poll on wake.
command -v caffeinate >/dev/null 2>&1 && caffeinate -i -w $$ &

# 1. deterministic local collection (git + sessions + worktrees)
echo "--- collect ---"
BRIEF_BASE="$BASE" bash "$BASE/collect.sh"

# BRIEF_DRY_RUN stops here: preflight and collector verified, nothing spent and
# nothing delivered. This is the way to check a setup or a renewed token.
if [ -n "${BRIEF_DRY_RUN:-}" ]; then
  echo "--- BRIEF_DRY_RUN set — preflight and collect passed, skipping compose+deliver ---"
  echo "===== $(date '+%F %T %Z') daily-brief DONE (dry run) ====="
  exit 0
fi

# 2. cloud gather + compose + deliver
PROMPT="$(cat "$BASE/brief-prompt.md")"
read -r -a ATTEMPTS <<<"$MODEL_LADDER"

TOTAL_COST=0
TOTAL_TOKENS=0
ATTEMPT_N=0
USED_MODEL=""
RESULT=""
OK=0

add() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.6f", a+b}'; }

for spec in "${ATTEMPTS[@]}"; do
  MODEL="${spec%%:*}"
  BACKOFF="${spec##*:}"
  [ "$BACKOFF" = "$MODEL" ] && BACKOFF=0
  ATTEMPT_N=$((ATTEMPT_N + 1))

  if [ "$BACKOFF" -gt 0 ]; then
    echo "--- backoff ${BACKOFF}s before attempt ${ATTEMPT_N} ---"
    sleep "$BACKOFF"
  fi

  # Re-check readiness: an attempt that starts on a cold network gets MCP servers
  # with no tools, and the agent reports every cloud source as "not connected"
  # while still burning the attempt.
  if [ "${GATES_ON:-0}" = 1 ] && ! bridge_gate "$REGATE_MAX" soft; then
    echo "attempt ${ATTEMPT_N} (${MODEL}): SKIPPED — bridge not ready, no attempt left worth making"
    ATTEMPT_N=$((ATTEMPT_N - 1))
    break
  fi

  echo "--- attempt ${ATTEMPT_N}: compose + deliver (model=${MODEL}) ---"
  USAGE="$BASE/logs/last-run-usage.json"

  BRIEF_BASE="$BASE" "$AGENT_CLI" -p "$PROMPT" \
    ${MCP_ARGS[@]+"${MCP_ARGS[@]}"} \
    --dangerously-skip-permissions \
    --model "$MODEL" \
    --output-format json > "$USAGE" || true

  if [ ! -s "$USAGE" ]; then
    echo "attempt ${ATTEMPT_N} (${MODEL}): FAILED — no output from CLI"
    continue
  fi

  # accumulate spend for this attempt even when it failed — a died-mid-run attempt
  # still costs money, and that is the number worth watching.
  COST="$(jq -r '.total_cost_usd // 0' "$USAGE")"
  TOK="$(jq -r '(.usage // {}) as $u | (($u.input_tokens//0)+($u.output_tokens//0)+($u.cache_read_input_tokens//0)+($u.cache_creation_input_tokens//0))' "$USAGE")"
  TOTAL_COST="$(add "$TOTAL_COST" "$COST")"
  TOTAL_TOKENS=$((TOTAL_TOKENS + TOK))
  CALLS="$(count_tool_calls "$(jq -r '.session_id // ""' "$USAGE")")"
  TOTAL_TOOL_CALLS=$((TOTAL_TOOL_CALLS + CALLS))
  RESULT="$(jq -r '.result // "(no text result)"' "$USAGE")"

  jq -r '
    (.usage // {}) as $u |
    (($u.input_tokens//0)+($u.output_tokens//0)+($u.cache_read_input_tokens//0)+($u.cache_creation_input_tokens//0)) as $tot |
    "  RESULT: \(.result // "(no text result)")\n" +
    "  TOKENS: total=\($tot) (in=\($u.input_tokens//0) out=\($u.output_tokens//0) cache_read=\($u.cache_read_input_tokens//0) cache_write=\($u.cache_creation_input_tokens//0)) | cost=$\(.total_cost_usd // 0) | turns=\(.num_turns // 0) | dur=\((.duration_ms // 0)/1000)s"
  ' "$USAGE" || echo "  (could not parse $USAGE)"

  # The DELIVERED summary carries per-channel counts, and (0 ok, 0 already, N
  # failed) means the agent announced that it delivered NOTHING. Reading the
  # marker alone once scored that as success: the run exited 0, no alert fired,
  # and no brief was posted. Counts win over the marker.
  DELIVERED_COUNTS="$(printf '%s' "$RESULT" | grep -oiE '\([0-9]+ ok, [0-9]+ already' | head -1)"
  if [ -n "$DELIVERED_COUNTS" ]; then
    # Counts are authoritative wherever they appear — they are the agent's own
    # tally, and they outrank any marker word elsewhere in the text.
    [ "$(printf '%s' "$DELIVERED_COUNTS" | grep -oE '[0-9]+' | awk '{s += $1} END {print s + 0}')" -gt 0 ] && OK=1
  # No counts to go on: fall back to the marker. It can be anywhere in the result
  # and any case — the model does not always emit a bare token, and often wraps
  # the date in backticks. Requiring a date after it keeps "failed to deliver"
  # from matching.
  elif printf '%s' "$RESULT" | grep -qiE '(delivered|(already_)?posted)[[:space:]]+`?[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
    OK=1
  fi
  if [ "$OK" -eq 1 ]; then
    USED_MODEL="$MODEL"
    break
  fi
  echo "attempt ${ATTEMPT_N} (${MODEL}): FAILED — retrying if attempts remain"
done

# 3. cost accounting across all attempts
CHARS="$(wc -c < "$BASE/data/brief-$(date +%F).md" 2>/dev/null | tr -d ' ' || echo 0)"
echo "COST: attempts=${ATTEMPT_N} model=${USED_MODEL:-none} tokens=${TOTAL_TOKENS} tool_calls=${TOTAL_TOOL_CALLS} spend=\$${TOTAL_COST} chars=${CHARS} dur=$(( $(date +%s) - RUN_START_EPOCH ))s"

record_run "${ATTEMPT_N}" "${USED_MODEL:-none}" "${TOTAL_TOKENS}" "${TOTAL_COST}" "${CHARS}" \
           "$([ "$OK" -eq 1 ] && echo ok || echo FAILED)"

if [ "$OK" -ne 1 ]; then
  echo "!!!!! $(date '+%F %T %Z') daily-brief FAILED after ${ATTEMPT_N} attempts — NO BRIEF DELIVERED"
  echo "!!!!! last result: ${RESULT}"
  notify "All ${ATTEMPT_N} attempts failed — see $LOG"
  echo "===== $(date '+%F %T %Z') daily-brief DONE (failed) ====="
  exit 1
fi

echo "===== $(date '+%F %T %Z') daily-brief DONE ====="
