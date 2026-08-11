#!/usr/bin/env bash
# Deterministic collector for the daily brief.
# Gathers what only the local disk knows — your git commits and agent-session
# activity — for the lookback window, and writes a single structured JSON at
# $BRIEF_BASE/data/YYYY-MM-DD.json for the LLM layer to read.
# No network, no LLM. Safe to run standalone: `bash collect.sh`.
#
# It also embeds config.env under `identity`, which is what keeps the prompt
# person- and channel-agnostic: the prompt reads one file and learns whose brief
# this is and where it goes, at no extra turn cost.
#
# Portable across BSD (macOS) and GNU (Linux) userland — Cowork's local execution
# runs in a Linux VM, so `date -v` / `stat -f` cannot be assumed.

set -eu

BASE="${BRIEF_BASE:-$HOME/daily-brief}"
DATA_DIR="$BASE/data"
CONFIG="$BASE/config.env"

[ -f "$CONFIG" ] || { echo "missing $CONFIG — copy config.env.example and fill it in" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONFIG"

: "${BRIEF_DISPLAY_NAME:?set in config.env}"
: "${BRIEF_GIT_AUTHORS:?set in config.env}"

REPO_ROOT="${BRIEF_REPO_ROOT:-}"
read -r -a REPOS <<<"${BRIEF_REPOS:-}"
read -r -a AUTHORS <<<"$BRIEF_GIT_AUTHORS"
SESSION_DIR="${BRIEF_SESSION_DIR:-$HOME/.claude/projects}"

mkdir -p "$DATA_DIR"

# ---- portability shims -------------------------------------------------------
# GNU date rejects -v, BSD date rejects -d. Probe once, branch never again.
if date -v-1d +%Y-%m-%d >/dev/null 2>&1; then DATE_FLAVOR=bsd; else DATE_FLAVOR=gnu; fi
if stat -f %m . >/dev/null 2>&1; then STAT_FLAVOR=bsd; else STAT_FLAVOR=gnu; fi

d_ago() {   # <days-back> <strftime-fmt>
  if [ "$DATE_FLAVOR" = bsd ]; then date -v-"$1"d "+$2"; else date -d "$1 days ago" "+$2"; fi
}
epoch_of_midnight() {   # <YYYY-MM-DD>
  if [ "$DATE_FLAVOR" = bsd ]; then
    date -j -f "%Y-%m-%d %H:%M:%S" "$1 00:00:00" +%s
  else
    date -d "$1 00:00:00" +%s
  fi
}
epoch_fmt() {   # <epoch> <strftime-fmt>
  if [ "$DATE_FLAVOR" = bsd ]; then date -r "$1" "+$2"; else date -d "@$1" "+$2"; fi
}
mtime() {   # <file>
  if [ "$STAT_FLAVOR" = bsd ]; then stat -f %m "$1"; else stat -c %Y "$1"; fi
}

TODAY="$(date +%Y-%m-%d)"
DOW="$(date +%u)"   # 1=Mon .. 7=Sun

# Lookback = last business day. Mon covers Fri+Sat+Sun; otherwise the prior day.
case "$DOW" in
  1) BACK=3 ;;   # Monday -> Friday
  *) BACK=1 ;;
esac
START="$(d_ago "$BACK" %Y-%m-%d)"
START_EPOCH="$(epoch_of_midnight "$START")"

# Human label for the window.
if [ "$BACK" -eq 1 ]; then
  WINDOW_LABEL="$(d_ago 1 '%a %b %d')"
else
  WINDOW_LABEL="$(d_ago "$BACK" '%a %b %d') – $(d_ago 1 '%a %b %d')"
fi

IS_MONDAY=false
[ "$DOW" -eq 1 ] && IS_MONDAY=true

