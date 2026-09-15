# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

<a id="a-configure-hub-at-editorconfigure"></a>

- **A Configure hub at `/editor/configure`.** The console had twenty-odd
  configuration screens and no screen that *was* configuration: the one page
  named Settings is your own profile and 2FA, and a sidebar link is a name with
  no explanation attached, so "where do I turn off full-text RSS" meant guessing
  between Feeds, Delivery and Code injection. The hub lists every configuration
  screen you may open, grouped as the sidebar groups them, each with a line
  saying what it is for, over a filter that matches those descriptions and a
  keyword list as well as the names — "rss" finds Feeds, "stripe" finds
  Billing, "passkey" finds your own settings (#1319).

<a id="notifications-are-persisted-not-only-mailed"></a>

- **Notifications are persisted, not only mailed.** Every workflow event
  already dispatched by email and Web Push — submitted for review, published,
  returned to draft, a comment, an `@mention`, a task assignment — now also
  writes a `KilnCMS.Notifications.Notification` row for each recipient, so an
  editor who does not read email and has not granted push has somewhere to find
  out. The row is written from the same place, on the same already-filtered
  recipient list, that enqueues the mail job: an event a user has muted in their
  account preferences stays muted in the inbox too. Rows are org-scoped and
  readable **only by their own recipient** — there is no admin bypass. The bell
  and `/editor/inbox` that read them follow. Reading one is announced on the
  recipient's own PubSub topic, so a notification read on a phone drops the
  badge on the desktop.

<a id="editorinbox"></a>

- **`/editor/inbox`.** The notification inbox: everything the console has told
  this editor about, newest first, with an unread filter, per-row mark-read /
  mark-unread and mark-all-read. Every row deep-links to the thing it concerns
  — a comment or a block-anchored task opens that block's thread via the
  `?comment=<block_id>` param the editor already reads at mount, which is the
  console's only durable block anchor (heading `id`s exist in public delivery
  only). Live: one `on_mount` hook subscribes each console page to the viewer's
  own notification topic, so the list follows a notification that lands, or one
  read in another tab, without a reload.

## Changed

<a id="new-page-no-longer-writes-a-row-until-you-start-writing"></a>

- **"New page" no longer writes a row until you start writing.** Clicking New
  used to create an "Untitled …" draft on the spot, so looking and pressing Back
  left a row behind for the weekly untitled sweep. New now opens
  `/editor/content/:type/new`, an unsaved editor showing the title and a Save
  draft button. The first non-blank title keystroke, or Save draft, creates the
  draft through the same create action, actor and site as before, and the same
  editor carries on at `/editor/content/:type/:id` without reloading, so the
  caret stays in the title. Someone who may not author the type is turned away
  at `/new` with the same refusal the content list already applied. The
  untitled sweep stays, for drafts abandoned after they were created.

<a id="configruntimeexs-is-now-an-index-not-a-1523-line-file"></a>

- **`config/runtime.exs` is now an index, not a 1,523-line file.** The
  configuration moved into per-concern fragments under `config/runtime/`
  (`observability.exs`, `governance.exs`, `prod/mailer.exs`, …), evaluated in
  exactly the order their blocks appeared before. Behaviour is unchanged: the
  same variables are read, in the same sequence, producing the same
  application env and the same boot warnings in the same order. Operators
  change nothing.

  One thing to know if you build releases outside the shipped Dockerfile:
  `mix release` copies only `config/runtime.exs` into `releases/<vsn>/`, so the
  fragments are copied alongside it by a `:steps` hook in `mix.exs`, and the
  Dockerfile now `COPY`s the directory into the build context. The hook refuses
  to assemble a release if the directory is missing rather than producing an
  image that fails on first boot.

<a id="docsenvironment-variablesmd-and-envexample-lead-with-the-short-list"></a>

- **`docs/environment-variables.md` and `.env.example` lead with the short
  list.** Both now open with **Required (3)** — `DATABASE_URL`,
  `SECRET_KEY_BASE`, `TOKEN_SIGNING_SECRET`, the only variables that stop a
  production boot — then **Common (10)**, then everything else grouped by
  feature. The previous "Required (production)" section also listed `PHX_HOST`
  and `PHX_SERVER`, neither of which raises; both are still documented, under
  server & networking. The required set is derived from the code and pinned by
  a test, so it cannot drift from what actually raises.

