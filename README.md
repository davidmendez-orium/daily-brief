# Daily Brief

A plugin for **Claude Code** and **Claude Cowork** that composes a personal daily
work brief and delivers it to Google Chat, Slack, or email.

It merges what only your machine knows — your git commits, agent sessions, open
worktrees — with what only the cloud knows — merged PRs, ticket transitions, today's
calendar, mail that needs a reply, chat mentions — into one message.

```
🗞️ Daily Brief — Thursday, Aug 06  ·  covers Wed Aug 05

📅 Today
- 10:00 Sprint planning ←
- 14:30 1:1

✅ Shipped
- humble: `f1730a41a` fix media attachments syncing to CT (#2649, merged)
- PROJ-2224: In Review → Done

🔄 In flight
- PR #2651 GA4 add_to_cart — 1 change requested from Sam

🎯 Focus
- Address Sam's review on #2651
- Reply to Priya re PROJ-2788 rate grain

📧 Email
- Priya — Re: FX rate on order 🔴 reply

💬 Chat
- eng-web/Sam — asked whether #2651 needs a QA pass before merge

🏷️ Tags
- <link|#2644> — Alex requested your review
```

## Install

```
/plugin marketplace add davidmendez-orium/daily-brief
/plugin install daily-brief@daily-brief
```

`daily-brief@daily-brief` reads oddly — the first is the plugin, the second the
marketplace it came from. Both are named after the repo.

Then, in a session:

```
/daily-brief
```

It walks you through setup the first time — deriving what it can, asking only for
what it can't guess (chiefly *where* the brief should go).

## How it works

Two layers, split so the expensive one does as little as possible:

| Layer | What | Cost |
|---|---|---|
| `collect.sh` | deterministic local scan → one JSON | free, no network |
| `brief-prompt.md` | cloud gather → compose → deliver | one agent run |

Everything person-specific lives in `~/daily-brief/config.env`. The collector embeds
it into the day's JSON, so the prompt carries no identity of its own and retargeting
the brief is a config edit, never a prompt edit.

## Three ways to run it

- **In a session** — `/daily-brief`, or just "brief me". The agent runs the
  collector and follows the spec itself. Cheapest: no nested CLI, no second model.
- **Terminal** — `bash ~/daily-brief/run.sh`. Wraps a headless agent run behind an
  optional network/credential preflight and a model fallback ladder.
- **Scheduled** — opt in with `install.sh --schedule` for a weekday `launchd` job.
  macOS only, and never required.

## Delivery

`BRIEF_DELIVERY` is a space-separated list:

| Channel | Needs | Duplicate check |
|---|---|---|
| `gchat` | a Google Chat MCP server | reads the space |
| `slack` | a connected, authenticated Slack integration | reads the channel, else a local sentinel |
| `email` | a Gmail MCP server | greps sent mail for today's subject |

Several at once is fine — they get the same brief, and one failing doesn't stop the
others. Each channel's rules live in
`plugins/daily-brief/skills/daily-brief/delivery/<channel>.md`; adding a channel
means adding a card, not editing the prompt.

## Platform support

| | Claude Code | Cowork (local) | Cowork (cloud) |
|---|---|---|---|
| Cloud half + delivery | ✅ | ✅ | ✅ |
| Local git / sessions | ✅ | connected folders only | ❌ |
| Scheduling | ✅ | ❌ | ❌ |

With no local half the brief runs from cloud sources and **says so** — it never
implies a quiet day when the truth is that nobody could look. Details in
`skills/daily-brief/reference/PLATFORMS.md`.

## Dependency check

The brief needs an MCP server behind each channel it delivers to and each source it
scans. `install.sh` works out which ones this config needs and reports them:

```
MCP dependencies for delivery=[gchat slack email]:
  [  ok  ] chat       chat                        deliver to Google Chat; scan mentions
  [ auth ] slack      claude.ai Slack             deliver to Slack
  [MISSING] github    -                           find your PRs and reviews

NEXT STEPS — the brief will fail on these until they are resolved:
  slack — 'claude.ai Slack' is configured but not usable. Authenticate it:
      claude mcp login "claude.ai Slack"
```

It is **non-fatal by design**: a config can be perfectly correct while a connector
is merely unauthenticated, and blocking would leave you with nothing to re-run once
you fix it. Re-check any time with `install.sh --check-deps`, or
`check-deps.sh --porcelain` for machine-readable output.

The skill goes further in a session — it can see its own tool list (the only check
that works in Cowork), offers to register a server you already have defined
elsewhere, and prints exactly what is left for you to do by hand.

## Alerting

Delivery goes over MCP; **alerts go over incoming webhooks**, deliberately. What an
alert usually reports is a dead shared credential — and every MCP server
authenticates with it, so announcing the failure through them cannot work. A
webhook carries its own key.

Drop a URL in `~/daily-brief/gchat-webhook.url` or `~/daily-brief/slack-webhook.url`
(or both) and every failure — dead token, no network, all model attempts spent —
fans out to all of them plus a desktop notification. Test it any time:

```bash
bash ~/daily-brief/notify.sh "test alert"
```

Email cannot be an alert channel: it sends through the Gmail MCP and dies with the
same credential.

## Requirements

- `jq`, `git`, `curl`
- macOS or Linux (the collector probes for BSD vs GNU `date`/`stat`)
- MCP servers for the sources you enable and the channel you deliver to
- An agent CLI on `PATH` only for the terminal and scheduled paths

## Repo layout

```
.claude-plugin/marketplace.json      the marketplace catalog
plugins/daily-brief/
├── .claude-plugin/plugin.json       the plugin manifest
└── skills/daily-brief/
    ├── SKILL.md                     routing + the interactive path
    ├── install.sh                   idempotent installer, --schedule/--status/…
    ├── check-deps.sh                MCP dependency report (also run by install)
    ├── templates/notify.sh          webhook fan-out for failure alerts
    ├── templates/                   collect.sh, run.sh, brief-prompt.md, config
    ├── delivery/                    gchat.md, slack.md, email.md
    └── reference/                   PLATFORMS.md, TROUBLESHOOTING.md
```

`plugin.json` deliberately omits `version`, so installs track the git commit SHA and
every push reaches users without a version bump.

## Status

Google Chat delivery is exercised daily. Email and Slack are implemented to their
integration contracts but **not yet verified end to end** — Slack in particular
needs an authenticated connector, which the card tells the agent to check for and
report rather than assume.

## License

MIT
