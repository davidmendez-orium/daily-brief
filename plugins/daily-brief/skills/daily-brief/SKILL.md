---
name: daily-brief
description: "Compose a personal daily work brief on demand, or set one up to run on a schedule — merging local git commits and agent-session activity with GitHub PRs, Jira tickets, Calendar, Gmail, and chat mentions, then delivering it to Google Chat, Slack, or email. Use when the user asks to be briefed or wants a standup or digest of their own recent work ('brief me', 'what did I do yesterday', 'run my brief'), or wants to install, configure, change the delivery channel, schedule, unschedule, or troubleshoot the daily brief. Triggers include 'brief me', 'daily brief', 'what did I ship yesterday', 'set up my daily brief', 'send my brief to Slack', 'email me my brief', 'run my brief now', 'schedule my brief', 'stop the daily brief', 'why didn't my brief arrive', '/daily-brief'."
---

# Daily brief

A brief of one person's recent work, delivered to Google Chat, Slack, or email.
**Runs on demand; scheduling is opt-in.**

Two layers, deliberately split:

- **`collect.sh`** — deterministic, no network, no LLM. Mines the local disk for
  what only it knows (git commits, agent-session activity, worktrees) plus
  `config.env`, and writes one `data/YYYY-MM-DD.json`.
- **`templates/brief-prompt.md`** — the content spec. Reads that JSON, pulls the
  cloud halves over MCP, composes a fixed-template brief, and delivers it via the
  per-channel cards in `delivery/`.

## Three ways to run it

| | How | When it fits |
|---|---|---|
| **In an agent session** | run `collect.sh`, then follow `brief-prompt.md` yourself | **the default for "brief me".** No nested CLI, no second model |
| **Terminal** | `bash $BASE/run.sh` | no agent session open; wraps a headless CLI behind an optional preflight and a model ladder |
| **Scheduled** | `launchd` fires `run.sh` Mon–Fri | **opt-in**, `install.sh --schedule`, macOS + a local agent CLI only |

Nothing depends on the schedule existing. A brief you never schedule is a fully
working brief.

`run.sh` writes everything to `$BASE/logs/<today>.log` **and** mirrors it to your
terminal when there is one, so a hand-run shows its work while a scheduled run stays
silent. To follow a run you did not start: `tail -f $BASE/logs/$(date +%F).log`.

## Know your platform before you promise anything

Read `reference/PLATFORMS.md` if anything below is unavailable. The short version:

- **Claude Code** — everything works: shell, local git, session transcripts,
  launchd scheduling.
- **Cowork, local execution** — shell and files work, but only inside **connected
  folders**, in a **Linux** VM. The collector is portable, so the local half works
  *if* the repo root is a connected folder. No launchd scheduling.
- **Cowork, cloud execution** (the default) — no local disk. `collect.sh` cannot
  run. The brief still works from its cloud sources, and **must say so** rather
  than implying a quiet day. No scheduling.

Never claim a local-git *Shipped* section on a platform that could not read the
repos. `local_capability` in the data JSON is there so you can tell the difference.

## Delivery is configurable

`BRIEF_DELIVERY` is a space-separated list of `gchat`, `slack`, `email`. Each has
a card in `delivery/<channel>.md` owning its own formatting, duplicate check, and
send call. The brief is **composed once** in chat markup (which serves Google Chat
and Slack unchanged) and transformed only for email.

Adding a channel means writing a new card and adding it to `KNOWN_CHANNELS` in
`install.sh` — not touching the prompt.

## Routing

| They want | Go to |
|---|---|
| **A brief now** — "brief me", "what did I do yesterday" | **Brief me now** |
| Install / set it up | **Setup** |
| A different destination — Slack, email, several | **Change delivery** |
| It to run on its own | **Schedule** / **Unschedule** |
| Change repos, name, time, sources | **Reconfigure** |
| "Did it run?" | **Status** |
| It did not arrive / arrived wrong | **Diagnose** |

If `$BASE/config.env` does not exist they are not set up — go to **Setup** first,
whatever they asked for. `$SKILL` is this skill's directory; `$BASE` is
`~/daily-brief` unless `BRIEF_BASE` is set.

## Brief me now

Do the work in this session. Do **not** shell out to `run.sh` — that spawns a
second agent to do what you can already do, at roughly a dollar and several
minutes of latency.

1. `bash $BASE/collect.sh` — deterministic, no spend. Prints the JSON path.
   If there is no shell, or it reports `git_repos_found: 0`, that is not an error:
   carry on cloud-only and follow the prompt's rule about saying so.
2. Read the JSON. Its `identity` block is who the brief is for, which sources to
   scan, and where it delivers — everything downstream depends on it.
3. Read **`$BASE/brief-prompt.md`** — the installed copy, not the template — and
   follow it from step 1. Using the installed copy keeps an interactive brief
   identical to a scheduled one.
