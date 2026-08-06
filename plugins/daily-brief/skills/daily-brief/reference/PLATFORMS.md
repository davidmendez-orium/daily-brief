# Platforms — what works where

One plugin, two clients, three execution environments. The plugin format is shared,
but the *environment* differs, and the brief's local half depends on the
environment. Check this before telling someone what their brief will contain.

| | Claude Code | Cowork — local execution | Cowork — cloud execution |
|---|---|---|---|
| Plugin install | ✅ | ✅ | ✅ |
| Skill invocation | ✅ | ✅ | ✅ |
| Shell (`collect.sh`) | ✅ | ✅ *(Linux VM)* | ❌ |
| Local git repos | ✅ | ⚠️ connected folders only | ❌ |
| Agent-session transcripts | ✅ | ⚠️ if under a connected folder | ❌ |
| Cloud sources (GitHub, Jira, Calendar, Gmail, chat) | ✅ | ✅ | ✅ |
| Delivery (gchat / slack / email) | ✅ | ✅ | ✅ |
| `launchd` scheduling | ✅ | ❌ | ❌ |

## Why the local half is conditional

The brief has two halves. The **cloud half** — merged PRs, ticket transitions,
calendar, mail, mentions — is all MCP/connector calls and works everywhere. The
**local half** — your commits, which sessions you ran, which worktrees are open —
can only come from the machine holding the repos.

**Cowork defaults to cloud execution:** the agent loop and code execution run on
Anthropic's servers. There is no local disk to read, so `collect.sh` cannot run and
there is no git history to mine.

**Cowork local execution** runs shell commands in a Linux VM on the device, and can
read and write files in **connected folders** the user explicitly linked. So the
local half works, with two conditions:

1. The repo root must be inside a connected folder, or git finds nothing.
2. The userland is **Linux**, not BSD. `collect.sh` probes for this and switches
   between `date -v` / `date -d` and `stat -f` / `stat -c` — which is why it must
   not be "simplified" back to macOS-only calls.

## Degrading honestly

When the local half is missing, the brief is still worth sending — but it must not
read like a quiet day. `collect.sh` records what it could see:

```json
"local_capability": {
  "git_repos_found": 0,
  "repo_root": "",
  "sessions_available": false,
  "platform": "Linux"
}
```

`git_repos_found: 0` with a non-empty `repo_root` means the folder is not reachable
— a *capability* problem. An empty `repo_root` means cloud-only was configured
deliberately. Either way the brief carries one line under *Shipped*:

> `_Local git/session data unavailable — cloud sources only._`

The failure this prevents is the expensive one: a reader concluding they shipped
nothing yesterday when the truth is that nobody looked.

## Scheduling off macOS

`--schedule` writes a `launchd` plist, so it is macOS-only, and it needs a local
agent CLI on `PATH` — a scheduled run has no session to borrow and must drive one
itself. Neither holds in Cowork.

Alternatives, in preference order:

1. **Don't schedule.** Ask for a brief when you want one. This is the default for a
   reason.
2. **cron on Linux** — `run.sh` is portable; wire it up yourself. The
   wake-with-no-network gate is macOS-shaped but harmless elsewhere.
3. A CI cron or hosted scheduler invoking `run.sh`. Untested; it needs the agent
   CLI and credentials in that environment.
