---
name: daily-brief
description: "Compose and deliver a personal daily work brief — local git commits and agent-session activity merged with GitHub PRs, Jira tickets, Calendar, Gmail, and chat mentions — or install, configure, change the delivery channel, schedule, unschedule, or troubleshoot it. Composing a brief POSTS it to a configured Google Chat space, Slack channel, or mailbox, so trigger ONLY on an explicit request that names the brief. Triggers are 'brief me', 'run my brief', 'send my brief', 'daily brief', '/daily-brief', '/daily-brief standup', 'draft my standup', 'standup me', 'set up my daily brief', 'send my brief to Slack', 'email me my brief', 'schedule my brief', 'stop the daily brief', 'why didn't my brief arrive'. The standup draft is the one mode that posts nothing — it prints and saves a file. Do NOT trigger on incidental questions about recent work such as 'what did I do yesterday', 'what did I ship', or 'catch me up' — those are conversation to answer directly, not a request to post a brief to a channel."
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
independent — one failing does not stop the others.

**There is no desktop notification, by request.** It carried no useful detail and
fired on a machine nobody is watching. Chat, Slack, email — that is the whole
list. If none is configured, a failed run is discoverable only in the log; say so
plainly rather than implying someone will be told.

`run.sh` routes all three failure classes through it: dead bridge token (announced
once per distinct token, latched by hash so a 15-minute retry loop is not a
15-minute spam loop), no network before the budget expires, and every model attempt
failing.

**When setting someone up, ask about this explicitly if they schedule the brief.**
With no alert channel, nothing tells them a run failed — the failure mode is "I
noticed my brief never arrived", which is how it has actually gone wrong twice.

**The channels are not equally robust — say which you set up and what it covers.**
Webhooks carry their key in the URL and survive anything. Email goes through the
Gmail MCP, so it needs no new credential but dies with the bridge token — the very
failure most worth alerting about. Email alone is a partial net: it catches a
failed model run or a refusing delivery channel, not an expired token. Recommend
pairing it with a webhook, and do not describe an email-only setup as covered.

## Routing

**Invoked with no argument — `/daily-brief` on its own — means brief me now, and
deliver.** Go straight to **Brief me now**; do not present this table and do not
ask which they meant. Someone who types the bare command wants the brief, and
answering with a menu is the wrong response to an unambiguous request.

Every other entry needs them to say so. Naming the skill is not on its own a
request to post a brief — "is the daily brief scheduled?" is a question, not a
trigger.

| They want | Go to |
|---|---|
| **A brief now** — bare `/daily-brief`, "brief me", "run my brief" | **Brief me now** |
| **A standup draft** — `/daily-brief standup`, "standup me", "draft my standup" | **Standup** |
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

## Standup

A standup draft, not a brief. Same sources, different question: a brief summarises
a window, a standup splits work onto the day it **actually happened** — PR
`mergedAt` / `createdAt` from `gh`, Jira status moves from each issue's changelog.
The brief's window spans yesterday→now and labels the whole thing yesterday, which
is wrong often enough that this exists.

**It does not post.** Standups go into an existing thread, and no delivery channel
here can reply into one. It prints, it writes a file, and it offers — it never
assumes.

1. `bash $BASE/standup.py` — facts only, no spend. `--days N` widens the lookback
   (default: the last business day, so Monday looks back to Friday).
   **Do not pass `--llm`** — that shells out to a second model to do the one thing
   you are already here to do. It reads `BRIEF_GITHUB_REPOS` from `config.env` for
   GitHub and speaks JSON-RPC to the Jira MCP client for tickets, so both halves
   work without a separate token.
2. Polish it yourself, under the script's own rules: keep every ticket key and PR
   url exactly as printed — never shorten a url back to `#123`, the whole point is
   that a reader can click through and review — keep the Yesterday/Today split exactly as
   printed, and invent no work that is not listed. Tighten each line to plain
   English, one line per item. The trailing `Waiting on clarification` placeholder
   is not derivable from git or Jira — ask them what goes there, or drop it.