4. Deliver per its step 3, one card per configured channel. **Deliver by
   default** — that is what a brief is for. Preview instead only if they asked
   ("show me", "don't send it", "draft"), and then say plainly nothing was sent.

Honour the prompt's cost rules: batch the whole gather into as few messages as you
can, and don't re-query to confirm something a payload already told you.

Report per channel, exactly. If a channel fails, say which and why. Never report a
delivery that did not happen.

## Setup

The installer does the file work; your job is `config.env`, the only part it
cannot guess.

1. **Lay down the files:** `bash $SKILL/install.sh`. On a first run this copies the
   config template and stops. Expected.

2. **Fill in `config.env`.** Derive what you can; ask only for the genuinely
   unknowable. In one batch:
   - `BRIEF_GIT_AUTHORS` — `git config user.email` **plus** every other address in
     `git log -500 --format='%ae' | sort | uniq -c | sort -rn`. Missing one hides
     those commits silently. Watch for machine-local identities like
     `tooling-setup@local`: fine on your own machine, but not unique to you, so
     confirm the commits are actually theirs before adding it.
   - `BRIEF_REPO_ROOT` / `BRIEF_REPOS` — parent dir and clone names. Leave the root
     empty if this machine has no clones.
   - `BRIEF_GITHUB_LOGIN` / `BRIEF_GITHUB_REPOS` — `github_get_viewer` and the
     `owner/name` of those repos.
   - `BRIEF_DELIVERY` and its target — **ask.** See **Change delivery**.
   - `BRIEF_DISPLAY_NAME`, `BRIEF_JIRA_PROJECT` — confirm rather than interrogate.
   - `BRIEF_MCP_SOURCE_DIR` — only if they want the terminal/scheduled path and
     their MCP config lives in a repo. Leave empty otherwise; the preflight is
     skipped and the agent's own config is used.

3. **Install for real:** `bash $SKILL/install.sh`. Validates and smoke-tests the
   collector. **Schedules nothing.**

4. **Offer a real brief** via **Brief me now** — the cheapest proof it works.

5. **Then offer the schedule as a question, not a default.** "Want this every
   weekday morning at 07:45, or run it when you feel like it?" Mention that an
   unattended run costs about a dollar a day and can fail unseen.

## Change delivery

Ask where it should go, then fill in only that channel's keys:

- **gchat** — `BRIEF_GCHAT_SPACE_ID` (bare id, no `spaces/`), and
  `BRIEF_GCHAT_USER_ID` (`users/<numeric>`, read off one of their own messages via
  `chat_list_messages`). Offer the list from `chat_list_spaces`; a private space or
  self-DM is a fine answer.
- **slack** — `BRIEF_SLACK_CHANNEL` (`C…` id or `#name`). Requires a connected,
  **authenticated** Slack integration. Check that before promising it works; if you
  find only an `authenticate` tool, say it needs authenticating.
- **email** — `BRIEF_EMAIL_TO`, default `me`. If they name anyone else, flag that
  the brief becomes outward communication and let them confirm the framing.

**Never invent a destination id.** A wrong space or channel id posts someone's
private brief into the wrong room. If you cannot determine it, say so.

Several channels at once is supported — space-separate them. They all get the same
brief, and one failing does not stop the others.

## Schedule / Unschedule

```bash
bash $SKILL/install.sh --schedule      # opt in  (macOS + local agent CLI)
bash $SKILL/install.sh --unschedule    # opt out, keeps everything else
```

Re-running `--schedule` replaces the job rather than stacking a second one. To
change the time, edit `config.env` then re-run it. After `--unschedule`, say the
brief still works on demand so they don't think they deleted it.

## Reconfigure

Edit `$BASE/config.env`, then re-run `bash $SKILL/install.sh` to re-validate.
Changes take effect on the next run by themselves — except the schedule time,
which needs `--schedule` again.

Never edit `$BASE/collect.sh`, `$BASE/run.sh`, `$BASE/brief-prompt.md`, or
`$BASE/delivery/` — the installer overwrites them. Behaviour changes belong in the
plugin's `templates/` and `delivery/`, committed, so everyone gets them.

## Status

```bash
bash $SKILL/install.sh --status
```

Files, config, configured channels, whether a schedule is active, and the last
five rows of `logs/cost.csv`. `schedule: off (manual only)` is a normal state, not
a fault — don't report it as one.

## Diagnose

Read `reference/TROUBLESHOOTING.md` before speculating — the recurring failures
are known and their symptoms mislead.

Narrow it first: most of that file is about *unattended* runs. If they only ever
run it in an agent session, the network gate, token latch, and wake-with-no-network
cases cannot apply — look at the content rules, the delivery card, and the target
id instead.
