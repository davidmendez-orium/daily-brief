# Daily brief — failure modes

Ordered by how often they actually happen. Each has a symptom that points somewhere
misleading, so check the named evidence before theorising.

**Narrow the scope first.** Sections 1–3 are about *unattended* runs — a scheduled
`launchd` job or a bare `run.sh`. If the brief is only ever run inside an agent
session, none of them can happen: there is no timer to miss, no headless preflight,
and a dead credential surfaces as a visible tool error instead of a silent wait.
Skip to §4 onward for problems common to every path.

---

## 1. No brief, and the run cost 4–7× normal

**Symptom.** `logs/cost.csv` shows a `FAILED` row with several attempts and spend
far above the usual. The log says every attempt died with "MCP servers never
surfaced any tools" — identically.

**Cause.** The machine was asleep at the scheduled time. `launchd` fires a missed
calendar interval on the next **DarkWake** — a ~2-second maintenance window with no
usable network — then re-sleeps and freezes the process. The MCP clients cannot
reach anything, so every rung of the fallback ladder fails the same way at full
price.

**Evidence.** `pmset -g log | grep -E "Sleep|DarkWake"` — not the app logs. The app
logs only show the downstream symptom.

**Mitigation, already in place.** `run.sh` polls the bridge before spending
anything, and the wall clock keeps advancing across sleep, so the run resumes on
wake instead of burning the budget. `caffeinate -i` is held only during real work —
never while polling, so a sleeping laptop just resumes the poll on wake, which is
the wanted behaviour on a plane.

**The nastier variant: the machine slept *mid-run*.** The gate passed at 07:45, the
laptop slept at 08:00, and attempts 2 and 3 ran on wake at 09:40 with the network
still coming up. Those attempts do *not* announce a network problem. The stdio
client answers `tools/list` with a live bridge fetch — once, no retry, no cache —
so a server whose fetch fails **connects and serves zero tools** for the whole
attempt. The agent then reports its sources as "no Chat MCP tool is connected in
this session", or invents "the bridge token expired", and composes from whatever
is left.

**Do not trust that self-report.** Verify the credential by hand before renewing
anything: `curl -s -X POST "$BRIDGE_BASE/chat" -H "X-Mcp-Bridge-Token: $TOKEN"
-d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'`. The real evidence
is the headless transcript — under `~/.claude/projects/-/` when launchd ran it,
since the cwd is `/`. Grep it for `No matching deferred tools found`: a run with
zero MCP tools shows the agent hunting for them over and over.

**Fixed by** re-running the readiness gate before **every** attempt, and probing
`tools/list` on every configured service rather than `initialize` on one — the
bridge answers `initialize` without exercising the service, so it passed while the
call the client actually makes was failing. `--strict-mcp-config` is passed too, so
a degraded run cannot silently compose from unrelated connectors in the user's own
config and report itself complete.

**Deliberately not done.** `pmset repeat` to force a wake. Waking the machine every
weekday morning to send a message is not worth it; a late brief is fine.

## 2. Blocked on a bridge/MCP credential

**Symptom.** Log shows `token bridge_token_invalid|expired|superseded` and the run
sits re-checking every 15 minutes.

**Cause.** Remote-bridge tokens expire. Renewal is a browser SSO flow and **cannot**
be automated from a headless run — the pipeline can only wait for a human.

**What happens.** The preflight announces it once per distinct token (latched by
hash in `logs/.token-alert-fingerprint`), then polls; the brief delivers as soon as
the token goes valid. If the wait crosses midnight or the 8h budget, the run aborts
rather than blocking the next day, and `cost.csv` records `STALE_ABANDONED` or
`TOKEN_WAIT_EXHAUSTED`.

**`bridge_token_superseded` is different** — a newer export replaced the token.
Reinstall from the latest build; refreshing will not help.