# One entry per calendar day the brief covers, oldest first and ending with today.
# The brief spans two days on any normal morning — yesterday's finished work and
# whatever today has produced already — and four on a Monday. Reporting them as one
# undifferentiated list reads as if it all happened at once, so the days are named
# here rather than inferred downstream: `date` is what the git/session records
# carry, `rel` is what the reader is told.
DAYS_JSON="[]"
i="$BACK"
while [ "$i" -ge 0 ]; do
  case "$i" in
    0) rel=today ;;
    1) rel=yesterday ;;
    *) rel=earlier ;;
  esac
  DAYS_JSON="$(jq \
      --arg d "$(d_ago "$i" %Y-%m-%d)" \
      --arg l "$(d_ago "$i" '%a %b %d')" \
      --arg w "$(d_ago "$i" '%A')" \
      --arg r "$rel" \
      '. + [{date: $d, label: $l, weekday: $w, rel: $r}]' <<<"$DAYS_JSON")"
  i=$((i - 1))
done

# One --author flag per configured email; git ORs them.
AUTHOR_FLAGS=()
for a in "${AUTHORS[@]}"; do AUTHOR_FLAGS+=(--author="$a"); done

# ---- git: your commits per repo in [START 00:00, now] ------------------------
# Today is included. It used to stop at midnight, which meant the local half could
# never show work done this morning while the cloud half — GitHub and Jira, both
# queried from START — showed it anyway. The two halves disagreed about what "the
# window" meant, and the brief read as if today's PRs had landed with no commits
# behind them. Each commit carries its own `date` for grouping.
# Tab-delimited, parsed with an anchored capture whose last group swallows the rest
# of the line. Deliberately NOT a 0x1f delimiter: an invisible control byte in a jq
# program is silently destroyed by editors and copy-paste, and when it goes missing
# `split` splits on the empty string — i.e. into single characters — which yields a
# plausible-looking but entirely wrong result instead of an error.
git_repo_json() {
  local dir="$REPO_ROOT/$1"
  [ -d "$dir/.git" ] || { echo "[]"; return; }
  git -C "$dir" log "${AUTHOR_FLAGS[@]}" \
      --since="$START 00:00" \
      --pretty=format:'%H%x09%ad%x09%s' --date=short 2>/dev/null \
  | jq -R -s '
      split("\n") | map(select(length>0)) | map(
        . as $line
        | (capture("^(?<hash>[0-9a-f]+)\t(?<date>[^\t]+)\t(?<subject>.*)$")
           // {hash: "", date: "", subject: $line})
        | { hash: (.hash[0:9]), date: .date, subject: .subject,
            pr: ( .subject | capture("#(?<n>[0-9]+)").n // null ) }
      )'
}

GIT_JSON="{}"
REPOS_SEEN=0
if [ -n "$REPO_ROOT" ]; then
  for r in "${REPOS[@]}"; do
    [ -n "$r" ] || continue
    [ -d "$REPO_ROOT/$r/.git" ] && REPOS_SEEN=$((REPOS_SEEN + 1))
    GIT_JSON="$(jq --arg k "$r" --argjson v "$(git_repo_json "$r")" '. + {($k): $v}' <<<"$GIT_JSON")"
  done
fi

# ---- weekly recap (Mondays only): prior Mon–Sun commit tallies ---------------
WEEK_JSON="null"
if [ "$IS_MONDAY" = true ] && [ -n "$REPO_ROOT" ]; then
  WK_START="$(d_ago 7 %Y-%m-%d)"      # last Monday
  wk_obj="{}"
  wk_total=0
  for r in "${REPOS[@]}"; do
    dir="$REPO_ROOT/$r"
    [ -d "$dir/.git" ] || continue
    c="$(git -C "$dir" log "${AUTHOR_FLAGS[@]}" --since="$WK_START 00:00" --until="$TODAY 00:00" --oneline 2>/dev/null | wc -l | tr -d ' ')"
    wk_obj="$(jq --arg k "$r" --argjson v "$c" '. + {($k): $v}' <<<"$wk_obj")"
    wk_total=$((wk_total + c))
  done
  WEEK_JSON="$(jq -n --arg s "$WK_START" --arg e "$(d_ago 1 %Y-%m-%d)" \
      --argjson per "$wk_obj" --argjson total "$wk_total" \
      '{start:$s, end:$e, total_commits:$total, per_repo:$per}')"
fi

# ---- agent sessions active in the window -------------------------------------
# Claude Code names each project dir after its path with "/" replaced by "-", so
# stripping the encoded repo root leaves a bare repo name to label sessions with.
PROJ_PREFIX=""
[ -n "$REPO_ROOT" ] && PROJ_PREFIX="$(printf '%s/' "$REPO_ROOT" | tr '/' '-')"

# First meaningful user prompt per transcript (skip /command wrappers & tool noise).
first_prompt() {
  jq -rc '
    select(.type=="user") | .message.content
    | if type=="string" then .
      elif type=="array" then (map(select(.type=="text") | .text) | join(" "))
      else empty end
  ' "$1" 2>/dev/null \
  | grep -vE '^[[:space:]]*<' \
  | grep -vE 'command-name|local-command|stdout|system-reminder' \
  | grep -vE '^[[:space:]]*$' \
  | head -1 | cut -c1-200
}

SESS_JSON="[]"
SESSIONS_AVAILABLE=false
if [ -d "$SESSION_DIR" ]; then
  SESSIONS_AVAILABLE=true
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    mt="$(mtime "$f")"
    [ "$mt" -ge "$START_EPOCH" ] || continue
    proj_dir="$(basename "$(dirname "$f")")"
    proj="$proj_dir"
    [ -n "$PROJ_PREFIX" ] && proj="${proj_dir#"$PROJ_PREFIX"}"
    prompt="$(first_prompt "$f")"
    [ -n "$prompt" ] || continue
    msgs="$(grep -c '"type":"assistant"' "$f" 2>/dev/null || true)"; msgs="${msgs:-0}"
    last="$(epoch_fmt "$mt" '%Y-%m-%d %H:%M')"
    obj="$(jq -n --arg p "$proj" --arg pr "$prompt" --arg l "$last" --argjson m "$msgs" \
        '{project:$p, prompt:$pr, last_active:$l, assistant_msgs:$m}')"
    SESS_JSON="$(jq --argjson o "$obj" '. + [$o]' <<<"$SESS_JSON")"
  done < <(find "$SESSION_DIR" -name '*.jsonl' -not -path '*/subagents/*' 2>/dev/null)
  SESS_JSON="$(jq 'sort_by(.last_active) | reverse' <<<"$SESS_JSON")"
fi

# ---- in-flight: git worktrees per repo ---------------------------------------
WT_JSON="{}"
if [ -n "$REPO_ROOT" ]; then
  for r in "${REPOS[@]}"; do
    dir="$REPO_ROOT/$r"
    [ -d "$dir/.git" ] || continue
    wl="$(git -C "$dir" worktree list --porcelain 2>/dev/null \
          | awk '/^worktree /{w=$2} /^branch /{printf "%s\t%s\n", w, $2}' \
          | jq -R -s '
              split("\n") | map(select(length>0)) | map(
                capture("^(?<path>[^\t]+)\t(?<branch>.*)$")
                | { path, branch: (.branch | sub("^refs/heads/";"")) }
              )' )"
    [ "$(jq 'length' <<<"$wl")" -gt 1 ] && WT_JSON="$(jq --arg k "$r" --argjson v "$wl" '. + {($k):$v}' <<<"$WT_JSON")"
  done
fi

# ---- identity: config.env, shaped for the prompt -----------------------------
# `delivery.channels` is the list the prompt fans out over; each named block holds
# that channel's target. `sources` says which inbound scans to run — a Slack shop
# with no Google Chat must not be told to scan one.
IDENTITY_JSON="$(jq -n \
  --arg name "$BRIEF_DISPLAY_NAME" \
  --arg watermark "${BRIEF_WATERMARK:-Claude}" \
  --arg base "$BASE" \
  --arg gh_login "${BRIEF_GITHUB_LOGIN:-}" \
  --arg gh_repos "${BRIEF_GITHUB_REPOS:-}" \
  --arg jira_project "${BRIEF_JIRA_PROJECT:-}" \
  --arg channels "${BRIEF_DELIVERY:-gchat}" \
  --arg gchat_space "${BRIEF_GCHAT_SPACE_ID:-}" \
  --arg gchat_user "${BRIEF_GCHAT_USER_ID:-}" \
  --arg slack_channel "${BRIEF_SLACK_CHANNEL:-}" \
  --arg slack_user "${BRIEF_SLACK_USER_ID:-}" \
  --arg email_to "${BRIEF_EMAIL_TO:-}" \
  --arg email_subject "${BRIEF_EMAIL_SUBJECT_PREFIX:-Daily Brief}" \
  --arg gmail_exclude "${BRIEF_GMAIL_EXCLUDE:-}" \
  --argjson src_gchat "${BRIEF_SOURCE_GCHAT:-true}" \
  --argjson src_gmail "${BRIEF_SOURCE_GMAIL:-true}" \
  --argjson src_jira "${BRIEF_SOURCE_JIRA:-true}" \
  --argjson src_github "${BRIEF_SOURCE_GITHUB:-true}" \
  --argjson src_calendar "${BRIEF_SOURCE_CALENDAR:-true}" \
  '{
     display_name: $name,
     watermark: $watermark,
     brief_base: $base,
     github: { login: $gh_login, repos: ($gh_repos | split(" ") | map(select(length>0))) },
     jira:   { project_key: $jira_project },
     gmail:  { exclude: $gmail_exclude },
     delivery: {
       channels: ($channels | split(" ") | map(select(length>0))),
       gchat: { space_id: $gchat_space, user_id: $gchat_user },
       slack: { channel: $slack_channel, user_id: $slack_user },
       email: { to: ($email_to | split(" ") | map(select(length>0))),
                subject_prefix: $email_subject }
     },
     sources: {
       gchat: $src_gchat, gmail: $src_gmail, jira: $src_jira,
       github: $src_github, calendar: $src_calendar
     }
   }')"

# What the local half could actually see. The prompt uses this to decide whether a
# thin *Shipped* is a real quiet day or just a machine that cannot see the repos.
LOCAL_JSON="$(jq -n \
  --argjson repos_found "$REPOS_SEEN" \
  --argjson sessions "$SESSIONS_AVAILABLE" \
  --arg root "$REPO_ROOT" \
  --arg platform "$(uname -s)" \
  '{ git_repos_found: $repos_found, repo_root: $root,
     sessions_available: $sessions, platform: $platform }')"

# ---- assemble ----------------------------------------------------------------
OUT="$DATA_DIR/$TODAY.json"
jq -n \
  --arg gen "$(date '+%Y-%m-%d %H:%M %Z')" \
  --arg start "$START" --arg end "$TODAY" --arg label "$WINDOW_LABEL" \
  --argjson mon "$IS_MONDAY" \
  --argjson days "$DAYS_JSON" \
  --argjson identity "$IDENTITY_JSON" \
  --argjson local "$LOCAL_JSON" \
  --argjson git "$GIT_JSON" \
  --argjson week "$WEEK_JSON" \
  --argjson sess "$SESS_JSON" \
  --argjson wt "$WT_JSON" \
  '{
     generated_at: $gen,
     identity: $identity,
     local_capability: $local,
     window: { start: $start, end: $end, label: $label, is_monday: $mon, days: $days },
     week_recap: $week,
     git: $git,
     claude_sessions: $sess,
     worktrees: $wt
   }' > "$OUT"

echo "$OUT"
