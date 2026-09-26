# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

<a id="a-site-can-sign-its-push-notifications-with-its-own-key-generated-in-the-console"></a>

- **A site can sign its push notifications with its own key, generated in the
  console.** `/editor/site-push` (Configure → Integrations) gives a site its own
  Web Push (VAPID) key pair with one *Generate* click (#1560), the way the DKIM
  key is generated on `/editor/mail`. Nothing is pasted, and the private half is
  encrypted with `KilnCMS.Keys.Vault` (`SiteVapidKey.private_key_encrypted`,
  typed `Vault.Ciphertext`, so `mix kiln.vault.reencrypt` walks it). The
  subject defaults to `mailto:` the generating admin and can be edited. Push no
  longer needs the operator to set `KILN_VAPID_*` and redeploy before a site
  can use it. Those variables are unchanged and remain the default for every
  site without its own pair.

  - **One resolver.** `KilnCMS.Push.Keys` answers both the subscribe side
    (which public key the browser is handed) and the sending side (which pair
    signs), so the two cannot disagree.
  - **Subscriptions are bound to their key.** `PushSubscription` records the
    site key it was made against (`vapid_public_key`; `nil` means the
    deployment's). Existing subscriptions keep the deployment's key after a site
    generates its own, so nobody's notifications stop. New subscriptions use the
    site's key, and a device moves over when it next turns notifications on.
  - **Rotation is deliberate.** *Rotate key* confirms first and names how many
    devices it cuts off. It deletes the subscriptions bound to the old key in
    the same transaction, rather than leaving rows that would be signed with a
    key the push service rejects. A subscription that raced a rotation is
    pruned by the worker without a request.
  - **Fails closed.** A site key that can't be decrypted (after a
    `SECRET_KEY_BASE` rotation) or read holds that site's pushes, keeps the
    subscriptions and says so on the page. It never signs with the deployment's
    key instead.

<a id="a-site-can-use-its-own-ai-provider-key-and-models-set-from-the-console"></a>

- **A site can use its own AI provider key and models, set from the console.**
  `/editor/site-ai` (under Configure → Integrations) lets a site admin choose
  the provider, API key and a model for each of SEO suggestions, block assist
  and `/api/ask` answers. No `SEO_MODEL` / `ASSIST_MODEL` / `ASK_MODEL` and no
  redeploy (#1557). Those variables are unchanged: they are the configuration
  for every site that hasn't set its own. The second integration #1322 moves
  out of the environment, built the way the SMTP relay set the pattern.

  - **Precedence.** A site with its own provider switched on uses it for all
    three features and nothing of the operator's: not the key, not `base_url`,
    not a bespoke generator module. A blank model switches that feature off
    for the site rather than handing it to the operator's provider.
  - **Fails closed.** If the row can't be read, or its key can't be decrypted,
    the request is refused and the editor says why; `/api/ask` answers
    retrieval-only with `"generation": "failed"`. It never falls back to the
    operator's provider (`KilnCMS.LLM.SiteProvider`), which would send the
    site's content through an account it opted out of and bill the operator.
  - **Key encrypted, write-only, database-only.** Stored with
    `KilnCMS.Keys.Vault` in a `Vault.Ciphertext` column, never shown again, no
    env-var or file source. Changing the provider or endpoint drops it.
  - **Nothing of the operator's rides along.** `req_llm` fills an unset key or
    endpoint from the operator's config and environment, so a site request
    always passes both explicitly; a test plants the operator's credentials in
    every place `req_llm` reads and inspects the request that leaves.
  - **SSRF-checked.** Hosted providers are dialled at their own API host. An
    OpenAI-compatible endpoint must be `https://`, is refused if it resolves
    to a private, loopback, link-local or metadata address, and is reached only
    through `KilnCMS.SafeFetch`.
  - **Budgets apply.** The per-user, per-caller and per-site `KilnCMS.LLM.Budget`
    limits apply to a site's own key as to the operator's.

  New table `site_ai_providers` (one migration). Its `api_key_encrypted` column
  is walked by `mix kiln.vault.reencrypt`; see `docs/secrets-rotation.md`.

## Fixed

<a id="an-open-calendar-no-longer-re-queries-once-per-write-during-a-bulk-import"></a>

- **An open calendar no longer re-queries once per write during a bulk
  import.** `/editor/calendar` refreshes when anything it plots is written, and
  it used to coalesce a burst of those writes with a `receive ... after 0`
  mailbox drain. A drain only collapses messages already queued, so a
  sequential import — writes a few milliseconds apart, each handled before the
  next arrived — ran one full window re-query per write on every open calendar
  in the org: 43 re-queries for a 100-page import, measured against real
  writes. The first change now arms a fixed 100ms window, every later one is
  absorbed into it, and one re-query runs when it closes, so the same import
  costs three. The window is not reset by later writes, so a long import
  never holds the calendar more than 100ms behind. A single save elsewhere now
  shows up on an open calendar up to 100ms later than before. The
  `kiln_cms.calendar.requery` telemetry and `CalendarRequeryMonitor` log line
  keep their meaning: messages answered per re-query.
  ([#1336](https://github.com/The-Verscienta/kiln_cms/issues/1336))

## Security

<a id="two-hex-advisories-closed-and-the-working-copy-survives-the-ash-fix"></a>

- **Two Hex advisories closed, and the working copy survives the `ash` fix.**
  `ash` 3.33.6 carried **EEF-CVE-2026-93477** (MEDIUM — private action arguments
  could be set by user input on the bulk destroy and bulk update paths) and
  `lazy_html` 0.1.12 carried **EEF-CVE-2026-92106** (LOW — SVG and MathML
  `style` and `script` text serialized unescaped, allowing mutation XSS). Both
  are closed by `ash` 3.33.11 and `lazy_html` 0.1.13. `mix deps.audit` reported
  neither — the mirego mirror was behind, as it was on 2026-09-18 — and
  `mix hex.audit` is what caught them, which is why both audits run in CI.
  The `ash` release also ships *"properly compare unions w/ `Ash.Type.equal?`"*,
  and that broke the working copy on the way in. `ContentEditorLive` seeds the
  autosave form on a struct whose `working_blocks` already hold the tree the
  copy is measured against, so the block sub-forms bind to existing blocks by
  index rather than creating new ones. A title-only save therefore submits that
  same tree, and once Ash compared two equal union trees correctly the write
  became a no-op: the copy was stamped with an empty body, and "Publish changes"
  would then have published nothing. It looked correct in memory, because the
  record Ash hands back reflects the seeded struct rather than the row. The
  seeded tree is now for sub-form binding only — the changeset diffs
  `working_blocks` against what the row actually holds, so an unchanged body on
  a document with no working copy yet is a real change again. Where the row
  already holds that tree the write is still elided, which is correct: the
  column already says what the save means to say. Worth recording that
  `force_change_attribute/3` is **not** a way out of this — it bypasses the
  acceptance checks, not the equal-to-data elision.
