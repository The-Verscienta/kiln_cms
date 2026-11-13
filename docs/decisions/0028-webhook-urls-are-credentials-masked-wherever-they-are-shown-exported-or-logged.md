# 0028. Webhook URLs are credentials, masked wherever they are shown, exported or logged

- **Status** — accepted (2026-11-12).
- **References** — [#2245](https://github.com/The-Verscienta/kiln_cms/issues/2245)
  (part 2, PR #2793), [#2796](https://github.com/The-Verscienta/kiln_cms/issues/2796);
  the open follow-up [#2794](https://github.com/The-Verscienta/kiln_cms/issues/2794)
  (encrypt URLs at rest, scrub them on staging clones); the threat model's
  URL-disclosure bullet.
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md)
  (#2793).

## The problem

A webhook endpoint's URL was treated as configuration: shown in full on the
Webhooks page, pre-filled in its edit form, named in the delivery history,
the governance trail and its exports, the "Retraction not delivered" notice
and the log line behind it.

For many receivers the URL is the secret. A Slack, Teams, Discord or Zapier
incoming webhook carries its token in the path or query, and Slack checks no
signature at all, so whoever holds the URL can post into the channel. #2793
added Slack-format endpoints for security alerts, which made this the normal
case rather than an edge case. Every admin of the site, every reader of an
export and everyone with log access could copy the credential.

The tempting fixes are narrower: mask only Slack-format endpoints, or mask the
page and leave exports and logs alone.

## Decision

**A webhook URL is a credential everywhere, for every format.** Any surface
that shows, exports or logs one shows `KilnCMS.Webhooks.display_url/1`, and
the full URL leaves the database only to be posted to, or on an admin's
explicit re-read.

- **One masking rule.** `display_url/1` keeps the scheme, host and a
  non-default port, then `/…/` and the last four characters of the path and
  query when those are at least 16 characters long, otherwise the host alone.
  Userinfo is always dropped; anything without a scheme and host is `••••`.
  It is idempotent, so a value masked twice is unchanged. It applies to every
  endpoint whatever its format, so no surface has to know which receivers
  embed a token.
- **Where it applies today.** The Webhooks list, the delivery history and the
  screen-reader labels of the secret buttons (`KilnCMSWeb.WebhookLive`); a
  document's governance trail and its JSON and CSV exports
  (`KilnCMS.Governance`, `KilnCMS.Webhooks.lost_retractions/3`); the
  `retraction_lost` notice and its log line
  (`KilnCMS.Webhooks.RetractionLost`). The JSON export carries `endpoint_id`
  beside the masked URL, because two endpoints on one host whose paths end
  alike mask to the same text; the CSV export has the masked URL only.
- **Reveal is a re-read.** **Reveal URL** reads the endpoint again as the
  admin, under the current site as tenant, so a demoted admin or an id from
  another site reveals nothing. The revealed URL lasts for that LiveView
  session.
- **The edit form never pre-fills.** It shows "Current URL" masked and an
  empty field; leaving it blank keeps the URL and is not a URL change, so it
  raises no `webhook_changed` notice
  ([ADR 0027](0027-security-alerts-derive-from-the-audit-log-and-turning-a-sites-alerts-down-is-never-silent.md)).
- **Kept out of `inspect`, changeset logs and errors.**
  `KilnCMS.CMS.WebhookEndpoint.url` and the ledger snapshot
  `KilnCMS.CMS.WebhookDelivery.endpoint_url` are `sensitive?: true`, and the
  URL validation (`lib/kiln_cms/cms/validations/webhook_url.ex`) reports no
  `value`.
- **Payloads say no more than they did.** The Kiln-format `"ping"` still
  carries `endpoint_url`: webhook payloads are additive-only under 1.x, and
  the receiver already holds its own URL. A Slack-format ping carries the
  site's name instead (`KilnCMS.Webhooks.ping/1`), because it is posted into
  a channel other people read. No security-alert payload carries a URL; a
  silencing notice names the endpoint by id.

The rule for a future surface: if it names a webhook endpoint to a person, a
file or a log, it calls `display_url/1` and, where two rows must be told
apart, carries `endpoint_id`.

## Rejected

- **Mask Slack-format endpoints only.** Teams, Discord, Zapier and many custom
  receivers on the Kiln format embed tokens too, and Kiln cannot tell which.
  A per-format rule is also one more thing each new surface has to get right.
- **Mask on the page but not in exports or logs.** Exports leave the
  installation and logs go to third-party aggregators; both outlive the
  session that produced them.
- **Pre-fill the edit form and mask it client-side.** The value would still be
  in the HTML sent to the browser.
- **Drop `endpoint_url` from the Kiln ping.** It would break a receiver that
  reads it, for a value the receiver already knows.
- **Stop keeping the URL in the delivery ledger.** The snapshot is what names
  an endpoint on the governance trail after the endpoint is deleted, and a
  redelivery copies it onto the new ledger row. Encrypting it at rest is the
  follow-up (#2794), not deleting it.

## Consequences

- At rest the URL is still plaintext: `webhook_endpoints.url` and
  `webhook_deliveries.endpoint_url`, and a Kiln-format ping's ledger payload.
  A database dump, backup or staging clone carries every URL, and
  `KilnCMS.Staging.Scrub` deactivates endpoints without replacing their URLs.
  #2794 tracks encrypting them and scrubbing them on clones.
- `retraction_lost` notifications written before #2793 still hold the full URL
  in their excerpt.
- Two endpoints on one host can look identical on the page; an admin tells
  them apart by Reveal or by their events, the JSON export by `endpoint_id`.
- A delivery is always posted to the endpoint's **current** URL
  (`KilnCMS.Webhooks.DeliveryWorker` reads the endpoint at send time); the
  ledger snapshot only names it.
- A failed delivery's `last_error` is one of Kiln's own messages
  (`endpoint returned HTTP 503`), a `KilnCMS.SafeFetch` refusal reason, which
  names no URL, or an inspected transport error (`Req.TransportError`,
  `Mint.TransportError`, which carry a reason and no URL). Webhook deliveries
  follow no redirects, so `SafeFetch`'s "blocked redirect from (url)" message
  cannot reach it.
