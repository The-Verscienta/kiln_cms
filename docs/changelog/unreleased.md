# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="reserved-route-slugs-upgrade"></a>

- **List the records a newly reserved route already shadowed (#2898).** Run `mix kiln.reserved_paths`, or in a release `bin/kiln_cms eval 'KilnCMS.Release.reserved_paths()'`. It lists every page whose slug, and every record whose path alias starts with, one of `developers`, `ready`, `setup`, `sign-in`, `sign-out`, `actor`, `ap`, `mcp`, `password-reset`, or the first segment of an installed plugin's public route. Those URLs were never served: the built-in route answered first. Nothing is renamed for you; give each a new slug or alias in the editor, and add a redirect if the old URL was ever linked. The records still read and save as before; only a change to the slug or alias is checked. No migration; the command is read-only.

## Breaking

<a id="breached-password-strictest-admin-sites"></a>

- **A password is held to the strictest breached-password policy of every site its account administers (#2408).** Until now the policy came from the site the request came in on alone: an admin of site A, whose policy is **Block**, could change or reset their password on site B's host, where the policy is **Warn** or **Off**, and set a breached one. That closed the threat model's residual risk (2).
  - **What changes.** When an existing account's password is set (change password, reset by token, an existing account accepting an invitation with a password), the policy is the strictest of the request site's policy for the account's tier there and the policy of every site the account administers, ordered Off, then Warn, then Block. An administered site with no saved policy brings in the operator's default (`BREACHED_PASSWORD_POLICY`, `warn` if unset). "Administers" means an active membership that is admin there, a live temporary admin grant included; a platform admin administers every site; an erased account administers none. A site's own policy is still downgraded to Warn for an account that is not its admin, but an administered site's never is.
  - **Why under Breaking.** A site's **Off** used to mean that nothing about a password set on that site was sent to Have I Been Pwned while the setting could be read. That no longer holds for someone who also administers a site that checks: their password is looked up, and can be refused, on every host. The Password policy page says so under **Off**. `BREACHED_PASSWORD_CHECK=false` is still the only switch that guarantees no request.
  - **Unchanged.** A registration, the first-run setup and an invitation that creates a new account have no administered sites yet and are judged as before. Editors and viewers are never refused. The cross-site read is bounded (two queries for a member, at most three for a platform admin, whatever the number of sites), and a failure to read it fails open to Warn for its part of the answer, with one log line that names nobody.
  - **No migration; rolling the pin back is safe.** An older release goes back to the request site's policy alone. Why this rule and not another: [ADR 0085](../decisions/0085-an-administrators-password-answers-to-the-strictest-policy-of-every-site-they-administer-and-is-checked-at-sign-in-only-where-a-site-asks.md).

## Added

<a id="breached-password-sign-in-check"></a>

- **A site can check its administrators' passwords against known breaches when they sign in (#2407).** The breached-password check used to run only when a password was set, so a breached password set before the check shipped was never noticed. **Sign-in & access → Password policy** (`/editor/password-policy`) now has a checkbox, **Also check administrators' passwords when they sign in**, off by default. Saving it requires the site's admin role.
  - **Who is checked.** Only someone who administers a site with the box ticked, signing in with a password, on any site's host and through any door: the sign-in form, the form `POST` and `POST /api/auth/sign_in`. Editors and viewers are never checked at sign-in. A platform admin answers to every site with the box ticked. The outcome is the strictest policy among the administered sites that have the box ticked; a site with it unticked plays no part, and neither does the site the request came in on.
  - **Block.** The sign-in is refused before any session, remember-me cookie or second-factor prompt. The token the password minted is revoked, and a reset link is emailed: a mail of its own, "Choose a new password for your (site) account", saying that someone signed in with the account's current password and that it appears in a breach. The browser lands on the password reset page (`/reset`) with "Your password appears in a known data breach, so it can't be used to sign in as an administrator. We've emailed you a link to choose a new one. If it doesn't arrive, request one below." The API answers `403` with `code: "password_reset_required"` and no token.
  - **Warn.** The sign-in goes ahead. A browser sign-in shows "Your password appears in a public data breach. Change it soon from your account page." once it completes, after the second factor where there is one. The API's one-step `201` carries `"password_breach": {"status": "breached"}`; a two-factor sign-in's `201` from `/api/auth/sign_in/verify` does not.
  - **Bounded.** One lookup per sign-in, made only after the password verified: a wrong password, an unknown address, a throttled or challenged attempt and the form's keystrokes make none. The lookup holds no database connection and gives up after 1.5 seconds (`config :kiln_cms, KilnCMS.Accounts.BreachedPassword, sign_in_deadline: 1_500`, in milliseconds; there is no environment variable). Every failure, of the lookup or of reading the settings, lets the sign-in through. The same five-character hash prefix is sent at every checked sign-in; nothing is cached.
  - **Limits worth knowing.** The reset mail is charged to the address's reset-mail budget (five an hour), so repeated blocked sign-ins can use up the owner's own reset requests for that hour. A blocked sign-in is not forgiven by the per-account sign-in throttle, so an owner who keeps retrying is paused after 20 attempts in 15 minutes and gets the usual pause mail. A `403` `password_reset_required` tells the caller that the password was right and that the account administers a site that checks; it issues no token.
  - **For operators.** The audit log records each refusal as `sign_in_failed` with `method: "password"` and `reason: "breached_password"`, unsampled, in the log of each site whose policy refused it (not the site the request came in on), and does not count it toward the failed-sign-ins alert. `[:kiln_cms, :password, :breach_check]` gains `action: :sign_in`. The Security posture line `core.breached_passwords` gains a `sign_in_check` fact; its status is unchanged.
  - **Upgrade.** One expand-only migration adds `site_password_policy.check_on_sign_in` (boolean, not null, default false). Rolling the pin back is safe: an older release ignores the column. During a rolling deploy an older node does not show the sign-in warning that a newer node left for it; the older "breached password" note after a register or reset still works across both.

## Fixed

<a id="publish-shows-unpublish-date"></a>

- **Publishing a draft without opening the editor shows its scheduled unpublish date (#2892).** This was a 1.13.0 known issue. A draft can carry a takedown date, **Scheduled unpublish at** in the editor (`unpublish_at`, with `expiry_action` saying what happens then), and [ADR 0051](../decisions/0051-taking-content-down-needs-the-same-approval-as-putting-it-up.md) leaves it ungated on a draft because whoever publishes the draft approves the date with the page. Only the editor showed it. An admin who approved a draft from the content list, the bulk bar or a release never saw the date, and the page came down at it.
  - **The content list.** A draft or in-review row with a date shows it beside its **Publish** or **Approve** button, as published rows already did: **Unpublishes**, **Archives** or **Flagged expired**, by the record's expiry action, then the time.
  - **The bulk bar.** The **Publish** confirm says how many of the selected drafts have a date ("2 of these have a scheduled unpublish date") and lists them soonest first, up to ten. Selected rows off the current page or filter are counted too.
  - **Releases.** Each pending publish item for a draft with a date shows it under the title, and the panel with **Schedule** and **Publish now** totals them.
  - **Unchanged.** Publishing works as before; nothing is asked or refused that wasn't. No migration; rolling the pin back is safe.

<a id="markdown-inline-image"></a>

- **An image that is not alone on its line of Markdown is kept (#2771).** This was a 1.13.0 known issue. `KilnCMS.Markdown.to_blocks/2` and `parse_document/2` rendered every image as `<img>` and left it to the HTML adapter, which lifts an image into an image block only when it is the whole of a top-level paragraph. Anywhere else, mid-sentence (`Our logo ![Acme](https://x.test/a.png) is blue`), two to a line, or in a list item, quote or table cell, the adapter had no inline node for it and dropped the picture and its alt text with no error. The stored text read "Our logo is blue".
  - **What changes.** Such an image stays where it was, as a link to the picture labelled with its alt text (or with its URL when it has no alt text). That is what pasting Markdown into a rich-text block already did. An image inside a link (`[![CI](badge.svg)](https://ci.example)`) becomes the link's text, and the outer link stays.
  - **Where.** Every path through the converter: the editor's Markdown view and `.md` import, `body_markdown` writes over JSON:API, GraphQL and MCP, and anything else that calls `KilnCMS.Markdown`.
  - **Unchanged.** An image alone in its paragraph, linked or not, still becomes an `image` block with its alt text and title as caption. Content stored before the fix is not repaired: the dropped image was never saved, so import that Markdown again.
  - **No migration; rolling the pin back is safe.** An older release drops such images again on the next Markdown write.

<a id="duplicate-rich-text-body"></a>

- **A duplicated text block keeps its text when it is saved (#2778).** This was a known issue in 1.13.0. A rich-text block's prose is held by the editor's server session, keyed by the block's id, and added back into the form on every keystroke, save and autosave; the form itself carries only an empty HTML field for it. Duplicating a block gave the copy a new id but never registered its prose under that id, so the first keystroke anywhere in the form, or the save itself, stored the copy empty while its editor still showed the text.
  - **What happens now.** The copy's prose is registered under its own id the moment it is made, taken from what the original holds at that point, typed but unsaved text included. Save, autosave and *Publish changes* store it, and editing the original afterwards leaves the copy's text alone.
  - **Other copy paths checked.** Duplicating a columns block already copied its nested blocks' text, which lives in the columns block's own state, and keeps doing so. Duplicating a whole document copies the saved record on the server and never read the editor's state. Copy and paste between blocks goes through the editor's normal typing path.
  - **No migration; rolling the pin back is safe.** A copy saved empty on an earlier release stays empty; its original, or a version in the document's history, still holds the text to copy back.


<a id="slack-missing-site-name"></a>

- **A Slack webhook message whose payload names no site names the endpoint's site (#2797).** `KilnCMS.Webhooks.SlackFormat` renders a Slack-format endpoint's body at send time from the ledger row's payload, and read the site from its `site_name`. A test ping queued by a 1.9 node while a rolling deploy to 1.10 was under way carries Kiln's ping payload (`message`, `endpoint_url`, `sent_at`) and no `site_name`, so the new node posted "KilnCMS webhook test for `-`". A security alert row without the key would have read "Security alert on `-`".
  - **What changes.** `KilnCMS.Webhooks.DeliveryWorker` fills in a missing or empty `site_name` from the endpoint's site (`KilnCMS.Branding.for_org/1`) before rendering a Slack body. If the renderer is still handed a ping without one, it says "KilnCMS webhook test" with no placeholder.
  - **Unchanged.** The job arguments are the same shape they were in 1.9, so no compatibility clause was needed; only the payload differed. The ledger row keeps the payload as it was queued, and Kiln-format endpoints are sent exactly what they were before.
  - **No migration; rolling the pin back is safe.** An older release renders such a row with `-` again.


<a id="console-small-defects-2"></a>

- **More small console fixes from the November bug sweep (#2786).**
  - **A row deleted behind the page.** **Edit** on `/editor/automation` read the rule with a raising call, so editing one another admin had just deleted crashed the page. It now says "That rule no longer exists." and refreshes the list, as does saving an edit of a rule deleted while the form was open. Deleting a rule closed whatever edit form was open, another rule's half-typed changes included; it now closes only that rule's. On `/editor/billing`, deleting the tier being edited left the form bound to it, so its next save could only fail; the form goes back to adding a tier.
  - **Analytics on a site other than the default.** The most-viewed list looked each content type up without the site, so every admin-defined type on any other site read "(unknown type: …)" with no link. It now shows the entry's title and links to it.
  - **Calendar.** A drag the server refused (into the past, or a move the editor may not make) left the chip on the day it was dropped: the re-read window rendered nothing new, so the browser got no patch. Every day's drop list now re-renders from what is saved. A `?type[a]=b` in the address crashed the page; a type filter that is not a plain value now shows every type.
  - **Custom fields.** Editing a field whose type has no default input (a color or email field, say) cleared the default it had been given through the API; it is kept while the type stays the same. A new sub-field of a group, or a new item type, took its siblings' count as its position, which after a delete is a position a sibling already has; it now goes after the last one. "A copy of another field" offered nothing for a Person field; it lists the site's other Person fields, and a private field copies only into a private one, as the save already required.
  - **Claim checking.** A save the site refused (a phrase over the length limit, say) reseeded the form from what was saved, so everything typed was lost. The form now keeps it beside the error.
  - **Taking over a field on a live document.** A takeover flushes the holder's queued autosave first, but only did so for drafts. A live document autosaves into its working copy, so the holder's edit stayed queued, the taker kept editing the text from when the page opened, and the next save met a conflict. The holder's edit is now saved to the working copy before the field moves, the taker gets the saved text, and the takeover dialog says nothing is lost.
  - **Not changed.** A `?to=9999-12-31` date filter on `/editor` was reported as a crash; it lists as expected.
  - **No migration; rolling the pin back is safe.**


<a id="reserved-route-slugs"></a>

- **A slug that a built-in route already answers is refused (#2898).** This was a 1.13.0 known issue. `KilnCMS.CMS.ContentTypes.reserved_path_segments/0` is the list the slug, path-alias and content-type validations check, and it had fallen behind the router: `GET /developers`, `/ready`, `/setup`, `/sign-in`, `/sign-out`, `/actor`, `/ap/...`, `/mcp` and `/password-reset/:token` are all declared ahead of the `/:slug` catch-all. A page slugged `developers` saved without error, and `/developers` kept serving the developer page.
  - **What changes.** Those segments are reserved. A page slug, a path alias's first segment, or a dynamic content type's path segment equal to one is refused with the existing reserved-slug error. A title-derived or regenerated slug steps around them (`developers-2`). Installed plugins' public and plug routes are declared ahead of `/:slug` too, so their first segments are reserved as well.
  - **Kept in step.** `KilnCMSWeb.ReservedRouteSegmentsTest` reads the compiled route table and fails when a GET route ahead of `/:slug` has an unreserved first segment. Names with a dot (`sitemap.xml`, `llms.txt`) are skipped: no slug or alias can contain one. `forms` and `newsletter` stay free, because every route under them is three segments deep and answers neither `/forms` nor `/forms/<slug>`.
  - **Unchanged.** Post and entry slugs live under `/blog/` or their type's segment, which no such route reaches, so `developers` is still a valid post slug. A dynamic type that already used a newly reserved segment can still be edited: its segment is checked only when it changes.
  - **No migration; rolling the pin back is safe.** Existing records are not changed; see the upgrade note for listing them.


<a id="fallback-mode-refire"></a>

- **Changing a custom field's localization to or from `:fallback` re-fires the type's locale variants (#2905).** A `:fallback` field that a variant leaves empty is filled from the next locale along the site's chain when the variant is fired, and the fired `:json` body names it under `inherited_fields`. Saving the chain at `/editor/locales` and publishing a variant re-fired the documents that inherit; changing the field's mode on the Fields screen re-fired nothing. A French page whose tagline was empty kept serving it empty, with no `inherited_fields`, after the field became `:fallback`, and kept serving the English tagline after it stopped being one, until that page was next published.
  - **What changes.** `KilnCMS.CMS.Changes.BustTypeRegistry` now re-fires the field's type when its `localization` changes to or from `:fallback`, and when a `:fallback` field is deleted. Only the type's published rows outside the default locale are queued (`KilnCMS.Firing.Sweep.sweep_type/3` with `only: :translations`): the default locale ends every chain, so it never inherits. A site with no translations queues nothing.
  - **Unchanged.** A switch between `:localized` and `:shared` re-fires nothing; a shared value is copied into the variants when the source publishes, as before. Creating a field as `:fallback` re-fires nothing either: no document holds a value for it yet.
  - **No migration; rolling the pin back is safe.** An artifact fired with the old answer on an earlier release is corrected by `mix kiln.refire_all`, or by publishing the variant.
