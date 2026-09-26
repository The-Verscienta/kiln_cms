# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

<a id="a-site-can-offer-its-own-single-sign-on-provider"></a>

- **A site can offer its own single sign-on provider.** A site admin sets an
  OpenID Connect issuer, client ID and client secret at `/editor/site-sso`, and
  the site's sign-in page offers "Sign in with …" beside the password form. The
  operator's `OIDC_*` provider is unchanged. Accounts belong to the whole
  deployment, so the site's provider is honoured only for addresses in email
  domains the site verified with a DNS TXT record (`_kiln-sso.<domain>`), looked
  up again on every sign-in, and never for an account with access on another
  site or across the deployment — a platform admin, another site's member, or a
  membership-less global editor. Those people sign in the other ways. The flow is
  deliberately not an AshAuthentication strategy: a per-site strategy would
  share the operator's identity namespace, so a site's provider asserting a
  `sub` the operator's had already linked would sign in as that account. It is
  Assent's OIDC callback (state, nonce, PKCE, `RS256` only) behind two routes,
  with every provider request through `SafeFetch`. The client secret is
  vault-encrypted and write-only; if it can't be decrypted, the site's SSO says
  it is unavailable rather than falling back to the operator's provider. Turning
  password sign-in off per site, SAML, and several providers per site are not
  in this change.

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

<a id="a-site-can-index-its-content-into-its-own-meilisearch-set-from-the-console"></a>

- **A site can index its content into its own Meilisearch, set from the console.**
  `/editor/site-search` (Configure → Integrations → Search instance) lets a
  site admin set the URL, API key and index their site's published content is
  indexed into. No `MEILI_*` variables and no redeploy (#1558). The `MEILI_*`
  variables are unchanged: they are the instance for every site that hasn't
  set its own. The third integration #1322 moves out of the environment,
  built the way the site SMTP relay was:

  - **Says what leaves.** The page states, above the form, that every
    published document an anonymous visitor could read — full text included —
    is sent to that URL.
  - **One resolver.** `KilnCMS.Search.Meilisearch.SiteInstance` is asked by
    the indexing jobs, by `Meilisearch.search/2` and by the publish path's
    enqueue gate, so indexing and search can't disagree about a site's
    instance. The site's requests are built from its row alone; nothing of the
    operator's URL, key or index goes with them.
  - **Key encrypted.** Stored with `KilnCMS.Keys.Vault` (a
    `Vault.Ciphertext` column, so `mix kiln.vault.reencrypt` rotates it),
    never shown again, kept on a blank save, and with no env-var or file
    source.
  - **Fails closed, one direction per axis.** If the row can't be read or the
    key can't be decrypted, *indexing* is held and retried for ~16 hours
    (never written into the operator's instance), and *search* returns an
    error without a request so the caller uses the built-in Postgres search
    (never the operator's index, which holds other sites' content).
  - **SSRF-checked.** HTTPS only, and refused if it resolves to a private,
    loopback, link-local or metadata address — at save, and on every request,
    which goes through `KilnCMS.SafeFetch` (pinned, no redirects).
    `SafeFetch.request/3` is new, for PUT/PATCH/DELETE.
  - **Reindexes on change.** Every save, switch-off or removal enqueues a full
    reindex of the site into the instance it now uses, and the page counts the
    jobs left. A reindex that succeeds releases jobs held behind a broken
    instance instead of leaving them to their backoff.

  `MeilisearchWorker` now retries up to 9 times over ~16 hours (was 3), for
  the operator's instance too.

<a id="a-site-can-keep-its-uploads-in-its-own-object-storage-bucket-set-from-the-console"></a>

- **A site can keep its uploads in its own object storage bucket, set from the
  console.** Configure → Integrations → **Object storage**
  (`/editor/site-storage`, #1559) takes an S3-compatible endpoint (blank for
  AWS), region, bucket, an optional private bucket, the bucket's public URL and
  a key pair; the site's new uploads then go there instead of to the
  operator's `S3_*` storage. Storage holds data, which is what made this
  harder than the other per-site integrations: every media item now records
  the store its file went to (`storage_profile_id`, a nullable column with no
  default, so the migration rewrites nothing and every existing row reads as
  "the operator's store"). Reads, downloads, streaming, variants, posters,
  transforms, gating and deletes follow the row, never the site's current
  setting, and a store's location never changes in place — moving the site to
  another bucket makes a new `StorageProfile` and leaves the old one, so
  nothing is stranded and nothing needs a backfill. There is no background
  copy job: files stay where they were stored. `KilnCMS.Storage.S3` and its
  `ReqClient` now take a site's credentials, endpoint and buckets per call, and
  that config is built from the site's settings alone and handed to
  `ExAws.Operation.perform/2` — `ExAws.request/2` would have merged the
  operator's session token, endpoint and instance-role credentials underneath
  it (`SiteStorageIsolationTest` plants them and checks). The private bucket
  (gated documents) and presigned direct uploads get the same treatment. The
  secret is vault-encrypted, write-only and database-only; the endpoint must be
  `https://` and is refused if it resolves to a private or metadata address, at
  save and on every connection, which is pinned to the checked address. A site
  whose bucket can't be used — unreadable settings, an undecryptable secret,
  a refused endpoint — has its uploads **refused**, never written to the
  operator's bucket. A **Test** button writes, reads back and deletes a probe
  object, and the site's bucket origin is added to that site's `img-src` and
  `media-src`.

<a id="a-site-on-its-own-smtp-relay-keeps-its-own-bounce-list"></a>

- **A site on its own SMTP relay keeps its own bounce list.** When a site's own
  relay (`/editor/site-mail`) rejects a recipient as dead (`5.1.1`, `5.2.1` and
  the like, in the mail transaction), the address goes on that site's own
  suppression list (`KilnCMS.Mail.SiteSuppressedRecipient`, keyed by site and
  address), and that site's newsletters and other queued mail skip it (#1562).
  Before, a site relay's hard reject cancelled that one message and nothing
  more, so a site on its own relay kept mailing dead addresses on every
  newsletter, which hurts its standing with its provider.

  The list stops only that site's mail. The relay is a server the site chose,
  and it may answer 550 to any address, so its word never reaches the
  instance-wide list, another site's mail, or account mail (sign-in links,
  password resets), which carries no site and never consults a site's list.
  The worst a hostile relay can do with it is stop mail its own site sends. The
  instance-wide list stays the operator's relay's alone, and it still applies
  to every site's mail. Only a reject naming the recipient suppresses: a relay
  refusing our AUTH, TLS or sender, and a reject that doesn't say whose fault
  it is, suppress nobody, as on the operator's relay.

  `/editor/site-mail` gains the **Delivery health** panel `/editor/mail` has,
  scoped to the site: its recent hard bounces and give-ups by recipient domain
  (newsletter jobs included), and its suppressed addresses, each with
  **Remove**. The list is read and cleared by the site's admins only, and
  written by nothing but the delivery pipeline. One new table,
  `site_suppressed_recipients`.

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

<a id="a-sites-relay-refusing-its-password-no-longer-pages-the-operator"></a>

- **A site's relay refusing its password no longer pages the operator.** A
  site's own relay refusing AUTH, TLS or the sender raised the operator's
  "relay refused" alert (log error, Sentry message, telemetry) as if the
  deployment's relay were broken, and spent that alert's 15-minute cooldown, so
  the operator's own relay failing in that window went unreported. It now
  alerts only for the operator's relay, as the relay-unreachable alert already
  did (#1562).

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
