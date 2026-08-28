You are assembling the **daily brief** for one person and delivering it to their
configured channels. Work autonomously end-to-end — no questions, no pauses. Do
not narrate your steps.

Whose brief this is, and where it goes, comes from the data file in step 0 — never
from your own assumptions. Below, **OWNER** means `identity.display_name` from
that file; use their actual name in the prose, never the word "OWNER".

**Two ways this spec gets run, same content either way:**

- *Headless* — `run.sh` feeds this file to a CLI agent on a schedule or on demand.
  Nobody is watching, so the autonomy rules above are absolute.
- *In an agent session* — the agent reads this file and executes it directly, with
  no nested CLI. Cheaper and faster, since the session's tool connections are
  already live.

## Style
Technical comms. Clear, concise, effective — but **complete**. This brief is
OWNER's single source of truth for what happened and what needs them; missing an
item is a much worse failure than being a line longer. Detail is wanted; padding
is not.

- **One line per item, carrying its specifics** — ID, PR number, status, person,
  commit subject. Concision means no wasted words, NOT fewer facts.
- **State facts, not reasoning.** Drop "likely", "probably", "worth a look",
  "might be", "no action needed yet". If you can't state it as fact, cut it.
- **Inbound sections are source-of-truth and are NEVER emptied.** *Email*, *Chat*,
  and *Tags* must list every qualifying item, even when *Focus* also references it.
  *Focus* is DERIVED — it never consumes an item. Concretely: if a DM needs a
  reply, it appears in *Chat* with who said what, AND (optionally) in *Focus* as
  "Reply to Sam re `KEY-123`." Rendering an inbound section as "None." because the
  fact already appeared in *Focus* is a BUG, not concision.
- **Say each fact once** applies only to how it's WORDED: *Focus* carries the
  action (verb + ID), the inbound section carries the detail. Never repeat the
  full who/what/why in both.
- **Never drop an item to save space.** If you're near the limit, cut adjectives,
  not entries. If you genuinely must truncate a list, say "(+N more)" with the
  count — never silently.
- **Empty section = one word.** "None."
- Names: **first name only** — "Sam", "Priya", "Alex T." if two people share a
  first name. Never a full legal name.
- **NEVER use a gendered pronoun for anyone.** Not he/him, not she/her, ever — a
  name does not tell you someone's pronouns. Use their name again, or they/them.
  Wrong: "Sam owned reassigning it to herself." Right: "Sam took it over." This
  rule has been broken before; re-read every line for pronouns before delivering.

## 0. Load the local data
In one call, get TODAY and the brief's base directory:
`date +%F; echo "${BRIEF_BASE:-$HOME/daily-brief}"`.
Read `<base>/data/<TODAY>.json`. If it is missing, run `bash <base>/collect.sh`.

That file carries everything person- and channel-specific, so read it first:

- `identity` — who this is for and where it goes. `display_name`, `watermark`,
  `github.login`, `github.repos`, `jira.project_key`, `gmail.exclude`,
  **`delivery.channels`** (the list you fan out over in step 3), and `sources`
  (which inbound scans to run). **Treat these as fact. Never spend a turn
  verifying them** — no `github_get_viewer`.
- `window` — `start` (yesterday, or last business day) and `end` (today). Use it
  for every date filter below.
  **`window.days`** is the list of calendar days the brief covers, oldest first
  and always ending with today: `{date, label, weekday, rel}` where `rel` is
  `today`, `yesterday`, or `earlier`. Two entries on a normal day; four on a
  Monday, which reaches back to Friday and picks up any weekend work. This is the
  spine of *Shipped* — never collapse those days into one list.
- `git` — LOCAL commits keyed by repo, each with `hash`, `date`, `subject`, `pr`.
  **Report every commit** — do not summarise them away. `date` is what assigns a
  commit to a day in *Shipped*; today's commits are included, so a brief run at
  midday shows this morning's work.
- `claude_sessions` — agent sessions active in the window: `{project, prompt,
  last_active, assistant_msgs}`. This is the record of work that produced no
  commit, and on a day of research, review or repo-wrangling it is the ONLY
  evidence the day happened. `worktrees`, `week_recap` (Mondays only).
- `local_capability` — what the local half could actually see. Read this before
  concluding anything from an empty `git`.

