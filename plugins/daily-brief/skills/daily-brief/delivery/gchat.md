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

**`chat_list_messages` returns OLDEST first.** A bare `page_size=5` therefore
returns the space's five *earliest* messages and will never show today's brief —
a check written that way silently always passes. Verified against a real space.

Two correct ways, cheapest first:

1. **Use `lastActiveTime`.** `chat_list_spaces` already reports it per space, and
   the Chat source scan usually has that payload in hand. If the delivery space's
   `lastActiveTime` is earlier than today, nothing was posted today — done, no
   further call.
2. **Read newest-first.** `chat_list_messages` with `order_by="createTime desc"`
   and `page_size=5`, then match the `🗞️ Daily Brief — <today>` header.

If today's brief is there, report `ALREADY_POSTED <TODAY>` for this channel and
move on. This matters because the headless runner retries on failure; without a
working check a retry double-posts.

## Send

`chat_send_message` with `space` = the configured space id, `text` = the brief.

## Notes

- The space id is the bare id (no `spaces/` prefix) — e.g. `AAQAgqWbBcM`.
- If this space is also scanned as an inbound source, the prompt already excludes
  it: the brief is not news to itself.
- A Chat *incoming webhook* can post to a space without MCP, and that is what the
  runner uses to announce a dead bridge token — but it cannot read the space, so
  it is unusable for the duplicate check and is not a delivery option here.
