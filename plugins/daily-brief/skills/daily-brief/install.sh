#!/usr/bin/env bash
# Installer for the daily brief. Idempotent — safe to re-run after editing
# config.env or updating the plugin.
#
# Scheduling is OPT-IN, and only possible on macOS with a local agent CLI. A plain
# install gives you a working brief you run when you want it.
#
#   bash install.sh               # install/refresh files + validate. No cron.
#   bash install.sh --schedule    # ...and load the weekday launchd job (macOS)
#   bash install.sh --unschedule  # drop the cron, keep everything else
#   bash install.sh --status      # what is installed, scheduled or not, last runs
#   bash install.sh --uninstall   # remove the cron and say where the files are
#
# Honours BRIEF_BASE (default ~/daily-brief).
set -eu

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SKILL_DIR/templates"
BASE="${BRIEF_BASE:-$HOME/daily-brief}"
LABEL="com.$(id -un).daily-brief"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
KNOWN_CHANNELS="gchat slack email"

MODE=install
case "${1:-}" in
  --schedule)        MODE=schedule ;;
  --unschedule)      MODE=unschedule ;;
  --uninstall)       MODE=uninstall ;;
  --status)          MODE=status ;;
  --no-schedule|"")  ;;   # --no-schedule is the default now; accepted for compat
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

# ---- status ------------------------------------------------------------------
if [ "$MODE" = status ]; then
  echo "base:      $BASE $([ -d "$BASE" ] && echo "(present)" || echo "(MISSING)")"
  echo "config:    $BASE/config.env $([ -f "$BASE/config.env" ] && echo "(present)" || echo "(MISSING)")"
  if [ -f "$BASE/config.env" ]; then
    # shellcheck disable=SC1090
    . "$BASE/config.env"
    echo "delivery:  ${BRIEF_DELIVERY:-(unset)}"
  fi
  if launchctl list "$LABEL" >/dev/null 2>&1; then
    echo "schedule:  ON — $LABEL fires Mon–Fri; plist at $PLIST"
  elif [ -f "$PLIST" ]; then
    echo "schedule:  plist exists but is NOT loaded — re-run with --schedule"
  else
    echo "schedule:  off (manual only) — add it with --schedule"
  fi
  if [ -f "$BASE/logs/cost.csv" ]; then
    echo "last runs:"; tail -5 "$BASE/logs/cost.csv" | sed 's/^/  /'
  else
    echo "last runs: none recorded"
  fi
  exit 0
fi

# ---- unschedule / uninstall --------------------------------------------------
# Both only ever remove the cron. The brief itself is just files you can run, so
# there is nothing else to "uninstall" — and deleting someone's archived briefs
# and cost history is not this script's call.
if [ "$MODE" = unschedule ] || [ "$MODE" = uninstall ]; then
  if [ -f "$PLIST" ]; then
    launchctl unload -w "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "schedule removed ($LABEL)"
  else
    echo "nothing scheduled — no plist at $PLIST"
  fi
  if [ "$MODE" = unschedule ]; then
    echo "the brief still works on demand: bash $BASE/run.sh"
  else
    echo "left $BASE in place (config, archived briefs, logs, cost history)."
    echo "run it by hand any time with: bash $BASE/run.sh"
    echo "delete $BASE yourself if you want it gone."
  fi
  exit 0
fi

# ---- preflight ---------------------------------------------------------------
MISSING=""
for c in jq git curl; do
  command -v "$c" >/dev/null 2>&1 || MISSING="$MISSING $c"
done
[ -z "$MISSING" ] || { echo "missing required commands:$MISSING" >&2; exit 1; }

mkdir -p "$BASE/data" "$BASE/logs"

# ---- config ------------------------------------------------------------------
# Never overwrite an existing config — it is the one file the person authors.
if [ ! -f "$BASE/config.env" ]; then
  cp "$TPL/config.env.example" "$BASE/config.env"
  echo "created $BASE/config.env from the template — FILL IT IN, then re-run this installer."
  NEW_CONFIG=1
else
  NEW_CONFIG=0
fi
cp "$TPL/config.env.example" "$BASE/config.env.example"

# ---- program files (always refreshed from the plugin) ------------------------
for f in collect.sh run.sh brief-prompt.md; do
  cp "$TPL/$f" "$BASE/$f"
done
chmod +x "$BASE/collect.sh" "$BASE/run.sh"
# Delivery cards travel with the brief so the headless runner and an agent session
# resolve the same path for them.
rm -rf "$BASE/delivery"
cp -R "$SKILL_DIR/delivery" "$BASE/delivery"
echo "installed collect.sh, run.sh, brief-prompt.md, delivery/ → $BASE"

if [ "$NEW_CONFIG" = 1 ]; then
  echo
  echo "Stopping here: config.env is still the unedited template."
  echo "Edit $BASE/config.env, then run: bash $SKILL_DIR/install.sh"
  exit 0
fi

# ---- validate the config -----------------------------------------------------
# shellcheck disable=SC1090
. "$BASE/config.env"

ERR=0
req() {
  eval "v=\${$1:-}"
  if [ -z "${v:-}" ]; then echo "  config.env: $1 is empty" >&2; ERR=1; fi
}
for k in BRIEF_DISPLAY_NAME BRIEF_GIT_AUTHORS BRIEF_DELIVERY; do req "$k"; done