### When there is no local half
Some environments have no shell, or no access to the person's repos — a cloud
agent session, or a desktop session where the repo folder was never connected.
Then `collect.sh` cannot run, or runs with `local_capability.git_repos_found: 0`.

Do not treat that as a quiet day, and do not invent local activity. Instead:

- Build the brief from the cloud sources alone. They carry most of it: merged PRs,
  ticket transitions, calendar, mail, mentions.
- **Say so in the brief**, once, under *Shipped*: `_Local git/session data
  unavailable — cloud sources only._` A reader must never mistake "could not look"
  for "nothing happened".
- If you cannot even read the data file, you still have `identity` nowhere — and
  without it you do not know where to deliver. **Stop and say that**, rather than
  guessing a destination.

Below, `KEY` means `identity.jira.project_key` and `<start>` means `window.start`.

## 1. Gather the CLOUD halves
Local + cloud on every source — merge, don't duplicate. **Run a source only if its
`identity.sources.<name>` is true**; skip the others silently, they are switched
off deliberately. If an enabled source errors, note it in one line under its
section and continue; never abort the whole brief.

**Efficiency — this is a HARD requirement, not a preference.**
Every turn re-reads all prior tool output, so cost ≈ turns × context. A run that
takes 50 turns costs 4× the same run in 12. Therefore:

- **Turn budget: gather everything in AT MOST 3 assistant messages.** Every source
  below is independent. Fire them as parallel tool calls in one message — the whole
  set is ~12 calls and belongs in ONE batch, not twelve.
- **Round 2** is only for calls that genuinely need round-1 output (chat message
  lists, Jira changelogs). Batch those in parallel too.
- **Then compose and deliver.** Do not re-query to double-check something you
  already have; do not call a tool to "verify" a fact already in a payload.
- **No detail follow-ups**: no `jira_get_issue`, `gmail_get_message`, or
  `github_get_pull_request` to enrich what a search already returned.
- Don't request fields you won't print.

Completeness still wins over cost: never drop a required item to save tokens. Cut
TURNS, not content — those are independent levers.

**GitHub** (`sources.github`). Search `identity.github.repos`, `per_page=15`.
Three searches, no more — the first covers open AND merged, so don't run a
separate open-PR query. Substitute `identity.github.login` for LOGIN:
- `is:pr author:LOGIN updated:>=<start>` — note merged vs open per result, and
  review state where the payload carries it. Keep every PR's `html_url`: each one
  is printed as a link, so it is a field you will print. Keep each merged PR's
  `pull_request.merged_at`: that date, not `updated_at`, is the day it belongs to
  in *Shipped*. A PR merged Friday and commented on today is Friday's.
- `is:pr review-requested:LOGIN state:open` — awaiting OWNER's review.
- `is:pr mentions:LOGIN updated:>=<start>` — review comments/mentions.
- Reconcile against the local `git` commits: each PR appears once, and a local
  commit with no PR still gets reported as a commit.

**Jira** (`sources.jira`). Pass `fields="summary,status,updated"`, `limit=20`.
Two searches, not three — one covers both worked-in-window and in-flight:
- `assignee = currentUser() AND (updated >= "<start>" OR status in ("In Progress","In Review","In Development")) ORDER BY updated DESC`
  Then partition the results yourself: recently-updated → *Shipped*/transitions,
  open statuses → *In flight*.
- Mentions needing OWNER: `comment ~ currentUser() AND updated >= "<start>" ORDER BY updated DESC`,
  with `comment` added to `fields`. Do NOT include `text ~ currentUser()` — it
  matches OWNER's name anywhere in an issue and floods the result with false
  positives.
  **Use `limit=5` here, not 20.** `comment` returns every comment body on every
  matched issue; at 20 issues this payload has hit 600k+ characters and been
  spilled to a file. If that happens, do NOT read the file back in — filter it in
  the shell and read only the result, e.g.
  `jq -r '.issues[] | .key as $k | (.fields.comment.comments//[]) | map(select(.created >= "<start>")) | .[] | "\($k) \(.author.displayName): \([.body|..|.text?//empty]|join(" ")|.[0:200])"' <file>`
  Then **filter the hits yourself**: keep one only if a comment written in the
  window actually addresses or @-mentions OWNER. **Never skip this section because
  the result set was noisy** — filtering it down is the job. If after filtering
  there are none, say "None."
