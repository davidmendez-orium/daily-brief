# Delivery — Google Chat

Target: `identity.delivery.gchat.space_id`. Requires a Google Chat MCP server with
`chat_send_message` and `chat_list_messages`.

## Format

Google Chat markup — **not** standard markdown:

| Want | Write | Never |
|---|---|---|
| bold | `*bold*` | `**bold**` |
| italic | `_italic_` | `*italic*` |
| code | `` `code` `` | — |
| link | `<https://url\|label>` | `[label](https://url)` — renders as literal text |
| section header | `*🗞️ Section*` | `# Section` |

This is the canonical composition format for the brief, and Slack's mrkdwn is
near-identical, so a brief composed for Google Chat needs no translation for
Slack. Only email requires a transform.

**Hard limit 4096 characters; stay under 4000.** Trim per the prompt's trim
order, and say `(+N more)` for anything cut.

## Duplicate check

Call `chat_list_messages` on the space, `page_size=5`. If a message posted TODAY
matches the `🗞️ Daily Brief — <today>` header, do not post again — report
`ALREADY_POSTED <TODAY>` for this channel and move on.

This matters because the headless runner retries on failure; without it a retry
double-posts.

## Send

`chat_send_message` with `space` = the configured space id, `text` = the brief.

## Notes

- The space id is the bare id (no `spaces/` prefix) — e.g. `AAQAgqWbBcM`.
- If this space is also scanned as an inbound source, the prompt already excludes
  it: the brief is not news to itself.
- A Chat *incoming webhook* can post to a space without MCP, and that is what the
  runner uses to announce a dead bridge token — but it cannot read the space, so
  it is unusable for the duplicate check and is not a delivery option here.
