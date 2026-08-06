# Delivery — Email

Target: `identity.delivery.email.to` (a list). Requires a Gmail MCP server with
`gmail_send_email` / `gmail_send_email_as_agent` and `gmail_search`.

## Format

Email is the one channel that cannot take the composed chat text as-is: chat
markup renders as literal punctuation in a mail client, and `<url|label>` is not a
link anywhere but Google Chat and Slack.

Transform the composed brief mechanically — do not recompose it, or the channels
drift apart:

| Chat markup | HTML |
|---|---|
| `*bold*` | `<b>bold</b>` |
| `_italic_` | `<i>italic</i>` |
| `` `code` `` | `<code>code</code>` |
| `<https://url\|label>` | `<a href="https://url">label</a>` |
| `- item` | `<li>item</li>` inside `<ul>` |
| section header line | `<h3>` |
| blank line | paragraph break |

Wrap in a minimal document — a readable sans-serif stack, nothing clever:

```html
<div style="font-family:-apple-system,Segoe UI,Roboto,sans-serif;font-size:14px;line-height:1.5;max-width:680px">
  …content…
</div>
```

**Escape before you convert.** `&`, `<`, `>` inside commit subjects and email
subject lines must become `&amp;`, `&lt;`, `&gt;`, or a commit message containing
`<` silently eats the rest of the line. Escape the text first, then insert tags.

The 4000-character discipline does not apply to email. Keep it anyway: the point
is that every channel shows the same brief.

## Subject

`<identity.delivery.email.subject_prefix> — <Weekday>, <Mon DD>`

Keep it exactly this shape — the duplicate check greps for it.

## Duplicate check

`gmail_search` with `in:sent subject:"<subject_prefix>" newer_than:1d`. If today's
subject is already there, report `ALREADY_POSTED <TODAY>` and do not send.

## Send

`gmail_send_email_as_agent` — `to` = the configured list, `subject` as above,
HTML body. `me` is a valid recipient meaning the authenticated mailbox, and is the
default.

## Notes

- **Recipients other than yourself change the stakes.** A self-brief can be blunt
  about half-finished work; a brief sent to a manager or a team alias is outward
  communication. If `to` contains anyone but `me` / the owner's own address, say so
  before sending and let the human confirm the framing — do not quietly send a
  private-tone brief to an audience.
- Sending mail is not reversible. If the duplicate check errors, prefer reporting
  the failure to sending a possible duplicate.