- **Status changes:** call `jira_get_changelog` only for issues whose `updated`
  falls inside the window — **cap 5**, newest first, one parallel batch. Report
  real transitions as `KEY-123: In Progress → Done`. Say how many you skipped if
  you hit the cap.

**Google Chat** (`sources.gchat`). Two things: messages mentioning OWNER, and DMs
awaiting their reply. OWNER's Chat user id is `identity.delivery.gchat.user_id`.
- `chat_list_spaces` (`page_size=100`). Each space carries **`lastActiveTime`** —
  use it: scan ONLY spaces whose `lastActiveTime >= <start>`. That is exact, so
  there is no need to cap or guess, and no space with activity gets skipped.
- Then in ONE parallel batch, `chat_list_messages` on each of those with
  `filter='createTime > "<start>T00:00:00+00:00"'`, `page_size=10`.
- Report (a) messages whose text mentions OWNER or @-mentions their user id, and
  (b) DMs whose LATEST message is from someone else — i.e. awaiting their reply.
- **Report the actual exchange**, not just that one happened: who said what, and
  any ticket/link in it.
- Skip `identity.delivery.gchat.space_id` if the brief is delivered there — that
  space is this report, not inbound.
- Ignore `singleUserBotDm` spaces — those are bots, not people.
- **LIMITATION:** the Chat API exposes no per-user unread state. "Unread" is
  approximated as "latest message isn't OWNER's". If you list any, label the
  section honestly as awaiting-reply, not unread.

**Calendar** (`sources.calendar`). Primary calendar, today's events only
(00:00–23:59 local) → the *Today* list. Do not fetch yesterday's events; nothing
in the brief uses them.

**Gmail** (`sources.gmail`). Mail that genuinely needs OWNER.
- `gmail_search`, `max_results=10`, query: `newer_than:2d (is:important OR
  is:starred OR label:inbox is:unread)` followed by `identity.gmail.exclude`
  verbatim.
- Excluding those notification senders in the QUERY is deliberate — they surface
  in *Tags* from the source of truth. Human-written mail only.
- **Anything that needs a reply must appear.** Flag 🔴 reply vs 👀 read; put every
  🔴 in the list before trimming any 👀.

**Best-effort extras**, if the tools happen to be available: pages or comments
mentioning OWNER in a wiki (Confluence), and a memory store queried for notes or
action items OWNER left themselves. Fold anything actionable into *Notes*. Skip
quietly on error — neither is required.

## 2. Compose the brief

**Compose ONCE, in chat markup** — `*bold*` headers (NOT `#`), `-` bullets,
backticks for IDs, `<url|label>` for links. That format serves Google Chat and
Slack unchanged; email is transformed from it in step 3. Composing per channel is
how the channels drift apart, so don't.

Order exactly:

*🗞️ Daily Brief — <Weekday>, <Mon DD>*  ·  _covers <first day's label> → today_

If `window.is_monday`, one line of _Last week:_ — commit/PR/ticket tallies from
`week_recap`. Numbers, not narrative.

*📅 Today* — `HH:MM title`, time-ordered. Mark the next one `←`. "None." if empty.

*✅ Shipped* — everything that landed in the window, **grouped by day**:

- **One sub-heading per entry in `window.days`, in that order** — oldest first,
  today last. Format it `_<rel capitalised>, <label>_`, so `_Yesterday, Mon Aug 10_`
  and `_Today, Tue Aug 11_`; an `earlier` day is just its label, `_Sat Aug 08_`.
  A Monday therefore reads Friday, Saturday, Sunday, Today.
- **Assign every item to the day it happened**, by its own timestamp: a commit by
  its `date`, a merged PR by its merge date, a Jira transition by the changelog
  entry's date. An item whose day cannot be determined goes under the oldest day
  rather than today — dating work forward is the error that misleads.
- **Skip a day with nothing in it.** Weekends are usually empty and a row of
  "None." per weekend day is noise. If *every* day is empty, one "None." for the
  whole section.
- Within a day: merged PRs first (linked, with the ticket and a short what), then
  **every commit** grouped by repo — `` `hash` subject ``, including commits with
  no PR. That is the git detail; do not collapse it into a count. Then Jira
  transitions as `KEY-123: <from> → <to>`.