**Why the alert needs a webhook.** Delivery runs over MCP, and the MCP servers
authenticate with the very token that died — so a dead token cannot be announced
through the same path that delivers. `notify.sh` therefore fans out over **incoming
three channels, all of them if configured: a Google Chat webhook
(`$BASE/gchat-webhook.url`), a Slack webhook (`$BASE/slack-webhook.url`), and
email (`BRIEF_ALERT_EMAIL_TO`, via the Gmail MCP).

**Only the webhooks can report a dead bridge token.** Email goes through the Gmail
MCP, which authenticates with that same token — so in the one failure that has
actually bitten twice, an email-only setup is silent. With no channel at all, a
failed run is discoverable only in the log.

Verify yours works without waiting for a real failure:

```bash
bash ~/daily-brief/notify.sh "test alert"
```

It prints one line per channel and exits 1 if nothing took it. Nothing fires on
the desktop, so a test run is safe to repeat.

**Not applicable** when `BRIEF_MCP_SOURCE_DIR` is unset, or when the config has no
bridge token — both gates are skipped entirely.

## 3. Cost drifted up

Cost is dominated by cached MCP tool **results** across turns, not tool schemas.
Trimming `BRIEF_SERVERS` barely moves it; the model choice and the **turn count**
do. `brief-prompt.md` enforces a 3-message gather budget — if `turns` in
`logs/last-run-usage.json` is well above ~15, the model stopped batching, and that
is the thing to fix.

Reference point: ~$0.94/run on a mid-tier model, ~$1.79 on a frontier one, with the
mid tier holding full quality on this structured task. That is why the ladder starts
there and only falls back when capacity-blocked.

---

## 4. *Shipped* is empty and that looks wrong

**First check `local_capability` in the day's JSON, not the git config.**

- `git_repos_found: 0` with a non-empty `repo_root` → the machine could not see the
  repos. In Cowork that usually means the folder is not a *connected folder*; see
  `PLATFORMS.md`.
- `platform: "Linux"` → you are in Cowork's local VM. The collector is portable, but
  if someone "simplified" `collect.sh` back to `date -v` / `stat -f`, every date
  call fails silently and the window collapses. Run `bash collect.sh` directly and
  read stderr.
- Everything present and still empty → check `BRIEF_GIT_AUTHORS`. Miss one address
  and every commit under it vanishes with no warning. Verify with
  `git log -500 --format='%ae' | sort | uniq -c | sort -rn`.

A genuinely absent local half must show the line `_Local git/session data
unavailable — cloud sources only._` If *Shipped* is empty and that line is missing,
the brief is lying about a quiet day — that is a bug in the run, not in the config.

## 4b. A tool the brief needed was not there

**Symptom.** A section is empty, or a channel reports `FAILED`, and the underlying
error is a missing or unauthorized tool rather than anything about the data.

**Check first.** `bash "$BASE/install.sh" --check-deps` maps this config's channels
and sources to the servers they need and reports each one. Exit `3` means something
is unmet; the report carries the exact fix command.

Two blind spots worth knowing:

- It reads the **local agent CLI's** configuration. Connectors enabled in a client
  UI (Cowork) do not appear, and it exits `4` — "cannot tell" — rather than
  claiming they are missing.
- "Connected" is a health check, not a permission check. A server can be connected
  and still refuse the specific call, e.g. a Chat server that cannot post to a space
  you are not a member of.

An agent session should trust its own tool list over this script.

## 5. Delivered to the wrong place, or not at all

- **Wrong space/channel.** The target ids are `identity.delivery.*` in the day's
  JSON, sourced from `config.env`. A brief in the wrong room is almost always a
  transcription error there, not a prompt bug.
- **Slack silently missing.** The Slack integration must be *authenticated*. If only
  an `authenticate` tool is available, the card says to report it and continue with
  other channels — a run that reports Slack as delivered without an authenticated
  connector is misreporting. Check the per-channel report lines.
- **Slack duplicate.** If the connected integration has no history/read tool, the
  card falls back to a sentinel file at `logs/.posted-slack-<date>`. A sentinel only
  knows what *this machine* did, so two machines can both post. Delete the sentinel
  to force a resend.
