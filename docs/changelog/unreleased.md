# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Breaking

<a id="multi-org-installs-now-refuse-unknown-hosts-unless-tenantstricthostfalse"></a>

- **Multi-org installs now refuse unknown hosts unless `TENANT_STRICT_HOST=false`.**
  `TENANT_STRICT_HOST` has a third state, and it is the new default: **unset
  means auto** — strict host matching is on if and only if more than one
  organization exists. A single-org install behaves exactly as before; a
  deployment with two or more organizations, where `TENANT_STRICT_HOST` was
  never set, now answers a request whose `Host` matches no organization (a bare
  hostname, an IP literal, a platform's internal hostname, an attacker-supplied
  header) with a `404` — or a retryable `503` if the database is down — instead
  of the default org's content, branding and analytics. The `PHX_HOST` apex, the
  `KILN_CONSOLE_HOST`, the health probes (`/up`, `/ready`) and the payment
  webhook are never refused.

  **To keep the old behaviour**, set `TENANT_STRICT_HOST=false`. Kiln then warns
  about it at boot and on `/editor/system`, as it has since #660, and those
  warnings now name the explicit `false` as the cause. An explicit
  `TENANT_STRICT_HOST=true` is unchanged.

  Auto follows the organization count without a restart: creating the second
  organization turns it on immediately on the node that served the create, and
  on the others through a `Phoenix.PubSub` broadcast (a node that misses it
  recounts within five minutes). The per-request check reads a cached verdict,
  never a count. If the count cannot be read at all — a node that booted while
  Postgres was unreachable — auto fails **closed** and refuses unknown hosts
  until a count succeeds, because serving another tenant's site to an
  unrecognized host cannot be undone and a retryable refusal can. See
  `KilnCMSWeb.Tenant.OrgCount`, `docs/multi-tenancy.md` and
  `docs/environment-variables.md`. Decision 4 of `docs/roadmap-1.0.md`
  ([#1547](https://github.com/The-Verscienta/kiln_cms/issues/1547)).

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

<a id="sign-in-and-the-other-account-pages-show-the-sites-own-name-and-logo"></a>

- **Sign-in and the other account pages show the site's own name and logo.**
  `/sign-in`, `/register`, `/reset`, `/sign-out` and the password-reset,
  confirmation and magic-link pages never assigned `:current_org`, so
  `Layouts.auth/1` failed closed to the stock KilnCMS name and logo on every
  host, a tenant's included. The document title was right, because the root
  layout reads the org from the request, which is why no title test caught it.
  The router did list `{KilnCMSWeb.LiveUserAuth, :assign_current_org}` for these
  pages, but AshAuthentication's route macros de-duplicate a live session's
  `on_mount` list by module, so of the two or three `LiveUserAuth` entries only
  the first, `:restore_locale`, ran. The sign-in page also lost
  `:live_no_user`, which sets its `:current_scope`. The same skipped hook is
  what refuses a socket that claims a different org's host, and what vouches
  the socket's host before `KilnCMSWeb.SignInLive` passes a patch URL to the
  library (#687). Neither ran on these pages until now.
  Each route now lists `LiveUserAuth` once, with its steps in order:
  `{KilnCMSWeb.LiveUserAuth, [:restore_locale, :assign_current_org]}`. The new
  list form runs the named clauses in sequence and stops at the first that
  halts. Kiln's own live sessions keep their separate entries, since
  `live_session` does not de-duplicate. On a multi-org install with
  `TENANT_STRICT_HOST` on, a connected mount of these pages from an unknown host
  is now refused with the same 404 the HTTP request already got.
  ([#1613](https://github.com/The-Verscienta/kiln_cms/pull/1613))

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
