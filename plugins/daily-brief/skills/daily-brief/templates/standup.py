#!/usr/bin/env python3
"""Assemble a standup draft from GitHub + Jira, bucketed by the day things
actually happened.

Companion to collect.sh. Where the daily brief's window spans yesterday->now and
labels the whole thing as yesterday, this splits on real timestamps: PR mergedAt
/ createdAt from `gh`, and Jira status transitions from each issue's changelog.

  ./standup.py                 # facts only, ready to paste
  ./standup.py --llm           # pipe the facts through `claude -p` for prose
  ./standup.py --days 3        # widen the lookback (default: last business day)

--llm is for the terminal. In an agent session the agent already is the model, so
it runs this bare and does the polishing itself rather than paying for a second
one -- see the Standup section of SKILL.md.

GitHub uses the local `gh` auth. Jira speaks JSON-RPC to the teleos stdio client
using the bridge credentials in mcp.json, so no separate Jira token is needed.
"""

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys

BASE = os.environ.get("BRIEF_BASE", os.path.expanduser("~/daily-brief"))
MCP_JSON = os.path.join(BASE, "mcp.json")
CONFIG = os.path.join(BASE, "config.env")

TICKET_RE = re.compile(r"\b([A-Z][A-Z0-9]+-\d+)\b")


def read_config():
    """Pull the handful of config.env values we need, without sourcing it."""
    out = {}
    if os.path.exists(CONFIG):
        for line in open(CONFIG):
            m = re.match(r'\s*([A-Z_]+)\s*=\s*"?([^"\n]*)"?', line)
            if m:
                out[m.group(1)] = m.group(2)
    return out


def business_day_before(today):
    """Mon looks back to Fri; every other day looks back one day."""
    delta = 3 if today.weekday() == 0 else 1
    return today - dt.timedelta(days=delta)


# ---- Jira over the teleos stdio client --------------------------------------

def jira_call(tool, arguments):
    """One JSON-RPC round trip: initialize -> initialized -> tools/call."""
    servers = json.load(open(MCP_JSON))["mcpServers"]
    spec = servers["atlassian"]
    env = {**os.environ, **spec.get("env", {})}

    msgs = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                    "clientInfo": {"name": "standup", "version": "1.0"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": tool, "arguments": arguments}},
    ]
    proc = subprocess.run(
        [spec["command"], *spec["args"]],
        input="\n".join(json.dumps(m) for m in msgs) + "\n",
        capture_output=True, text=True, env=env, timeout=120,
    )
    for line in proc.stdout.splitlines():
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if msg.get("id") == 2:
            if "error" in msg:
                raise RuntimeError(f"{tool}: {msg['error']}")
            content = msg["result"]["content"][0]["text"]
            return json.loads(content)
    raise RuntimeError(f"{tool}: no response ({proc.stderr.strip()[:200]})")


def jira_my_keys(since):
    """Issues assigned to me touched since <since> — the starting candidate set.

    Returns (fields-by-key, my-accountId); the id lets us tell my own status
    moves apart from ones QA or a lead made on my tickets.
    """
    jql = f'assignee = currentUser() AND updated >= "{since:%Y-%m-%d}" ORDER BY updated DESC'
    res = jira_call("jira_search",
                    {"jql": jql, "fields": "summary,status,assignee", "limit": 50})
    issues = {i["key"]: i["fields"] for i in res.get("issues", [])}
    me = next((f["assignee"]["accountId"] for f in issues.values() if f.get("assignee")), None)
    return issues, me


def jira_transitions(key, since):
    """Status moves on <key> at or after <since>, as (when, to, author-id, author)."""
    res = jira_call("jira_get_changelog", {"issue_key": key, "max_results": 100})
    moves = []
    for entry in res.get("values", []):
        when = dt.datetime.fromisoformat(entry["created"]).astimezone()
        if when < since:
            continue
        author = entry.get("author") or {}
        for item in entry.get("items", []):
            if item.get("field") == "status":
                moves.append((when, item["toString"],
                              author.get("accountId"), author.get("displayName", "someone")))
    return moves


# ---- GitHub over gh ----------------------------------------------------------

def gh_prs(repo, since):
    """My PRs in <repo> with any activity since <since>."""
    fields = "number,title,url,createdAt,mergedAt,state,isDraft"
    try:
        raw = subprocess.run(
            ["gh", "pr", "list", "--repo", repo, "--author", "@me",
             "--state", "all", "--limit", "50", "--json", fields],
            capture_output=True, text=True, check=True, timeout=60,
        ).stdout
    except subprocess.CalledProcessError as e:
        print(f"warn: gh failed for {repo}: {e.stderr.strip()[:120]}", file=sys.stderr)
        return []

    out = []
    for pr in json.loads(raw):
        pr["repo"] = repo
        for field in ("createdAt", "mergedAt"):
            pr[field] = (dt.datetime.fromisoformat(pr[field].replace("Z", "+00:00")).astimezone()
                         if pr[field] else None)
        if (pr["mergedAt"] and pr["mergedAt"] >= since) or pr["createdAt"] >= since \
           or pr["state"] == "OPEN":
            out.append(pr)
    return out


def ticket_of(text):
    m = TICKET_RE.search(text or "")
    return m.group(1) if m else None


