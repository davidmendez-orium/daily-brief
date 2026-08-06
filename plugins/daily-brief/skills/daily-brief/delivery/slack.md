# Delivery — Slack

Target: `identity.delivery.slack.channel`. Requires a connected Slack integration
(the Claude Slack connector, or any MCP server exposing Slack).

## Find the tools first — do not assume names

Slack reaches Claude through more than one integration, and their tool names
differ. **Discover, don't guess:** look through the available tools (or search
them) for a Slack pair — one that *posts a message to a channel*, and one that
*reads a channel's recent messages*. Typical shapes are `…send_message` /
`…post_message` and `…conversations_history` / `…list_messages`.

If the connector is present but unauthenticated, you will find only an
`authenticate` tool. That is not a failure you can work around: **stop, report
that Slack needs authenticating, and deliver the other configured channels.**
Never silently drop the channel, and never claim a Slack delivery you did not make.

## Format

Slack mrkdwn, which for everything this brief uses is identical to Google Chat:

| Want | Write |
|---|---|
| bold | `*bold*` |
| italic | `_italic_` |
| code | `` `code` `` |
| link | `<https://url\|label>` |

So **reuse the composed Google Chat text as-is**. Two Slack-specific deltas:

- **Mentions.** `identity.delivery.slack.user_id` (a `U…` id) becomes `<@U…>`. Use
  it only if the brief needs to ping the owner; a self-brief usually does not.
- **Channel refs.** `<#C123>` renders a channel link. Plain `#name` does not.

Slack's per-message ceiling is far above Google Chat's, but keep the same
under-4000-character discipline so one composition serves every channel.

## Duplicate check

Read the channel's recent messages (page size ~5) and look for TODAY's
`🗞️ Daily Brief — <today>` header from the bot. If present, report
`ALREADY_POSTED <TODAY>` for this channel and do not post.

If the connected integration exposes **no** history/read tool — only a write —
fall back to the sentinel file: `<base>/logs/.posted-slack-<TODAY>`. If it exists,
skip; otherwise post, then create it. Say in your report that the check was
sentinel-based, since a sentinel only knows what *this machine* posted.

## Send

Post the composed text to `identity.delivery.slack.channel`. The configured value
may be a channel id (`C…`) or a `#name`; pass it through as configured rather than
converting between them.

## Notes

- **Unverified end to end.** This card was written against the Slack integration
  contract, not against a live authenticated Slack. Treat the first real run as a
  test: confirm the message renders (links especially) before trusting it.
- Slack is a delivery target only. Scanning Slack as an inbound *source* — your
  mentions, unread DMs — is not implemented; `identity.sources` has no slack key.