- **Email duplicate.** The check greps sent mail for the exact subject
  `<prefix> — <Weekday>, <Mon DD>`. Changing `BRIEF_EMAIL_SUBJECT_PREFIX` mid-day
  lets exactly one duplicate through, by design — the old subject no longer matches.
- **One channel failed, others fine.** Correct behaviour. Channels are independent;
  the summary line counts each outcome.
- **Run history says `ok` but nobody got a brief.** The runner reads the agent's own
  report to decide success. `DELIVERED <date> (0 ok, 0 already, 1 failed)` announces
  that nothing was delivered, but it still contains the word DELIVERED and a date —
  matching on the marker alone scored that as success, so the run exited 0 and no
  alert fired. The counts now outrank the marker, and the marker is only consulted
  when no counts are present. If you extend the report format, keep the counts
  parseable.

## 6. Delivered twice to the same channel

Should not happen: each card checks for today's brief before sending. `run.sh`
treats `ALREADY_POSTED` as success, which is what makes the retry ladder safe. If a
duplicate appears, the check did not run — look for an attempt that delivered and
then crashed before printing its report line, so the runner retried a completed run.

## 7. A section says "None." when it should not

The prompt's most-violated rule. *Email*, *Chat*, and *Tags* are source-of-truth
sections and are never emptied because the fact already appeared in *Focus* —
*Focus* is derived and consumes nothing. Fix belongs in `templates/brief-prompt.md`,
committed, not in the installed copy (which the installer overwrites).

Same class of bug: gendered pronouns for teammates, and markdown `[label](url)`
links, which Google Chat and Slack both render as literal text.

## 8. Sessions show up with mangled project names

`collect.sh` labels sessions by stripping the encoded `BRIEF_REPO_ROOT` from the
transcript's project directory name (the CLI replaces `/` with `-`). If
`BRIEF_REPO_ROOT` does not match where the clones live, labels come out as full
encoded paths. Fix the config, not the script.

---

## Testing the failure paths

`run.sh` honours these so you never have to break anything real:

| Variable | Effect |
|---|---|
| `BRIEF_DRY_RUN=1` | readiness gate and collector, then stop — no spend, no delivery |
| `BRIEF_BASE` | run against a throwaway directory |
| `BRIEF_AGENT_CLI` | swap the CLI for a stub echoing a canned result JSON — exercises the whole success path, run-history row included, for free |
| `BRIEF_GATE_POLL` / `BRIEF_GATE_MAX` | shorten the first readiness wait |
| `BRIEF_REGATE_MAX` | shorten the per-attempt re-check |
| `BRIEF_TOKEN_POLL` | shorten the credential re-check interval |
| `BRIEF_GCHAT_WEBHOOK_FILE` | point the alert somewhere harmless |
| `BRIEF_QUIET=1` | suppress the terminal mirror, log to file only |

**`config.env` overrides your environment, not the other way round.** It assigns
`BRIEF_*` unconditionally and `run.sh` sources it *after* reading the env, so
`BRIEF_MCP_SOURCE_DIR=... bash run.sh` is silently ignored. Edit a copy of
`config.env` inside the throwaway `BRIEF_BASE` instead. Getting this wrong points a
"broken bridge" test at the real bridge and spends real money.

### Where the output goes

`run.sh` logs everything to `logs/<today>.log`, and **also mirrors it to your
terminal when it detects one** — so a hand-run shows its work while a `launchd`
run (no tty) stays silent as before. `BRIEF_QUIET=1` forces file-only. To watch a
run you did not start interactively:

```bash
tail -f ~/daily-brief/logs/$(date +%F).log
```

`BRIEF_DRY_RUN=1 bash run.sh` is the fastest way to answer "is my setup sane".
`bash collect.sh` alone is safer still: no network, no LLM, no delivery.

To rehearse delivery without sending, ask for a **preview** in an agent session —
it composes and archives the brief, and sends nothing.