def strip_key(title, key):
    """Drop <key> from a PR title -- the caller already prints it as a label.

    Only where the key is a tag rather than prose: leading ("KEY-1 do the
    thing", "[KEY-1] do the thing"), or trailing in brackets, which is how a
    conventional-commit title carries it ("feat(x): do the thing (KEY-1)").
    A key mentioned mid-sentence is part of the sentence and is left alone.
    """
    if not key:
        return title
    k = re.escape(key)
    out = re.sub(rf"^\W*{k}\W*", "", title, count=1)
    out = re.sub(rf"\s*[(\[]{k}[)\]]\s*[.:]?\s*$", "", out, count=1).strip()
    # A title that was nothing but the key leaves the reader with a dash and
    # blank space; keep the original instead.
    return out or title


# ---- assembly ----------------------------------------------------------------

def build(days=None):
    cfg = read_config()
    now = dt.datetime.now().astimezone()
    today = now.date()
    yday = today - dt.timedelta(days=days) if days else business_day_before(today)
    since = dt.datetime.combine(yday, dt.time.min).astimezone()

    buckets = {yday: [], today: []}
    # (day, key) -> last status seen that day, so a ticket that walked
    # To Do -> In Progress -> In Review reports only where it landed.
    landed = {}

    def add(day, line):
        """Drop anything older than the lookback on the floor."""
        if day in buckets and line not in buckets[day]:
            buckets[day].append(line)

    prs = []
    for repo in (cfg.get("BRIEF_GITHUB_REPOS") or "").split():
        prs.extend(gh_prs(repo, since))

    review = []
    for pr in prs:
        key = ticket_of(pr["title"]) or ""
        label = f"{key} " if key else ""
        title = strip_key(pr["title"], key)
        # The url, not the bare number: a standup is read to be acted on, and
        # nobody looks up a PR by number to go review it.
        if pr["mergedAt"] and pr["mergedAt"] >= since:
            add(pr["mergedAt"].date(), f"- Merged {label}({pr['url']}) — {title}")
        if pr["createdAt"] >= since and not pr["mergedAt"]:
            add(pr["createdAt"].date(), f"- Opened {label}({pr['url']}) — {title}")
        if pr["state"] == "OPEN" and not pr["isDraft"]:
            review.append(f"   • {label}{pr['url']}".replace("  ", " "))

    issues, in_progress, me = {}, [], None
    try:
        issues, me = jira_my_keys(since)
    except Exception as e:                                  # noqa: BLE001
        print(f"warn: jira unavailable ({e}); GitHub-only draft", file=sys.stderr)

    keys = set(issues) | {t for t in (ticket_of(p["title"]) for p in prs) if t}
    for key in sorted(keys):
        try:
            moves = jira_transitions(key, since)
        except Exception:                                   # noqa: BLE001
            continue
        for when, new, author_id, author in moves:
            landed[(when.date(), key)] = (new, author if author_id != me else None)
        status = (issues.get(key) or {}).get("status", {}).get("name")
        if status == "In Progress":
            summary = issues[key].get("summary", "")
            in_progress.append(f"- Now on {key} — {summary}")

    # Grooming sweeps (a dozen tickets to To Do in one sitting) are one line,
    # not a dozen. Everything else reports individually.
    for day in buckets:
        by_status = {}
        for (d, key), (status, by_other) in landed.items():
            if d == day:
                by_status.setdefault(status, []).append((key, by_other))
        for status, entries in sorted(by_status.items()):
            keys = sorted(k for k, _ in entries)
            if len(keys) >= 3 and status in ("To Do", "Screening"):
                add(day, f"- Queued {len(keys)} tickets to {status} ({keys[0]}–{keys[-1]})")
            else:
                for key, by_other in sorted(entries):
                    who = f" (moved by {by_other})" if by_other else ""
                    add(day, f"- {key} → {status}{who}")

    return buckets, yday, today, review, in_progress


def render(buckets, yday, today, review, in_progress):
    lines = [f"*Yesterday ({yday:%a %b %-d})*"]
    lines += buckets[yday] or ["- (nothing recorded)"]
    lines.append("")
    lines.append(f"*Today ({today:%a %b %-d})*")
    lines += buckets[today] or ["- (nothing recorded yet)"]
    if review:
        lines.append("- In review, looking for eyes:")
        lines += sorted(set(review))
    lines += in_progress
    lines.append("")
    lines.append("- Waiting on clarification: <fill in — not derivable from git/Jira>")
    return "\n".join(lines)


POLISH = """Rewrite this standup draft for a team chat. Keep every ticket key and
PR url exactly as given -- never shorten a url to its number, the link is the point
-- keep the Yesterday/Today split exactly as given, and do not invent work that is
not listed. Tighten each line to plain readable
English, one line per item. Drop the placeholder line if it is still unfilled.
Return only the standup text."""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--llm", action="store_true", help="polish the prose via `claude -p`")
    ap.add_argument("--days", type=int, help="lookback in days (default: last business day)")
    args = ap.parse_args()

    draft = render(*build(args.days))
    if args.llm:
        draft = subprocess.run(["claude", "-p", f"{POLISH}\n\n{draft}"],
                               capture_output=True, text=True, check=True).stdout.strip()
    print(draft)


if __name__ == "__main__":
    main()
