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

## Alerting — how it tells you it failed

Delivery and alerting use **different transports on purpose**, and conflating them
is the mistake to avoid.

| | Transport | Why |
|---|---|---|
| Delivery | MCP servers / connectors | can read the channel back, so duplicates are detectable |
| Alerts | incoming **webhooks** | survive the failure being announced |

The thing an alert usually reports is a dead shared credential — and the Chat MCP,
the Gmail MCP and the Slack connector all authenticate with it. Announcing a dead
token through them cannot work. A webhook carries its own key in its URL.

`notify.sh` fans one short message out to **every** service with a webhook
configured (`$BASE/gchat-webhook.url`, `$BASE/slack-webhook.url`). Channels are
independent — one failing does not stop the others. A desktop notification is the
**fallback**, fired only when no webhook took it: once a webhook exists the alert
belongs where the person will see it, and popping a system notification too is
just noise on the machine.

**When testing, set `BRIEF_NOTIFY_NO_DESKTOP=1`.** Verifying the webhook path
should never put notifications on someone's screen — a handful of test runs in a
few minutes reads as spam, and it has.

`run.sh` routes all three failure classes through it: dead bridge token (announced
once per distinct token, latched by hash so a 15-minute retry loop is not a
15-minute spam loop), no network before the budget expires, and every model attempt
failing.

**When setting someone up, ask about this explicitly if they schedule the brief.**
With no webhook the only alert is a desktop notification, which nobody sees on a
closed laptop — the failure mode is then "I noticed my brief never arrived", which
is how it has actually gone wrong. **Email cannot serve here**: sending mail goes
through the Gmail MCP and dies with the same token, so an email-only setup still
needs a Chat or Slack webhook.

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
| To be told when it fails | **Alerting** |
| "Do I have the right MCPs?" | **Check dependencies** |

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

## Check dependencies

The brief is only as good as the MCP servers behind it. A config can validate
perfectly and still fail at delivery because a connector was never authenticated.
Check before promising anything — at setup, when delivery changes, and whenever a
brief fails for a reason that smells like a missing tool.

**Two checks, and they see different things.**

1. `bash $SKILL/check-deps.sh` — maps the config's channels and sources to the
   servers they need and reports each as connected / needs-auth / missing, with
   the exact command to fix it. Exit `0` satisfied, `3` unmet, `4` cannot tell.
   It asks the local agent CLI, so it is authoritative for Claude Code and
   **blind** to connectors enabled in a client UI.
2. **Your own tool list** — the authoritative check, and the only one available in
   Cowork or when `check-deps.sh` exits `4`. Confirm you can actually see a send
   tool for each delivery channel and a query tool for each enabled source.

Where they disagree, trust your tool list. Say which check you used.

### Then offer to fix them — don't just fix them

Present what is unmet and let them choose. Some of this touches their MCP config,
which is theirs, not yours.

**What you can do for them**, with their agreement:

- **Copy a server they already have elsewhere.** If the server is defined in
  `BRIEF_MCP_SOURCE_DIR/.mcp.json` but not registered, `claude mcp add-json <name>
  '<json>'` registers it. Non-interactive, reversible with `claude mcp remove`.
  Show the name and where it came from before running it.
- **Switch off what they don't want.** A missing source is often not worth
  installing — flipping `BRIEF_SOURCE_GCHAT=false` is a legitimate fix, and
  cheaper than adding a connector they'll never otherwise use. Offer it.

**What only they can do:**

- **Authenticate a connector** — `claude mcp login "<name>"` opens a browser and
  cannot run unattended. Ask them to run it themselves: suggest they type
  `! claude mcp login "<name>"`.
- **Add a connector in the client UI** — Cowork connectors, and anything not
  already defined in a config you can read.

Never invent an install command for a server you cannot see the definition of.
Guessing a package name or URL produces a config that fails later and looks like
it was set up correctly.

### Close with what's left

Whatever they chose, end with a short, literal next-steps list — the exact
commands for anything they opted to do themselves, and what will happen if they
don't:

> **Before your first brief:**
> 1. `! claude mcp login "claude.ai Slack"` — Slack delivery fails without it
> 2. Re-check: `bash $SKILL/install.sh --check-deps`
>
> Google Chat and email are ready now; you can run a brief on those today.

If everything is satisfied, say so in one line and move on — no ceremony.

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

3. **Install for real:** `bash $SKILL/install.sh`. Validates the config,
   smoke-tests the collector, and runs the dependency check. **Schedules nothing.**

4. **Resolve any unmet dependencies** — see **Check dependencies**. The installer
   reports them but never blocks on them, so this is your job, not its.

5. **Offer a real brief** via **Brief me now** — the cheapest proof it works.

6. **Then offer the schedule as a question, not a default.** "Want this every
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

**After changing a channel, re-run the dependency check** — a new channel usually
means a new server, and finding that out at delivery time is the expensive way.

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