# Delivery: every listed channel must be known AND have its target filled in.
# A brief with nowhere to go is the one failure worth blocking the install for.
for ch in ${BRIEF_DELIVERY:-}; do
  case " $KNOWN_CHANNELS " in
    *" $ch "*) ;;
    *) echo "  BRIEF_DELIVERY: unknown channel '$ch' (known:$KNOWN_CHANNELS)" >&2; ERR=1; continue ;;
  esac
  [ -f "$BASE/delivery/$ch.md" ] || { echo "  no delivery card for '$ch'" >&2; ERR=1; }
  case "$ch" in
    gchat)
      req BRIEF_GCHAT_SPACE_ID
      case "${BRIEF_GCHAT_USER_ID:-}" in
        users/*|"") ;;
        *) echo "  BRIEF_GCHAT_USER_ID should look like users/<numeric>, got: $BRIEF_GCHAT_USER_ID" >&2; ERR=1 ;;
      esac
      ;;
    slack) req BRIEF_SLACK_CHANNEL ;;
    email) req BRIEF_EMAIL_TO ;;
  esac
done

# Local half is optional — a machine with no clones runs cloud-only by design.
if [ -n "${BRIEF_REPO_ROOT:-}" ]; then
  if [ ! -d "$BRIEF_REPO_ROOT" ]; then
    echo "  BRIEF_REPO_ROOT does not exist: $BRIEF_REPO_ROOT" >&2; ERR=1
  else
    FOUND_REPO=0
    for r in ${BRIEF_REPOS:-}; do
      [ -d "$BRIEF_REPO_ROOT/$r/.git" ] && FOUND_REPO=1
    done
    [ "$FOUND_REPO" = 1 ] || echo "  NOTE: no BRIEF_REPOS clone found under $BRIEF_REPO_ROOT — the brief will run cloud-only"
  fi
else
  echo "  NOTE: BRIEF_REPO_ROOT empty — cloud-only brief (no git/session half)"
fi

# Headless runner config is only needed if you intend to use run.sh.
if [ -n "${BRIEF_MCP_SOURCE_DIR:-}" ] && [ ! -f "$BRIEF_MCP_SOURCE_DIR/.mcp.json" ]; then
  echo "  BRIEF_MCP_SOURCE_DIR is set but has no .mcp.json: $BRIEF_MCP_SOURCE_DIR" >&2; ERR=1
fi

[ "$ERR" = 0 ] || { echo "config.env has problems — fix them and re-run." >&2; exit 1; }
echo "config.env validated (delivery: ${BRIEF_DELIVERY})"

# ---- smoke-test the collector (no network, no tokens spent) ------------------
OUT="$(BRIEF_BASE="$BASE" bash "$BASE/collect.sh")"
echo "collector wrote $OUT ($(jq -r '[.git[]?|length]|add // 0' "$OUT") commit(s) in window)"

# ---- default stop: installed, usable, unscheduled ----------------------------
if [ "$MODE" = install ]; then
  echo
  echo "Installed and ready. Nothing is scheduled — the brief runs when you ask."
  echo
  echo "  in an agent session   /daily-brief  (\"brief me\") — cheapest, no nested CLI"
  echo "  from a terminal       bash $BASE/run.sh"
  echo "  check it works free   BRIEF_DRY_RUN=1 bash $BASE/run.sh"
  echo
  if launchctl list "$LABEL" >/dev/null 2>&1; then
    echo "Note: a schedule is already active ($LABEL). It keeps running."
    echo "Drop it with: bash $SKILL_DIR/install.sh --unschedule"
  elif [ "$(uname -s)" = "Darwin" ]; then
    echo "Want it every weekday morning?  bash $SKILL_DIR/install.sh --schedule"
  else
    echo "Scheduling is macOS-only (launchd). On Linux, wire $BASE/run.sh into cron yourself."
  fi
  exit 0
fi

# ---- launchd (opt-in: --schedule) -------------------------------------------
[ "$(uname -s)" = "Darwin" ] || {
  echo "--schedule needs macOS (launchd). Wire $BASE/run.sh into cron instead." >&2
  exit 1
}
command -v "${BRIEF_AGENT_CLI:-claude}" >/dev/null 2>&1 || {
  echo "--schedule needs the '${BRIEF_AGENT_CLI:-claude}' CLI on PATH: a scheduled run has no" >&2
  echo "agent session to borrow, so it must drive one itself." >&2
  exit 1
}

HOUR="${BRIEF_SCHEDULE_HOUR:-7}"
MINUTE="${BRIEF_SCHEDULE_MINUTE:-45}"
mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|__LABEL__|$LABEL|g" \
    -e "s|__BASE__|$BASE|g" \
    -e "s|__HOUR__|$HOUR|g" \
    -e "s|__MINUTE_PADDED__|$(printf '%02d' "$MINUTE")|g" \
    -e "s|__MINUTE__|$MINUTE|g" \
    "$TPL/launchd.plist.template" > "$PLIST"

plutil -lint "$PLIST" >/dev/null || { echo "generated plist is invalid: $PLIST" >&2; exit 1; }

launchctl unload -w "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"
echo "scheduled $LABEL — Mon–Fri at $HOUR:$(printf '%02d' "$MINUTE") local"
echo
echo "Still runnable on demand:  bash $BASE/run.sh   (or /daily-brief in an agent session)"
echo "Drop the schedule:         bash $SKILL_DIR/install.sh --unschedule"
echo "Watch a run:               tail -f $BASE/logs/$(date +%F).log"
