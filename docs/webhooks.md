# Webhooks

An operator guide to Kiln's outbound webhooks: signed HTTP push on content
lifecycle events, with SSRF-safe delivery, retry/backoff, and a delivery
ledger. Split out of [#53](https://github.com/The-Verscienta/kiln_cms/issues/53)
as [#570](https://github.com/The-Verscienta/kiln_cms/issues/570) — the feature
(`lib/kiln_cms/webhooks/`) had never had a guide of its own; see
[Automation](automation.md) for the complementary in-app reactions
(email/broadcast/cache/reindex) that don't need a receiver at all.

## Registering an endpoint

Admins manage endpoints at **`/editor/webhooks`**. Adding one takes a format, a
URL and a set of events to subscribe to; Kiln generates a signing secret at creation time.
The **Format** is **Kiln (signed JSON)**, the envelope described below, unless
you choose **Slack (incoming webhook)** for a channel that receives the site's
security alerts ([Slack-format endpoints](#slack-format-endpoints)). The format
is fixed once the endpoint is added: to change it, add a new endpoint.
After you add it, the list shows the endpoint's URL masked
([See or change an endpoint URL](#see-or-change-an-endpoint-url)).
It does not change when you edit the endpoint; an admin replaces it on purpose with
**Rotate secret** ([Rotate a webhook signing secret](#rotate-a-webhook-signing-secret)
below). Each row shows the secret masked
until an admin reveals it ([Copy a webhook signing secret](#copy-a-webhook-signing-secret)
below). The secret
is stored encrypted with the app's vault key, which is derived from
`SECRET_KEY_BASE`. Rotating that key leaves every endpoint's secret unreadable:
the row says so, and deliveries are refused rather than sent unsigned.
Rotate each endpoint's secret after that ([secrets rotation](secrets-rotation.md)). Toggling
**Active** or editing an endpoint gives it a clean slate: its failure count
resets (see [Auto-disable](#auto-disable) below).

Deleting an endpoint keeps its delivery history (see
[Delete an endpoint](#delete-an-endpoint) below).

The form starts with the default subscription ticked, the same list an
endpoint created over code or AshAdmin gets when it names no events: the
"Subscribed by default" rows of the table below, plus `form.submitted`. The
events that carry unpublished content are marked **includes unpublished
content** and start unticked. **Select all**, **Clear** and **Reset to
defaults** act on the whole list, and each group (one per content type, plus
tasks, releases, experiments, memberships, security, and the tag, tag group and category
taxonomy) has its own toggle. **Select all** leaves the `security.*` events
as they are: it ticks every other event, and keeps a security event only if
it was already ticked. Security alerts carry client addresses and user ids,
so an endpoint receives them only when someone ticks them in the `security`
group, whose own toggle ticks them all. An endpoint
that receives unpublished content says so on its row.

## Copy a webhook signing secret

Your receiver needs the endpoint's signing secret to
[verify each delivery](#verifying-the-signature). The list keeps it masked so
that it isn't on screen, or in the page, for anyone looking over your shoulder
or watching a screen share. You need the admin role; `/editor/webhooks` is
admin-only.

1. Open **Webhooks** (`/editor/webhooks`): in the sidebar under **Outbound**,
   or under **Configure** when the sidebar shows only the essentials. Each
   endpoint's row says **Signing secret:** followed by `••••` and the
   secret's last four characters, and a **Reveal** button. A secret shorter
   than 16 characters shows the dots alone, since its last four would give
   away too much of it.
2. Click **Reveal**. The full secret replaces the dots, with **Copy** and
   **Hide** buttons beside it.
3. Click **Copy**. The secret goes to your clipboard and the page says
   "Signing secret copied." Paste it into your receiver's configuration.
4. Click **Hide** to mask it again. Reloading the page or leaving it masks
   every secret too: a reveal lasts only while the page stays open.

A newly added endpoint skips step 2. After **Add webhook** the page says
"Webhook added. Copy its signing secret into your receiver." and the new row's
secret is already revealed, with **Copy** beside it.

The masked row carries only the last four characters. The full secret is sent
to the browser when you click **Reveal** (or add the endpoint), after the
server reads the endpoint again as you, on the current site.

What can go wrong:

- **"Couldn't reveal that signing secret."**: the endpoint was not found,
  usually because another admin deleted it after your page loaded. Reload the
  page to see the current list.
- **The row says the secret is "unreadable"** and has no **Reveal** or
  **Copy**: it was encrypted under a `SECRET_KEY_BASE` this server no longer
  has. Click **Rotate secret** and give the receiver the new secret
  ([Rotate a webhook signing secret](#rotate-a-webhook-signing-secret),
  [secrets rotation](secrets-rotation.md)).
- **Copy does nothing and no "copied" message appears**: the browser refused
  the clipboard write, which it does on a page not served over HTTPS (other
  than `localhost`) or when clipboard access is blocked. Select the revealed
  secret and copy it by hand.

## Rotate a webhook signing secret

Replace an endpoint's signing secret when it may have leaked, or when the row
says the secret is "unreadable". You need the admin role; `/editor/webhooks`
is admin-only, and so is the rotation. The URL, events and **Active** setting
stay as they are.

The old secret stops working at once. There is no window in which both are
accepted: rotation is the remedy for a leaked secret, and a grace period would
leave the leaked one valid. If your receiver can accept two secrets at a time,
do this in order:

1. Change the receiver to accept signatures made with either the old or the
   new secret. You have the old one; you get the new one in step 4. If the
   receiver can't do this, skip to step 3 and expect the gap described below.
2. Open **Webhooks** in the console navigation (`/editor/webhooks`) and find
   the endpoint's row.
3. Click **Rotate secret**. The browser asks: "Rotate this signing secret?
   Deliveries start using the new secret now, and the old one stops working,
   so update the receiver with the new secret." Click **OK**.
4. The page says "Signing secret replaced. Copy the new secret into your
   receiver; the old one no longer works." and the row's secret is already
   revealed, with **Copy** beside it and, under it, "Update your receiver
   now: deliveries already use this secret." Click **Copy** and put it in the
   receiver ([Copy a webhook signing secret](#copy-a-webhook-signing-secret)).
5. Once the receiver uses the new secret, remove the old one from it.
6. Click **Ping** on the row and check the receiver accepts it.

What to expect:

- **Deliveries sign at send time.** Queued deliveries and retries read the
  endpoint's secret when each attempt is sent, so everything sent after the
  click uses the new secret, whatever its age.
- **One in-flight attempt can fail.** An attempt already on the wire when you
  click was signed with the old secret. A receiver that has switched to the
  new one rejects it; Oban retries it, and the retry carries the new
  signature. A receiver that has not switched yet rejects every attempt made
  after the click until it does.
- **Failures count toward auto-disable.** Rotation leaves `consecutive_failures`
  and `auto_disabled_at` as they are. An endpoint near the limit of 10 can be
  auto-disabled by deliveries that exhaust their retries while the receiver
  still holds the old secret ([Auto-disable](#auto-disable)). Update the
  receiver promptly, and check the row afterwards. Rotating does not
  re-enable an auto-disabled endpoint; tick **Active** for that.
- **An unreadable secret can be rotated.** Kiln never opens the old value, so
  an endpoint whose secret was encrypted under a lost `SECRET_KEY_BASE` gets a
  working one, and the receiver then needs it ([secrets rotation](secrets-rotation.md)).
- **The record is a log line.** Each rotation logs at info level
  `webhook secret rotated endpoint_id=… org_id=… actor_id=…`, never the
  secret. There is no other audit trail.

What can go wrong:

- **"Couldn't rotate that signing secret."**: the endpoint was not found
  (another admin deleted it after your page loaded) or the rotation was
  refused. Reload the page to see the current list.
- **No Rotate secret button**: your role can't rotate secrets. Ask an admin.
- **The receiver answers 4xx after the rotation**: it still holds the old
  secret. Reveal the new one and update the receiver; failed deliveries retry
  on their own and can be redelivered ([Ping and redeliver](#ping-and-redeliver)).

## See or change an endpoint URL

An endpoint's URL can be a credential. A Slack, Teams, Discord or Zapier
incoming-webhook URL carries its own token, and anyone holding it can post to
the channel. So Kiln shows every endpoint's URL masked, whatever its format,
and sends the full URL to the browser only when an admin asks for it. You
need the admin role; `/editor/webhooks` is admin-only.

1. Open **Webhooks** (`/editor/webhooks`). Each row shows its URL masked: the
   scheme and host, then `/…/` and the last four characters of the path and
   query, such as `https://hooks.slack.com/…/9xQz`. When the path and query
   are shorter than 16 characters, only the scheme and host are shown
   (`https://example.com`). A user name and password in the URL are never
   shown, nor is the scheme's default port.
2. Click **Reveal URL** beside it. Kiln reads the endpoint again as you, on
   the current site, and the full URL replaces the masked one, with a
   **Hide URL** button. It stays revealed until you click **Hide URL** or
   leave or reload the page.
3. To change the URL, click **Edit** on the row. The form shows the
   endpoint's **Format** (read-only), an empty **Endpoint URL** field with the
   hint "Leave blank to keep the current URL.", and under it **Current URL:**
   followed by the masked URL and its own **Reveal URL** button.
4. Type the new URL and click **Save**, or leave the field empty to keep the
   URL as it is and change only **Active** or the events. The page says
   "Saved."

Leaving the field empty does not count as a URL change, so saving an endpoint
subscribed to security alerts without typing a URL sends no
[silencing notice](security-alerts.md#silencing-notices) for its URL.

The same masked form names an endpoint everywhere else it appears: the
**Recent deliveries** table, the labels of the signing-secret buttons read by
screen readers, a document's governance trail and its JSON and CSV exports,
the "Retraction not delivered" notice, and the application log. The database
and the delivery ledger keep the real URL, and a redelivery is sent to it.

What can go wrong:

- **"Couldn't reveal that URL."**: the endpoint was not found (another admin
  deleted it after your page loaded) or you are no longer an admin of the
  site. Reload the page.
- **Two rows look the same.** Two endpoints on one host whose paths end alike
  mask to the same text. Reveal both, or tell them apart by their events.
  The governance exports carry each endpoint's `endpoint_id` for this.

## Slack-format endpoints

A Slack-format endpoint posts the site's [security alerts](security-alerts.md)
into a chat channel as a message, instead of Kiln's signed JSON envelope. It
works with a Slack incoming webhook and with receivers that accept the same
body: Mattermost, Rocket.Chat, and Discord's `/slack` URL. The step-by-step
setup is in [Send alerts to Slack](security-alerts.md#send-alerts-to-slack).

- **Security events only.** Its events must all start with `security.`. A
  Slack endpoint is never sent a content event, a retraction, a form
  submission or a taxonomy event: content carries document bodies that have
  no sensible chat rendering. Adding or saving one with another event ticked
  is refused with "Slack endpoints can only receive security events". An
  endpoint added with no events gets every security event.
- **The body.** A JSON object with `text` (the whole message on one line,
  ending with the link to the console as a bare URL, for receivers that ignore
  `blocks`), `blocks` (a section with the headline, the site and when, and a
  context line with a link to the security log and the event name) and
  `"unfurl_links": false, "unfurl_media": false`. The wording is the same
  English headline as the alert email. The site name, the IP address and the
  event name are put in code spans, with backticks replaced and line breaks
  collapsed, and `&`, `<` and `>` are escaped, so nothing typed into a site
  name can mention `@channel`, add a link or format the message. It carries no
  user id, delivery id or endpoint id.
- **Ping** posts "KilnCMS webhook test for `Site`" and never the endpoint's URL.
- **Signed, but nobody checks.** The `x-kilncms-webhook-signature`,
  `x-kilncms-event` and `x-kilncms-delivery-id` headers are still sent, and
  the signature covers the body actually sent, so a relay in front of the
  channel can verify it. Slack itself checks no signature: **the URL is the
  credential**. That is why the row shows no signing secret and no **Rotate
  secret** button, and why the URL is masked. If the URL leaks, regenerate it
  in Slack, then delete the endpoint and add the new URL.
- **Failures are ordinary.** Slack answers `400 invalid_payload`, `403`,
  `404 channel_not_found` or `410 channel_is_archived` when it can't post;
  those are retried and count toward [auto-disable](#auto-disable) like any
  non-2xx answer.
- **An event it has no message for**, such as a content event an older node
  queued for it during a rolling deploy, is posted as one neutral line naming
  the event, with nothing from its payload.
- **A format this release doesn't know** (an endpoint added by a newer release,
  met after a rollback) is not sent at all: the delivery fails with
  `delivery failed: endpoint format not supported by this release`.

## Delete an endpoint

You need the admin role; `/editor/webhooks` is admin-only, and so is the
delete itself. An endpoint can be deleted whether it is active, disabled or
auto-disabled: there is no need to disable it first.

1. Open **Webhooks** in the console navigation (`/editor/webhooks`). Each
   endpoint's row ends with **Ping**, **Disable** (or **Enable**), **Edit**,
   **Rotate secret** and a red **Delete**.
2. Click **Delete** on the endpoint's row. If you already have the endpoint
   open under **Edit**, the form's **Delete webhook** button, to the right of
   **Save** and **Cancel**, does the same.
3. The browser asks: "Delete this webhook? Queued deliveries, including
   retractions, won't be sent. Delivery history is kept." Click **OK**.
4. The page says "Webhook deleted." and the endpoint's row is gone.

What deleting does:

- **Nothing more is sent to the URL.** A delivery already queued or waiting
  to retry settles as `failed` with the error `endpoint deleted` on its next
  attempt, instead of being sent. That includes retractions
  (`unpublished`, `archived`, `deleted`), which disabling an endpoint does not
  stop ([Retractions are exempt](#retractions-are-exempt)).
- **The history stays.** Past deliveries keep their ledger rows under the
  usual [retention](#delivery-history). In **Recent deliveries** each row
  still shows the URL it was sent to, masked, followed by "(deleted endpoint)", and
  has no **Redeliver** button: there is no endpoint to send it to, and the
  signing secret went with it. A failed retraction in a document's
  **Retractions not delivered** panel on the governance trail is shown the
  same way.
- **It can't be undone.** The signing secret goes with the endpoint. To
  deliver to the same URL again, add it as a new endpoint and give the
  receiver its new secret.

What can go wrong:

- **"Couldn't delete that webhook."**: the endpoint was not found (another
  admin deleted it first, or the page was stale) or the delete was refused.
  Reload the page to see the current list.
- **"That delivery's endpoint was deleted, so it can't be redelivered."**
  after clicking **Redeliver**: the endpoint was deleted after your page
  loaded (by another admin, or in another tab). Nothing is sent, and the row
  updates to "(deleted endpoint)" without the button. A deleted endpoint's
  deliveries can't be replayed; to reach the same receiver again, add its URL
  as a new endpoint and give the receiver the new secret. Events from then on
  go there.

## Event names & payload

An event name is `<type>.<verb>`. Every registered content type — built-in and
admin-defined dynamic types alike (D17) — gets one event per lifecycle verb it
can emit, so a new content type has webhook events for free:

| Verb | Fires when | Subscribed by default? |
| --- | --- | --- |
| `published` | A document goes live | Yes |
| `unpublished` | A live document is taken down | Yes |
| `updated` | A **published** document is edited (draft edits/autosaves stay silent), or re-rendered without an edit (see below) | Yes |
| `in_review` | A document is submitted for review ([#375](https://github.com/The-Verscienta/kiln_cms/issues/375)) | **No — opt in** |
| `returned_to_draft` | A review is sent back to draft | **No — opt in** |
| `created` | A document is created (API, editor, or import) | **No — opt in** |
| `archived` | A document is archived, from any state | Yes |
| `deleted` | A document is moved to the trash (`DELETE` over the API is this too) | Yes |
| `restored` | A document comes back from the trash, or is unarchived to draft | Yes |

A mirror needs `archived`, `deleted` and `restored`, or it keeps serving
documents the site no longer has. They are on by default for that reason, and
they are safe defaults because of what they carry (see the payload
shapes below): `archived` and `deleted` send a
**tombstone**, the document's identity and nothing else, since they fire for
drafts as readily as for live documents. `restored` sends the full body only
when the document is published again (it is back on the delivery path and a
mirror must re-ingest it); otherwise it sends the tombstone too.

The trash is a soft delete. A hard purge from the trash, or the nightly
auto-purge, sends nothing more: the receiver already heard `deleted`.

After `deleted`, a document sends nothing until `restored` (#2332). An editor,
API client or job that loaded it before the trash can no longer write to it,
so no `updated`, `unpublished` or `archived` follows a `deleted`. Trashing it
twice sends one `deleted`, and restoring it twice sends one `restored`. When a
purge clears the purged document out of another document's reference field,
a referrer that is itself in the trash is cleared silently; a live referrer
still sends `updated`.

`updated` also fires when a published document's fired artifacts are
re-rendered without an edit, so what delivery serves may have changed while
`updated_at` did not: an overlay's `KilnCMS.Firing.refire/3`
([#2048](https://github.com/The-Verscienta/kiln_cms/issues/2048)), and an
operator's re-fire sweep run with `notify: true` after an upgrade
([Re-render published content after an upgrade](releasing.md#re-render-published-content-after-an-upgrade)).
Those payloads carry `"reason": "refire"` in `data`; an edit's carries no
`reason` key ([#2463](https://github.com/The-Verscienta/kiln_cms/issues/2463)).
Treat a re-fire like an edit: refetch the document. Don't drop it as a
duplicate because its `updated_at` matches what you hold. A sweep's
`updated` reaches webhook endpoints and the public change feed only, not
automation, federation or the CDN purge, and the change feed's event does not
say it was a re-fire.

`unpublished` fires for both an explicit unpublish **and** archiving a
published document (#914) — both remove it from delivery, and a receiver
watching for content leaving delivery should not have to subscribe to two
events to hear about it. The payload's `data.state` reflects which happened:
`"draft"` for an unpublish, `"archived"` for an archive.

`in_review`, `returned_to_draft` and `created` are opt-in only. Their payload is
the full serialized body of a document that has **never been published**, and a
receiver built for publish-mirroring must not be sent draft or embargoed content
it didn't ask for. `created` fires for every create path, bulk
[import](content-portability.md) included, so expect one per imported record.

More event names exist outside the `<type>.<verb>` pattern:

- **`form.submitted`** — a public form submission ([Forms](forms.md)); every
  endpoint is subscribed by default.
- **`membership.activated`** / **`membership.canceled`** — a paid membership
  started or stopped granting access ([Paid memberships](memberships.md#webhook-events));
  opt in.
- **`task.assigned`** / **`task.overdue`**, **`release.published`** /
  **`release.rolled_back`** / **`release.failed`**, and
  **`experiment.concluded`** — editorial tasks, content releases and A/B
  experiments; opt in.
- **`tag.created`** / **`tag.updated`** / **`tag.deleted`**, the same three for
  **`tag_group`**, and the same three for **`category`** — taxonomy changes
  ([#1965](https://github.com/The-Verscienta/kiln_cms/issues/1965)); opt in. A
  receiver that caches taxonomy (a tag cloud, a list of payers kept as a tag
  group) can invalidate on them instead of polling. See
  [Taxonomy events](#taxonomy-events) below.
- **`security.new_admin`**, **`security.role_elevation`**,
  **`security.failed_sign_ins`**, **`security.lockout`**,
  **`security.two_factor_disabled`**, **`security.sso_config_changed`** and
  **`security.alerts_silenced`** — the site's
  [security alerts](security-alerts.md) and the notice that someone turned
  them down ([#2245](https://github.com/The-Verscienta/kiln_cms/issues/2245));
  opt in. See [Security alert events](#security-alert-events) below.
- **`ping`** — a manual test delivery (see [Ping](#ping-and-redeliver) below);
  never subscribed to, and delivered on demand regardless of an endpoint's
  active state or event list.

Each of these namespaces (`form`, `membership`, `task`, `release`,
`experiment`, `tag`, `tag_group`, `category`, `security`) is reserved: a new content type
cannot take one as its name, so `release.published` always means a release
and never a document of a type called `release`
([#1994](https://github.com/The-Verscienta/kiln_cms/issues/1994)). A type
created with one of these names before the rule keeps working and can still be
edited, but its events still share names with the built-in ones.

The request body is always
`{"event": "<name>", "delivery_id": "<uuid>", "data": {...}}`. `delivery_id` is
the ledger row's id: the same on every retry of one delivery, and new for a
redelivery. It is inside the signed body, so a receiver can trust it as a
dedupe key. `data` shape depends on the event:

- **Tombstones** (`archived`, `deleted`, and `restored` for a document that is
  not published) — `{"id", "slug", "locale", "state", "updated_at"}`. `state`
  is the document's workflow state: `"archived"` after an archive, and the state
  it was trashed in for `deleted` (`"published"` tells you it was live).
- **Other content lifecycle events** (`published`/`unpublished`/`updated`/
  `in_review`/`returned_to_draft`/`created`, and `restored` for a published
  document) — the document's public fields (`id`, `title`, `slug`,
  `excerpt`, `blocks`, `seo_*`, `canonical_url`, `locale`, `state`, `audience`,
  `locked`, `published_at`, `scheduled_at`, `inserted_at`, `updated_at`); each block
  trimmed to `type`, `content`, `data`, `order`, `children`. Internal-only
  fields (e.g. search text) are never included. These payloads also carry
  **`affected`**: the published documents whose fired artifacts embed this
  one, each as `{"type", "id", "slug", "locale"}` (see below). An `updated`
  sent for a re-render rather than an edit also carries `"reason": "refire"`
  (above).
- **`form.submitted`** — `{"form": "<slug>", "data": {...submitted fields...}}`.
  A value is a string, number, boolean or, for a `checkboxes` field, a list of
  strings (see [Forms](forms.md#field-types)); don't assume every value is a string.
- **`membership.activated`** / **`membership.canceled`** — the member (`user_id`,
  `email`), the tier (`id`, `slug`, `name`, `audience`), the transition
  (`status`, `previous_status`, `occurred_at`) and `event_id` to dedupe on; see
  [Paid memberships](memberships.md#webhook-events).
- **Taxonomy events** (`tag.*`, `tag_group.*`, `category.*`) —
  `{"id", "slug", "name", "updated_at"}`, plus `tag_group_id` for a tag. An
  `updated` adds `previous_slug` when the slug changed and, for a tag,
  `previous_tag_group_id` when it moved group. A `deleted` is the record as it
  was. See [Taxonomy events](#taxonomy-events).
- **Security alert events** (`security.*`) — the alert, its window's summary
  or a silencing notice, told apart by `phase`. See
  [Security alert events](#security-alert-events).
- **`ping`** — `{"message": "KilnCMS webhook test", "endpoint_url": "...", "sent_at": "<ISO 8601>"}`.
  `endpoint_url` is the endpoint's full URL. A
  [Slack-format endpoint](#slack-format-endpoints) is not sent this envelope:
  its ping is a chat message naming the site, without the URL.

```jsonc
// POST to your endpoint, page.published
{
  "event": "page.published",
  "delivery_id": "0b9c…",
  "data": {
    "id": "…", "title": "Launch", "slug": "launch", "state": "published",
    "audience": "public", "locked": false,
    "blocks": [{ "type": "paragraph", "content": "…", "data": {}, "order": 0, "children": [] }],
    "published_at": "2026-08-04T12:00:00Z", "…": "…",
    "affected": [{ "type": "page", "id": "…", "slug": "about", "locale": "en" }]
  }
}
```

### Taxonomy events

Creating, editing or deleting a tag, tag group or category sends one event,
after the write commits, to the endpoints of that site that selected it. None
is subscribed by default, so an endpoint created before these events existed
receives none of them until an admin ticks them.

```jsonc
// tag.updated: renamed, re-slugged and moved to another group
{
  "event": "tag.updated",
  "delivery_id": "…",
  "data": {
    "id": "…", "slug": "payer-acme-health", "name": "Acme Health",
    "tag_group_id": "…", "updated_at": "2026-10-15T12:00:00Z",
    "previous_slug": "payer-acme", "previous_tag_group_id": "…"
  }
}
```

- **`previous_slug` / `previous_tag_group_id`** are present only when that
  field changed. They come from the record the editor was working on, so treat
  them as a hint: if two people edited the same tag at once, one of them may
  report a value that was already out of date. `id` is what to key on.
- **`updated` fires on every save**, including one that changes only a tag
  group's position. Use `updated_at` to drop a retry that arrives after a
  later event. A `deleted` carries the `updated_at` of the last edit, so it can
  tie with the `updated` before it: on a tie, `deleted` wins.
- **Deletes cascade without further events.** Deleting a tag removes it from
  every document, media item and entry that carried it, and those records get
  no `updated` event. Deleting a tag group leaves its tags ungrouped, and those
  tags get no `tag.updated`. On `tag.deleted`, drop the tag's `id` from
  anything you cached; on `tag_group.deleted`, treat the group's tags as
  ungrouped. Deleting a category leaves its documents with no category, with
  no event for them either.
- **A taxonomy delete is not a retraction.** It is delivered and retried like
  any other event (see [Retractions are exempt](#retractions-are-exempt), which
  covers documents only), and it counts toward auto-disable.
- Taxonomy events do not run [automation](automation.md) rules or federate.
  They do trigger the optional CDN purge, because the cached taxonomy lists
  and every cached document carrying the term change.
- A content type cannot be named `tag`, `tag_group` or `category`, so these
  names always mean taxonomy. The same goes for every other namespace above
  (`form`, `membership`, `task`, `release`, `experiment`).

### Security alert events

A site's [security alerts](security-alerts.md) can be sent to its endpoints:
one event per site alert kind, `security.<kind>`, and
`security.alerts_silenced` for the notice that someone turned the alerts down
(an alert kind or admin notifications switched off, a security webhook
changed, deleted, re-keyed or auto-disabled, an admin removed or demoted, the
site's mail relay changed).

- **Opt in.** None is in the defaults, so an endpoint receives none until an
  admin ticks them in the `security` group of its event list. The list's
  **Select all** does not tick them; the `security` group's own toggle does.
- **To a chat channel.** A [Slack-format endpoint](#slack-format-endpoints)
  receives these events as a chat message instead of this JSON envelope.
- **When.** Within about a minute of the event. Alerts are grouped per kind
  into 15-minute windows: the first event of a window is sent as an alert
  (`"phase": "alert"`), and when more followed, one summary
  (`"phase": "summary"`, with the window's `count`) about a minute after the
  window closes. Notices are never grouped.
- **What the site's settings change.** A kind the site turned off is sent to
  nobody, webhooks included. Switching off the admins' bell and email leaves
  webhooks on.
- **What it carries.** The site, the window, and for an alert the security log
  event that raised it (id, type, actor and target ids, metadata), with its IP
  address cut to the network (`/24`, `/48`) unless the site shows full
  addresses. Never an email address, user agent, secret or endpoint URL. The
  full shape and examples are in
  [Security alerts → Payload](security-alerts.md#payload).
- **Platform alerts** (new platform admins, platform role changes, new API
  keys, a stolen API key used again) are not webhook events in this release;
  they go to the platform admins by bell and email only.
- **Sent only to the endpoint.** A security event is not a content change:
  it does not run [automation](automation.md) rules, federate, purge the CDN
  or appear in the change feed. It is otherwise an ordinary delivery: on the
  ledger, retried, redeliverable, and counted toward auto-disable.
- **Changing a subscribed endpoint is announced.** Editing the URL of an
  endpoint subscribed to any `security.*` event, unticking **Active** or one
  of its `security.*` events, rotating its secret, deleting it, or its being
  auto-disabled sends `security.alerts_silenced` to the site's admins (and to
  every endpoint of the site subscribed to it). Subscribing to more events
  does not.

### `affected`: the other pages this change touched

A document that embeds another (a formula page listing a herb, a page with a
reference block, a fragment's users) re-fires when its target changes, so its
delivered artifact changes too. A consumer that caches per page used to learn
only about the document in the event, and the pages built on it waited out
their TTL. `data.affected` lists those referrers, so a receiver can
invalidate or refetch them in the same breath (#1925):

- Each entry is `{"type", "id", "slug", "locale"}`, with `type` the public
  type name exactly as event names use it (`"recipe"`, not `"entry"`).
- Only referrers that are **currently published** are listed: the list is
  for invalidating pages a consumer serves, and a referrer that has since
  been unpublished or trashed has no page to invalidate.
- It is the firing dependency graph as it stands at the moment of the
  event, the same edges Kiln's own re-fire wave walks. Edges are written
  when a referrer fires (on publish), so a draft that has never been
  published is never listed.
- Present on every full payload, including `unpublished`, where it names the
  pages that embedded the retracted document. Tombstones stay identity only.
- An empty list means nothing embeds the document, never that the lookup
  was skipped; a failed lookup is logged and answers `[]` rather than cost
  the delivery.

### Gated content is delivered too — check `audience`

A webhook fires for an **audience-gated** document exactly as it does for a
public one, and the payload carries the full block tree. That is deliberate: an
endpoint is somewhere you chose to send content, the request is HMAC-signed and
the URL is SSRF-guarded, so this is not the anonymously-queryable surface the
Meilisearch index is (which *does* exclude gated content, [#1006](https://github.com/The-Verscienta/kiln_cms/issues/1006)).

But it means **your receiver decides**, and the payload carries both halves of
the decision Kiln makes for its own surfaces:

| Field | Value when open | Filter if your sink is public |
| --- | --- | --- |
| `audience` | `"public"` | anything else (`"member"`, or whatever your deployment configures) is content a reader was supposed to pay for or be granted |
| `locked` | `false` | `true` means a shared passphrase stands between the reader and this body ([#496](https://github.com/The-Verscienta/kiln_cms/issues/496)) |

Both, not either. Kiln's own rule is three-part — published **and** `public`
**and** unlocked — so a receiver checking only `audience` mirrors a document
that was published openly and locked afterwards, which still arrives as
`"audience": "public"`. `locked` is derived; the hash and the
`password_fingerprint` never leave.

**A narrowing `updated` event is a retraction.** Gating or locking a live
document fires `<type>.updated` with the new values, so a receiver that filters
only at ingest keeps serving the body it already mirrored. Treat an `updated`
whose `audience` moved away from `"public"`, or whose `locked` became `true`, as
an instruction to withdraw it.

## Verifying the signature

Every request carries these headers:

| Header | Value |
| --- | --- |
| `x-kilncms-webhook-signature` | `t=<unix seconds>,v1=<hex>` where `v1` is the lowercase hex HMAC-SHA256 of `"<t>.<raw body>"`, keyed by the endpoint's secret |
| `x-kilncms-delivery-id` | The delivery's id, the same value as the body's `delivery_id`. Stable across retries |
| `x-kilncms-event` | The event name (redundant with the body's `event` field, for routing without a parse) |

To verify a delivery:

1. Split the header on `,` into `t` and one or more `v1` values.
2. Reject it if `t` is more than **300 seconds** (five minutes) from your own
   clock, in either direction. This is what stops a captured request from
   being replayed later. Kiln signs each attempt when it sends it, so a retry
   carries a fresh `t`. Keep your clock NTP-synced.
3. Compute the HMAC of the string `t`, then `.`, then the **raw request body**,
   using the exact bytes you received. Do not re-serialize the parsed JSON: key
   order and whitespace aren't guaranteed to round-trip.
4. Accept if any `v1` matches, compared in constant time.
5. Optionally, remember each `delivery_id` for the length of your window and
   drop a repeat. That makes delivery exactly-once inside the window as well
   as outside it.

The official clients do all of this: `verifyWebhook` in the
[JS client](https://github.com/The-Verscienta/kiln_cms/blob/main/clients/js/README.md) and `KilnClient.Webhook.verify/4` in the
[Elixir client](https://github.com/The-Verscienta/kiln_cms/blob/main/clients/elixir/kiln_client/README.md). By hand:

```js
// Node
const crypto = require("crypto");
function verify(secret, rawBody, header, toleranceSeconds = 300) {
  const pairs = header.split(",").map((p) => p.trim().split(/=(.*)/s));
  const ts = pairs.filter(([k]) => k === "t").map(([, v]) => v);
  if (ts.length !== 1 || !/^\d+$/.test(ts[0])) return false;
  if (Math.abs(Date.now() / 1000 - Number(ts[0])) > toleranceSeconds) return false;
  const expected = Buffer.from(
    crypto.createHmac("sha256", secret).update(`${ts[0]}.`).update(rawBody).digest("hex"),
  );
  return pairs.some(([k, v]) => {
    if (k !== "v1") return false;
    const given = Buffer.from(v);
    return given.length === expected.length && crypto.timingSafeEqual(given, expected);
  });
}
```

```python
# Python
import hmac, hashlib, time

def verify(secret: str, raw_body: bytes, header: str, tolerance: int = 300) -> bool:
    pairs = [p.split("=", 1) for p in header.split(",") if "=" in p]
    ts = [v for k, v in pairs if k == "t"]
    if len(ts) != 1 or not ts[0].isdigit() or abs(time.time() - int(ts[0])) > tolerance:
        return False
    expected = hmac.new(secret.encode(), ts[0].encode() + b"." + raw_body, hashlib.sha256).hexdigest()
    return any(hmac.compare_digest(expected, v) for k, v in pairs if k == "v1")
```

**The removed `x-kilncms-signature`.** Releases 0.10 and 0.11 also sent a
body-only `x-kilncms-signature`: the hex HMAC of the body alone. It proved a
delivery came from Kiln unmodified, but not when it was sent, so a captured
request could be replayed indefinitely to a receiver that checked only that
header. It was deprecated in 0.10.0 and is no longer sent from 0.12.0 (#1616).
A receiver still reading it sees the header missing on every delivery; switch
it to `x-kilncms-webhook-signature` as above.

An admin **redelivery** is a new delivery: a new `delivery_id` and a fresh `t`.
It is meant to be accepted.

## Egress protections (SSRF)

Endpoint URLs are validated on every create/edit, and re-resolved (not just
re-checked) on every delivery attempt, by `KilnCMS.Webhooks.SafeUrl`:

- **Blocked hosts**: `localhost`, `metadata.google.internal`, `metadata.goog`,
  and any `.local` / `.internal` hostname.
- **Blocked addresses**: loopback (`127.0.0.0/8`, `::1`), unspecified
  (`0.0.0.0`, `::`), link-local (`169.254.0.0/16`, `fe80::/10`), private
  ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `fc00::/7` ULA),
  carrier-grade NAT (`100.64.0.0/10`), and the broadcast address — checked
  against IPv4-mapped/-compatible IPv6 addresses too, so `::ffff:10.0.0.1`
  doesn't slip through.
- **DNS resolution is checked, then pinned.** A hostname is resolved once
  before delivery, every answer is checked against the same blocklist, and the
  HTTP client connects to *that* resolved address (not the hostname) with the
  original `Host` header and TLS SNI restored separately. Re-resolving at
  connect time would reopen a DNS-rebinding window — an attacker's DNS could
  answer safely during validation and privately at connect time — so the
  pinned address is what the request actually dials. Resolution has a 3-second
  timeout so a stalled/firewalled name can't hang a delivery worker.
- **Redirects are not followed.** A 3xx response is treated as the delivery
  outcome (and retried like any other non-2xx), not a new destination — an
  endpoint can't hop to a blocked address after passing validation.
- **HTTPS is required in production** (`require_https: true`); HTTP is
  accepted in dev/test.

## Delivery, retries, and failure handling

A publish/unpublish/update/form-submit enqueues one Oban job per active,
subscribed endpoint, plus one ledger row (`WebhookDelivery`) per job — the row
is updated on every attempt, not just the outcome. The row's id is the
`delivery_id` the receiver sees.

- Delivery is a `POST` with a 5-second connect timeout and a 15-second
  response timeout.
- A non-2xx response or a transport error fails the job, and Oban retries with
  exponential backoff up to **5 attempts**. Retractions get a longer schedule
  (see [Retractions are exempt](#retractions-are-exempt)).
- Once retries are exhausted, the delivery is marked `:failed` — permanently;
  nothing retries it further unless an admin redelivers it.
- A delivery whose endpoint secret can no longer be decrypted (see
  [Registering an endpoint](#registering-an-endpoint)) fails with
  `delivery failed: signing secret unreadable` and is never sent.

### Auto-disable

Every exhausted delivery counts against the endpoint's `consecutive_failures`.
After **10** exhausted deliveries in a row, the endpoint is auto-disabled
(`auto_disabled_at` stamped, shown in the UI) and stops receiving new
deliveries — a dead receiver doesn't burn the delivery queue forever. Any
successful delivery to an active endpoint, or any admin edit, resets the
counter to zero. `auto_disabled_at` is cleared only when the endpoint is
active again: a ping or a retraction that gets through to an auto-disabled
endpoint leaves it auto-disabled, and so does an edit that leaves **Active**
unticked (fixing the URL before you ping it, say). Tick **Active** to turn it
back on. To stop an auto-disabled endpoint receiving retractions, delete it.

### Retractions are exempt

Three verbs take a document *off* a consumer: `<type>.unpublished`,
`<type>.archived` and `<type>.deleted`. When the document was published
before the action, a consumer that misses one keeps serving something the
site has withdrawn, so these are exempt from auto-disable. (`archived` and
`deleted` also fire for drafts. A draft was never delivered, so its tombstone
is an ordinary delivery.)

- **They still go to an auto-disabled endpoint.** An endpoint that has been
  failing `updated` deliveries for an hour and was switched off by the
  pipeline still receives the `unpublished` that follows. An endpoint an
  admin switched off (unticked **Active**) receives nothing; that was a
  decision, not a fault.
- **They retry longer**: **30 attempts**, starting 30 seconds apart and
  doubling up to one hour apart, which comes to about a day. An endpoint that
  has been auto-disabled for more than **7 days**
  (`retraction_stale_after_days`) gets one attempt, so a long-dead receiver
  cannot hold the queue for a day per retraction.
- **They never count against `consecutive_failures`.** A failing retraction
  cannot be what disables an endpoint, and one that gets through to an
  auto-disabled endpoint does not re-enable it.
- **When one exhausts its retries, an editor is told:**
  - every admin of the site gets a **"Retraction not delivered"** notice in
    the console bell and `/editor/inbox`. It names the document, the endpoint
    and the last error. It cannot be muted. It is not sent for an endpoint
    past the 7-day stale window, whose losses were announced while it was
    fresh; those still show on the trail.
  - the document's governance trail (`/editor/governance/:type/:id`, which
    the notice links to) shows a **Retractions not delivered** panel. The
    panel lists each failed delivery with its endpoint, attempt count and
    error. Once any later `unpublished`, `archived` or `deleted` of the same
    document reaches the same endpoint (a redelivery, or a later verb), the
    row shows when. A trashed document still has a trail for this reason.
    The JSON and CSV trail exports carry the same rows.
  - a failed retraction is **kept past the 30-day ledger retention**, and
    through the deletion of its endpoint, so the trail does not lose it.
    Past the retention window its payload is cut down to the tombstone's
    identity fields (`id`, `slug`, `locale`, `state`, `updated_at`), so a
    withdrawn body is not kept indefinitely; a redelivery after that sends
    the identity only.

Fix the receiver, then press **Redeliver** on the row in the trail's panel.
A row whose endpoint has since been deleted keeps its URL (shown masked), marked
"(deleted endpoint)", and has no **Redeliver** button
([Delete an endpoint](#delete-an-endpoint)).
`/editor/webhooks` lists only the 25 newest deliveries, and a retraction is
given up on about a day after it was sent.

### Ping and redeliver

- **Ping** sends a one-off `"ping"` test event to a single endpoint — it
  delivers even while the endpoint is inactive or auto-disabled, so you can
  verify a receiver before flipping it on (or diagnose one that's already
  off).
- **Redeliver** replays a recorded delivery — same endpoint, event, and
  payload — as a **new** ledger row. History is immutable; a redelivery never
  overwrites the original failed attempt. A delivery whose endpoint was
  deleted can't be redelivered and shows no button
  ([Delete an endpoint](#delete-an-endpoint)).

## Delivery history

`/editor/webhooks` shows the 25 most recent deliveries across all of an
org's endpoints: timestamp, event, target endpoint (its URL masked), status
(delivered/retrying/failed), attempt count, last HTTP status, and last error.
Delivery rows are retained for **30 days**, then pruned by a nightly job (per
org, so one site's retention sweep never touches another's history). A failed
retraction is the exception: it is kept, because it is on the document's
governance trail.

Each row is one delivery to one endpoint, and `delivered_at` is when that
endpoint answered 2xx. For an `unpublished`, the latest `delivered_at` across
the endpoints is when the last consumer heard about the withdrawal.

## Configuration

```elixir
# Days an endpoint may sit auto-disabled before a retraction to it gets one
# attempt and no console notice (default 7)
config :kiln_cms, KilnCMS.Webhooks, retraction_stale_after_days: 7

# Exhausted deliveries in a row before auto-disable (default 10)
config :kiln_cms, KilnCMS.Webhooks, auto_disable_after: 10

# Delivery ledger retention, in days (default 30)
config :kiln_cms, :webhooks, delivery_retention_days: 30

# SSRF guard (see config/prod.exs for the production defaults)
config :kiln_cms, KilnCMS.Webhooks.SafeUrl,
  require_https: true,
  resolve_dns: true
```

## Multi-tenancy

Endpoints and deliveries belong to one organization ([epic #336](https://github.com/The-Verscienta/kiln_cms/issues/336)): a publish only fans out to
its own site's subscribed endpoints, and the admin panel only ever shows the
current org's endpoints and history.