- **A day with real activity but no commits is not an empty day.** If a day has no
  PR, commit or transition, but `claude_sessions` holds entries whose
  `last_active` falls on it, add one line under that day:
  `_Worked on:_ <project> — <short phrase from its prompt>`, at most four, busiest
  first by `assistant_msgs`. Exploration, pulling and reading repos, design work
  and attempts that were abandoned are all real work that leaves no commit behind,
  and a day of it rendered as "None." is the same wrong answer as an unscanned
  repo — it just looks honest. **Never present these as shipped**: they are what
  was worked on, not what landed, and the wording must keep that distinction.
- The local-data-unavailable line from step 0, if it applies, goes once at the end
  of the section — not per day.

Today's group is normally short or absent on a 07:45 run, and that is correct — do
not pad it, and do not pull yesterday's work forward to fill it.

*🔄 In flight* — open PRs (+ review state if known), in-progress tickets with
status, active worktrees/branches.

**Every open PR carries its link** — `<url|#123>`, never a bare number. This
section is what a reader acts on, and a PR they cannot click is a PR they do not
review. A PR whose url you do not have is listed with its number and the note that
the link is missing, not silently dropped.

*🎯 Focus* — 3–5 bullets, imperative, verb first. Concrete next action only, no
rationale. The one judgment section.

*📝 Notes* — action items OWNER left themselves, not already in Focus. Skip if none.

*📧 Email* — `Sender — subject`, 🔴 reply / 👀 read. Every 🔴 listed. A direct
question, a doc shared for comment, or anything addressed to OWNER personally is
🔴 — an all-👀 list means you under-classified; re-check before settling on it.

*💬 Chat* — messages mentioning OWNER (`space/sender — gist`) and DMs awaiting
their reply. Label honestly per the limitation above. "None." if empty.

*🏷️ Tags* — GitHub review requests, PR/Jira/wiki mentions. `<link|ID> — Name` +
what they want.

**The three inbound sections stay flat — do not group them by day.** They are short
and current, and splitting five items across four Monday headings buries them.
Instead date each item that is *not* from today, at the end of the line: `(Mon)` on
a normal day, `(Fri)` / `(Sat)` on a Monday. Items from today carry no marker, so
an undated line means "today". Two people asking the same thing on different days
is exactly what this makes visible.

Rules: no invented items. **Keep the message under 4000 characters** — that is
Google Chat's ceiling minus headroom, and holding to it for every channel is what
lets one composition serve all of them. If you're over, trim in this order —
adjectives, then the "what" clauses in *Shipped*, then 👀 emails, then oldest
commits — and say "(+N more)" for anything cut. Never drop a 🔴 email, a *Chat*
item, or a *Tags* item to fit; those are the point of the brief.

Watermark: end with `— generated by <identity.watermark> · <timestamp>`.

## 3. Deliver

1. Write the composed markup to `<base>/data/brief-<TODAY>.md`. This happens in
   every mode — it is the archive, not the delivery.

2. **For each channel in `identity.delivery.channels`**, read
   `<base>/delivery/<channel>.md` and follow it. Each card owns its own three
   things: how to format, how to check for a duplicate, and how to send. Channels
   are independent — **one channel failing must not stop the others.**

3. Report one line per channel, and be exact about what happened:
   `POSTED <TODAY> gchat (3485 chars)` · `ALREADY_POSTED <TODAY> slack` ·
   `FAILED email — <reason>`.
   Then a final line: `DELIVERED <TODAY> (<n> ok, <n> already, <n> failed)`.

   The headless runner greps this to decide whether to retry, so the words matter.
   Never print a success marker for a channel you did not deliver to.

**Preview instead — only when the invoking instructions said so** (an interactive
"show me the brief, don't send it"):

- Do step 1, skip step 2 entirely. Show the brief in the reply and say plainly
  that nothing was delivered, naming the channels it would have gone to.
- Do not silently downgrade a delivery to a preview. If you could not deliver for
  a reason of your own — a tool error, an unauthenticated connector, a missing
  target id — that is `FAILED`, and you say why. A preview is a choice the human
  made, never a fallback you picked.