3. Write the polished text to `$BASE/data/standup-YYYY-MM-DD.md` **and** print it
   in the reply. Both, always: the file is what they paste from, the reply is what
   they read. Re-running the same day overwrites — a standup has one true version.
4. Then offer to post it, and **ask where**. Do not fall back to `BRIEF_DELIVERY`;
   that is where the brief goes, which is not necessarily where standup goes. Take
   a Google Chat space or a Slack channel from them, and if they name a *thread*,
   say plainly that opening a new one is the only thing these tools can do.

The script degrades rather than failing: an unauthenticated `gh` or an unreachable
Jira prints a `warn:` line and yields a partial draft. Pass that gap on — a
GitHub-only standup that reads as complete is worse than one labelled partial.

## Check dependencies

The brief is only as good as the MCP servers behind it. A config can validate
perfectly and still fail at delivery because a connector was never authenticated.
Check before promising anything — at setup, when delivery changes, and whenever a
brief fails for a reason that smells like a missing tool.

**Two checks, and they see different things.**

1. `bash $BASE/check-deps.sh` — maps the config's channels and sources to the
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
> 2. Re-check: `bash $BASE/install.sh --check-deps`
>
> Google Chat and email are ready now; you can run a brief on those today.

If everything is satisfied, say so in one line and move on — no ceremony.

## Setup

The installer does the file work; your job is `config.env`, the only part it
cannot guess.

1. **Lay down the files:** `bash $SKILL/install.sh`. On a first run this copies the
   config template and stops. Expected.

   This is the only command that needs `$SKILL`. It copies itself, `check-deps.sh`,
   `templates/`, `delivery/` and `reference/` into `$BASE`, so everything after it
   runs from `$BASE/install.sh` — a stable path, unlike the plugin's, which carries
   a commit hash and moves on every update. Give people the `$BASE` form.

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

3. **Install for real:** `bash $BASE/install.sh`. Validates the config,
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
bash $BASE/install.sh --schedule      # opt in  (macOS + local agent CLI)
bash $BASE/install.sh --unschedule    # opt out, keeps everything else
```

Re-running `--schedule` replaces the job rather than stacking a second one. To
change the time, edit `config.env` then re-run it. After `--unschedule`, say the
brief still works on demand so they don't think they deleted it.

## Reconfigure

Edit `$BASE/config.env`, then re-run `bash $BASE/install.sh` to re-validate.
Changes take effect on the next run by themselves — except the schedule time,
which needs `--schedule` again.

Never edit anything in `$BASE` except `config.env` and the webhook files. Everything
else — `collect.sh`, `run.sh`, `notify.sh`, `brief-prompt.md`, `install.sh`,
`check-deps.sh`, `standup.py`, `templates/`, `delivery/`, `reference/` — is a copy the installer
overwrites, so an edit there survives exactly until the next install and then
vanishes without a word. Behaviour changes belong in the plugin repo, committed, so
everyone gets them.

`$BASE/templates/` is the local source the contained installer copies from, not a
place to develop. Editing it then running `$BASE/install.sh` does apply the change —
and the next plugin install silently reverts it.

## Status

```bash
bash $BASE/install.sh --status
```

Files, config, configured channels, whether a schedule is active, and the last five
runs — from `logs/runs.db` (date, start, duration, attempts, model, tool calls,
tokens, cost, outcome), falling back to `logs/cost.csv` where sqlite3 is missing.
`schedule: off (manual only)` is a normal state, not a fault — don't report it as
one.

Every run appends a row to both, aborted ones included, so a `SKIPPED_NO_NETWORK`
that waited four hours is as visible as a delivery.

## Diagnose

Read `reference/TROUBLESHOOTING.md` before speculating — the recurring failures
are known and their symptoms mislead.

Narrow it first: most of that file is about *unattended* runs. If they only ever
run it in an agent session, the network gate, token latch, and wake-with-no-network
cases cannot apply — look at the content rules, the delivery card, and the target
id instead.