<a id="the-stock-front-page-now-renders-in-the-public-delivery-chrome"></a>

- **The stock front page now renders in the public delivery chrome.** `/` was
  the one public URL served out of `Layouts.app`, the authoring shell — so a
  first-run instance gave its front page a theme toggle and an account menu no
  other public page has, while skipping the site's own header and footer menus,
  its theme preset and the attribution line. It now uses `Layouts.public` like
  every other delivery URL. That layout gained two optional attrs to make the
  move lossless: `wide`, which widens `--public-measure` to the 72rem the page
  was drawn at (all the old `container_class` was doing), and `current_user`,
  which draws the account/sign-out pair for a signed-in reader. Nothing changes
  for a site that has published a Home page of its own — that page already
  rendered in this shell.

<a id="the-public-search-form-has-a-submit-button"></a>

- **The public search form has a submit button.** It was a label and a single
  text input, which submits on Enter and nothing else: a touch keyboard without
  a Search key and a screen reader reading the form both had no way to run the
  query. The button carries a `public-search-submit` hook for the theme presets.

<a id="the-product-name-is-spelled-kilncms-everywhere"></a>

- **The product name is spelled `KilnCMS` everywhere.** Thirteen places still
  said "Kiln CMS" — among them the heading and opening line of
  `docs/design-language.md`, which `scripts/publish_docs.exs` publishes as a
  public docs page, and the `title` of the exported delivery schema.

<a id="the-docs-publisher-no-longer-installs-earmark"></a>

- **The docs publisher no longer installs `earmark`.**
  `scripts/publish_docs.exs` renders with `earmark_parser` — the parser mix.exs
  already depends on — and a renderer ported from `KilnCMS.Markdown`, so the
  retired package and its stored-XSS advisory are gone from the repo entirely.
  Nothing about a guide's published HTML changes, with one exception: the
  fenced HTML example in `docs/visual-editing-bridge.md` regains two lines that
  earmark's own parser was silently eating.

<a id="workflow-and-task-notifications-now-dispatch-after-the-write-commits"></a>

- **Workflow and task notifications now dispatch after the write commits.**
  `NotifyWorkflowEmail` and `NotifyTaskAssigned` moved from
  `Ash.Changeset.after_action` to `after_transaction`, joining `NotifyComment`,
  which was already there. Two effects: a query inside the notifier can no
  longer poison the editorial action's transaction and lose the content, and a
  rolled-back submit-for-review no longer mails the reviewers about a
  transition that never happened.

<a id="a-secrets-rotation-runbook-docssecrets-rotationmddocssecrets-rotationmd-closing"></a>

- **A secrets-rotation runbook**, [`docs/secrets-rotation.md`](../secrets-rotation.md),
  closing residual risk 12 in `docs/threat-model.md` (#1304). Per-secret
  procedures against a running deployment, written from what the code does
  rather than what would be reasonable — so it says plainly that nothing here
  supports a dual-key transition: `TOKEN_SIGNING_SECRET` and `SECRET_KEY_BASE`
  are hard cutovers that sign every user out, while `DATABASE_URL` and the S3
  keys can be rolled without downtime only because Postgres and S3 will each
  hold two credentials at once. It also documents the trap: `SECRET_KEY_BASE`
  keys `KilnCMS.Keys.Vault`, so rotating it **permanently orphans** the DKIM
  key, social credentials, payment secrets and the ActivityPub actor key, with
  no re-encryption path — and every one of those fails quietly, behind a
  settings page that keeps rendering from its plaintext columns. The actor key
  is called out as the one rotation that cannot be done safely today.

<a id="editoraccounts-the-instance-wide-account-register"></a>

- **`/editor/accounts` — the instance-wide account register.** Platform-admin
  only. Lists every registration (search by email or name; filter by platform
  role, or to unconfirmed / temporarily elevated / erased accounts), and carries
  the levers that belong to an *account* rather than to a site: the standing
  platform role and consumer audiences, a time-boxed role grant, a
  password-reset link, signing every session out, and removing the account.
  `/editor/team` is unchanged and still answers the other question — who may
  author what on *this* site. See `docs/account-administration.md`.

<a id="temporary-roles-that-expire-on-their-own"></a>

- **Temporary roles that expire on their own.** Either tier can be granted for a
  bounded window — "admin until Friday" on the platform role from
  `/editor/accounts`, "editor on this site until Friday" on the site tier from
  `/editor/team`. Two new columns on `users` and `org_memberships`
  (`granted_role`, `granted_role_expires_at`); the standing `role` is never
  overwritten, so expiry is a comparison rather than a scheduled write and a
  missed sweep cannot leave anyone elevated.
  `KilnCMS.Accounts.Preparations.FoldRoleGrant` presents a live grant as `role`
  on every read, which is how it reaches `Scoping.effective_tier/2` and the
  `actor_attribute_equals(:role, …)` policies without either knowing it exists.
  An hourly AshOban sweep clears expired columns and drops the holder's live
  sockets. Grants are elevations only, and carry no scope axes. The window is one
  of five offered durations or an explicit UTC datetime.

<a id="admin-initiated-password-resets"></a>

- **Admin-initiated password resets.** `Accounts.send_user_password_reset/2`
  mails a named account a reset link and reports whether it went — which the
  anonymous form deliberately cannot, since it must stay indistinguishable for
  addresses that don't exist. Bypasses (and logs) the per-address mail budget:
  nobody reaches it without an admin session, and a silent drop there would make
  the console's confirmation a lie. Erased accounts are refused.

<a id="account-removal-with-a-content-disposition"></a>

- **Account removal with a content disposition.**
  `KilnCMS.Accounts.AccountRemoval.remove/3` erases the account and applies one
  of three dispositions to everything it authored, across every content type on
  every site: **keep** (published work stays in delivery; its byline stops naming
  a person), **archive** (the workflow transition, reversible by an editor), or
  **trash** (soft-delete, restorable from `/editor/trash`). Content first,
  account second, so a partial run leaves a recoverable account rather than a
  tombstone with unhandled content. Hard-delete (`:purge`) is deliberately not
  offered.

<a id="a-guard-on-the-last-admin"></a>

- **A guard on the last admin.** Demoting or erasing the only platform admin is
  refused rather than silently locking every operator out of `/editor` — `/setup`
  does not come back, because the account still exists. A temporary admin does
  not count as the other one, and the guard covers actorless system calls too;
  only `Staging.Scrub` is exempt, by name.

<a id="kilncmsaccountschecksplatformadmin-replaces-actorattributeequalsrole-admin-on"></a>

- **`KilnCMS.Accounts.Checks.PlatformAdmin` replaces
  `actor_attribute_equals(:role, :admin)`** on every platform resource. It asks
  for the *effective* role and re-checks a temporary grant's expiry at
  authorization time, so a LiveView or GraphQL socket that mounted while a grant
  was live stops authorizing as admin the moment it expires. Behaviour for
  standing admins is unchanged.

<a id="erasure-revokes-api-keys"></a>

- **Erasure revokes API keys.** `:anonymize` deleted passkeys and IdP links and
  revoked session tokens, but left API keys live — each a complete credential for
  the erased account. It now revokes them, and clears any temporary grants.

<a id="contenttypescount2-the-count-list2-would-return-rows-for-without-the-rows-for"></a>

- **`ContentTypes.count!/2`** — the count `list!/2` would return rows for,
  without the rows, for compiled and dynamic types alike.

<a id="the-release-image-is-published-to-ghcr-on-every-version-tag"></a>

- **The release image is published to GHCR on every version tag.**
  `docker pull ghcr.io/the-verscienta/kiln_cms:<version>` (or `:latest`) now
  gets the project-agnostic core, built by
  `.github/workflows/release.yml` from the same `Dockerfile` CI builds on every
  PR and stamped with the commit and build date. `linux/amd64` only. Submodule
  overlays are unaffected — an overlay still builds its own image with
  `--build-arg PROJECT=<name>`, and `mix kiln.update` remains the way a pinned
  project moves between releases (#1328).

<a id="githubsupportmd-and-a-status-maturity-section-at-the-top-of-the-readme"></a>

- **`.github/SUPPORT.md`, and a "Status & maturity" section at the top of the
  README.** Where questions, bugs and security reports each go, and what
  response time to expect from a single-maintainer pre-1.0 project; plus, up
  front, that KilnCMS is consumed as a git-submodule overlay rather than a Hex
  package, and which surfaces are stable, which move without notice, and which
  are off by default (#1328).

<a id="docsoverlay-contractmd-what-a-downstream-overlay-may-rely-on-across-releases"></a>

- **`docs/overlay-contract.md` — what a downstream overlay may rely on across
  releases.** The semver table says a major bump means "the overlay contract
  broke", but nothing said which surfaces that covers. This one does: a table
  of covered surfaces (the `KilnCMS.CMS.Content` options and injected hooks,
  the `Kiln.Plugin` callbacks, the block DSL and its `_type`/`_version`
  attributes, the extension behaviours, the config keys, the `PROJECT` build
  arg and `priv/` merge conventions, and the `public-*` CSS hooks), a matching
  list of what is *not* covered and may change in a patch, the three things a
  minor may still do that cost an overlay work — including the two production
  incidents the `overlay_drift` job exists to prevent (#452/#459, #488/#504) —
  the additive-first deprecation path, four CI commands a downstream repo
  should run, and the soft spots stated outright: the block upcast path has
  never run a real migration, eager backfill is unwired, `to_markdown/1` is
  probed rather than declared, and `Kiln.Plugin` declares no optional
  callbacks. Linked from `projects/README.md` (which keeps the mechanics) and
  the getting-started guide router (#1328).

<a id="kilnfieldtypeparsefloat1-a-covered-numeric-parse-for-a-custom-field-types-cast2"></a>

- **`Kiln.FieldType.parse_float/1` — a covered numeric parse for a custom
  field type's `cast/2`.** `Float.parse/1` is not total, and *how* it fails is
  toolchain-dependent: on a literal that overflows a double it returns `:error`
  on Elixir 1.20 and **raises** `ArgumentError` on 1.19, the version
  `.tool-versions` pins. A `cast/2` runs on every content write including
  public ones, so the difference is a validation message on one toolchain and a
  500 on the other. The core already had this as `KilnCMS.CMS.Computed`'s
  `@doc false` `safe_float/1`; it is now public, documented, spec'd, and listed
  in the covered-surfaces table, because a downstream field type needs it for
  exactly the reason the core's own `Geolocation` does.

<a id="the-in-tree-example-overlay-no-longer-reaches-past-the-overlay-contract"></a>

- **The in-tree example overlay no longer reaches past the overlay contract.**
  The money field type (`projects/example/field_types/money.ex`) parsed its
  amount through `KilnCMS.CMS.Computed`'s `safe_float/1`, which is marked
  `@doc false` — a surface `docs/overlay-contract.md` explicitly excludes. It
  now calls `Kiln.FieldType.parse_float/1`. Its `cast/2` semantics are
  unchanged and are now pinned by tests. The `@doc false` helper is gone; it
  was core-internal, so this is not a contract break, and the four core call
  sites moved with it.

<a id="docsoverlay-contractmd-says-why-the-examples-test-plugin-list-names-a-core"></a>

- **`docs/overlay-contract.md` says why the example's `:test` plugin list names
  a core fixture.** `projects/example/project.exs` restates
  `KilnCMS.FixturePlugin` because `:plugins` *replaces* rather than merges and
  `config/project.exs` is imported last — an artifact of the example living in
  the core's repo, not a pattern a real overlay should copy. The "Not covered"
  entry now says both halves.
  probed rather than declared, and the hand-rolled `@behaviour` path breaks on
  callback additions. Linked from `projects/README.md` (which keeps the
  mechanics) and the getting-started guide router (#1328).

<a id="the-configure-sidebar-is-sections-and-k-finds-settings-screens"></a>

- **The Configure sidebar is sections, and ⌘K finds settings screens.** The
  admin half of the console nav now sits in collapsible sections — Content
  model, Capture, Delivery, Integrations, Organization, Account — with
  **Operations** ruled off below them for the instance-wide screens a platform
  admin owns (Team, Accounts, Billing, Mail, API keys, Backups, System). Every item in
  that band is platform-gated, so an org admin sees no band at all. Which
  sections are collapsed is remembered per browser, like the icon rail, and is
  ignored in the rail itself. The ⌘K palette gained a **Go to** category ahead
  of the content results, searching the same list the sidebar and the hub
  draw — by name, section, description and keyword, already filtered to what
  you may open — so "backups" or "dkim" is one keystroke from the screen rather
  than a scan down 25 items. The per-user screen is now labelled **Your
  settings** under an **Account** heading, so nothing named "Settings" looks
  like it holds the site's configuration, and the System screen no longer
  describes itself as "the Kiln core this instance is built from" (#1319).

<a id="changelogmd-is-a-summary-and-the-reasoning-moved-to-docschangelog-and"></a>

- **`CHANGELOG.md` is a summary, and the reasoning moved to
  `docs/changelog/` and `docs/decisions/`** (#1325). The file had reached 5,142
  lines across six releases, with entries written as design essays — one
  Unreleased security bullet ran thirty lines of threat-model prose. That is
  the wrong shape for the one moment it has to work: `mix kiln.update` shows it
  to an operator about to move a production pin, who is asking "what breaks if
  I upgrade?".

  Each release entry is now one line per change under **Upgrade notes**,
  **Breaking**, **Added**, **Changed**, **Fixed**, **Security** and
  **Removed** — 1,038 lines in total. Every line links to the pull request that
  shipped it and, where it was shortened, to its own long-form entry under
  `docs/changelog/`, which carries the original prose verbatim. Ten entries
  that argue a choice outliving their release became architecture decision
  records under `docs/decisions/`.

  New `mix kiln.changelog` does the work and keeps doing it. `--condense` moves
  the long form out and is idempotent, so it is a step in `docs/releasing.md`
  rather than a one-off migration; `--verify REF` proves, paragraph by
  paragraph, that nothing was dropped; `--check` runs in `mix precommit` and CI,
  holding Unreleased entries to three lines and failing on an entry with
  nowhere to link.

  `mix kiln.update` now prints only the **Upgrade notes** and **Breaking**
  sections between the two pins, with their long-form links rewritten to
  absolute URLs at the target tag. It still reads the `### Upgrading` spelling
  every release up to 0.8.0 used, since it reads the changelog at the tag being
  installed.

## Fixed

<a id="mix-docs-view-source-links-point-at-the-release-tag-not-main"></a>

- **`mix docs` "View Source" links point at the release tag, not `main`.**
  `source_ref` was pinned to the branch, so every link in a published build
  kept re-resolving as `main` moved and would eventually land on a shifted line
  or a deleted function. It now defaults to `v<version>` from `mix.exs`, which
  the release commit bumps to match the tag. A build from an untagged `main`
  can pin itself with `DOCS_SOURCE_REF=$(git rev-parse HEAD) mix docs`.

<a id="a-md-file-that-opens-with-an-html-comment-keeps-its-title"></a>

- **A `.md` file that opens with an HTML comment keeps its title.** A license
  or editing note above the leading `# H1` — a common shape for an imported
  file — sat in front of the heading in the parsed tree, so
  `KilnCMS.Markdown.parse_document/2` stopped recognizing it as the document's
  title: the import arrived untitled *and* with the heading still in the body,
  which then printed the name twice.

<a id="the-content-cache-metric-no-longer-inverts-during-a-stampede-and-a-courier"></a>

- **The content-cache metric no longer inverts during a stampede, and a Courier
  failure no longer amplifies one.** A burst of concurrent requests for one
  just-invalidated key is deduplicated by Cachex into a single database read,
  but every deduplicated caller was counted as a cache **hit** — so the worse
  the stampede, the healthier `[:kiln_cms, :cache, :content]` looked. Those
  callers are now tagged `coalesced`, distinct from a genuine `hit`. Separately,
  when Cachex answers a fetch with an error (its courier worker died, or the
  fallback itself raised), every blocked caller fell through to a silent
  per-caller recompute — N simultaneous rebuilds, N sitemap rebuilds on the
  generic helper, exactly the stampede the cache exists to prevent. The most
  common form of that — a fallback raising, which on the delivery path is just a
  404 — now runs once for the whole burst and hands every waiting caller the
  original exception, so a missing hot URL costs one database read instead of
  one per request. What is left in that arm is the cache itself failing, where
  the caller still computes (a dead courier must not take the site down) but the
  degrade is logged and tagged `error` so it is visible while it happens.

<a id="an-arrow-key-can-no-longer-walk-a-calendar-chip-off-the-grid-it-is-drawn-on"></a>

- **An arrow key can no longer walk a calendar chip off the grid it is drawn
  on.** On the editorial calendar, `ArrowDown` from the last row of a month
  that ends on a Sunday — or either vertical key in week view, whose grid is a
  single row — moved the chip to a day the rendered window does not cover. The
  move was written and announced, and then the re-query drew a calendar the
  chip is not in: it vanished, with nothing on screen saying where it went. The
  server now refuses a target outside the window it is rendering and says so,
  the way it already refuses a move into the past. Dragging could never reach
  this state — every drop target is a cell on screen — so this was the keyboard
  path only (#1384).

<a id="an-html-comment-in-imported-markdown-is-no-longer-published-as-prose"></a>

- **An HTML comment in imported Markdown is no longer published as prose.**
  `<!-- a note to whoever edits this file -->` standing on its own between
  paragraphs came through `KilnCMS.Markdown` as a visible paragraph — earmark
  hands a block comment back tagged with the atom `:comment`, which matched
  none of the renderer's tag lists and fell through to the clause that keeps a
  node's text. Affected `.md` import, Markdown pasted into a rich-text block,
  and the `body_markdown` write argument. A comment written mid-sentence was
  already dropped by the sanitizer, and one inside a fenced code block is the
  example, so it still survives.

<a id="links-to-a-readmemd-from-a-guide-pointed-at-the-wrong-readme"></a>

- **Links to a `README.md` from a guide pointed at the wrong README.** ExDoc
  resolves a relative link between extras by basename alone, taking whichever
  extra with that basename was registered last — so `[Overview](../README.md)`
  in `docs/getting-started.md`, and ten links like it, rendered in the published
  docs as links to the Elixir client's README. `mix docs --warnings-as-errors`
  warns only when a basename is missing entirely, never when it resolves to the
  wrong page, so the docs job was green throughout. Every link to a README is
  now its full github.com URL, correct in both renderings, and
  `test/kiln_cms/docs/extras_links_test.exs` fails the build if a relative link
  between extras renders as a link to a different file than the one it names.

<a id="both-password-forms-check-the-confirmation-as-you-type"></a>

- **Both password forms check the confirmation as you type.** On `/register`
  and on the new-password page behind a reset link, the two password boxes
  disagreeing was held back until submit — which on registration also clears the
  password field, so a typo in the confirmation cost re-typing both.
  `KilnCMSWeb.AuthConfirmationFeedback` reveals that one error on `phx-change`;
  every other field — an empty email, an invalid reset token — stays quiet until
  submit, as before.

<a id="the-new-password-button-says-change-password"></a>

- **The new-password button says "Change password".** The button on the page
  behind a reset link read "Reset password with token" — the name of the Ash
  action, humanized, on the same button that then said "Changing password ..."
  while it worked. `KilnCMSWeb.AuthOverrides` had asked for the right wording
  since it was written, but `AshAuthentication.Phoenix.Components.Reset.Form`
  declares no `button_text`, and a setting naming a key its component does not
  declare compiles and is then read by nothing. Kiln's own form component
  declares it. A new test checks every setting in that file the same way, so the
  next one that lands on a key upstream renamed fails instead of going quiet.

## Security

<a id="a-system-actor-so-internal-callers-run-under-the-policies-instead-of-around-them"></a>

- **A system actor, so internal callers run under the policies instead of
  around them.** `%KilnCMS.SystemActor{}` and the `KilnCMS.Checks.SystemActor`
  policy check replace `authorize?: false` for workers, jobs and other trusted
  internal code: the grant is declared in the resource's `policies` block and
  listed in `docs/policy-matrix.md` (a test fails the build if a resource
  admits the actor without a row there), and it is admitted with `authorize_if`
  rather than `bypass`, so a policy added to the resource later still applies.
  The first resource converted is `Firing.ReferenceEdge` — the re-fire wave's
  link graph, which has no caller-facing write path at all. No behaviour
  changes for any caller-facing path (#1402).

<a id="the-firing-path-runs-under-the-policies"></a>

- **The firing path runs under the policies.** Everything `KilnCMS.Firing.*`
  touches now carries `%KilnCMS.SystemActor{}` and a matching policy clause
  instead of `authorize?: false`: the artifact table (written only by the
  engine, destroyed only by unpublish), the reference graph, the type and
  field definitions it reads, and the one system-only content action that
  recomputes `search_text`. Two reads deliberately keep their bypass, and now
  say why — a system clause on the `Content` read policy would be a standing
  grant over the whole corpus, much wider than the call it would replace.
  `mix kiln.authz.check` gates `lib/kiln_cms/firing/` from here on (#1402).

<a id="the-semantic-index-runs-under-its-policies"></a>

- **The semantic index runs under its policies.** `Search.BlockEmbedding` and
  `Search.TagEmbedding` — internal indexes with no caller-facing write path —
  admit `%KilnCMS.SystemActor{}` by name, so the indexer, `BlockSearch` and
  `Search.Related` no longer bypass them; the document-level `:set_embedding`
  vector write joins `:reindex_search_text` as the second system-only content
  action named in the content resources' own create/update policy. Two tag
  reads turn out to need no bypass at all
  (taxonomy is world-readable). The workers' *document* reads keep theirs, and
  say why. `mix kiln.authz.check` now also gates `lib/kiln_cms/search/`
  (#1402).

<a id="editorial-automation-runs-under-the-policies"></a>

- **Editorial automation runs under the policies.** `KilnCMS.Automation.RuleWorker`
  carries `%KilnCMS.SystemActor{}`: `Automation.Rule` and `Social.Account`
  admit it for **reads only** (authoring a rule, and the credentials for a
  site's public voice, stay admin acts), and `CMS.Comment` / `CMS.Task` admit
  it for create and read but **not** update — automation posts findings and
  opens tasks, it does not edit what anyone said or close their work. The
  content and user lookups keep their bypass, and now say why.
  `mix kiln.authz.check` now also gates `lib/kiln_cms/automation/` (#1402).

<a id="billing-and-the-newsletter-tier-sync-run-under-the-policies"></a>

- **Billing and the newsletter tier sync run under the policies.** The last two
  of the four modules #1329 audited: `Billing.Settings` (read and first-use
  init only — the write path to payment credentials stays platform-admin),
  `Billing.Membership` and `Billing.MembershipEvent` (the provider-state,
  append and GDPR-erasure actions that are `forbid_if always()` for every
  person, admin included), and `Newsletter.Segment` / `Subscriber` /
  `SegmentMembership` for the tier-backed lifecycle. The one caller that may
  take those actions is now named in each policy block instead of reaching
  around it. The `Accounts.User` lookups keep their bypass, and say why
  (#1402).

<a id="mix-kilnauthzcheck-now-gates-all-of-lib"></a>

- **`mix kiln.authz.check` now gates all of `lib/`.** It was the web layer
  only; every file is checked from here on, with the pre-existing unexplained
  bypasses recorded per file in the task's `@backlog` — 129 files, 313 sites.
  That list is a ratchet: a file with no entry must be clean, so **new code is
  gated from the day it lands**; a listed file may not gain a site; and a
  listed file that loses one fails too, with the number to write, so the
  allowance can never drift out of date. Nothing may be added to it, and
  emptying it finishes #1402.

