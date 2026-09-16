# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="sidebar-presets-essentials-and-everything-upgrading"></a>

**Upgrading:** the migration adds the column with a default of `everything`
(so every existing account is backfilled to the sidebar it already had) and
then changes the column default to `essentials`, which is also the
resource's create-time default. Nobody who already knows where Menus is
finds it gone after an upgrade. Accounts created by the seeds after the
migration (the demo admin and editor) start on Essentials.

## Added

<a id="media-sideloading-can-be-tested-without-the-network"></a>

- **Media sideloading can be tested without the network.** `Media.Ingest.store_url/2`
  — the fetch the WordPress importer points at every attachment URL in an
  uploaded export (#487), and so the most content-chosen request the system
  makes — called `SafeFetch.get/2` with no `req_options`. Every comparable
  module takes one from config (`Webhooks`, `OEmbed`, `Federation`,
  `Links.External`, `Storage.S3`, `Social`, `Push`), so this was the one fetch
  that could not be pointed at a `Req.Test` stub, and everything past its SSRF
  refusals had never run in a test. `Ingest.req_options/0` follows the same
  shape and is merged by `SafeFetch` after its own options, so address pinning
  and redirect refusal still apply to a stubbed request. The new tests pin what
  Ingest does with each answer: a stored image named after the URL's last
  segment (percent-decoded, since editors search by it), a non-2xx reported as
  `{:http_status, status}` with nothing stored, a transport failure returned as
  an error rather than raised, and a `302` pointing at the cloud metadata
  address producing exactly one request — never a followed second one. Two
  importer tests that had been getting their "unreachable image" from a real
  connection attempt now stub the 404 instead, and the reachable case — an
  imported post's image block re-pointed at the stored item — has a test for
  the first time. With the stub configured, a test that lets media through
  without installing one fails loudly instead of dialling out.

<a id="sidebar-presets-essentials-and-everything"></a>

- **Sidebar presets: Essentials and Everything.** A usability pass on
  kilncms.dev found a platform admin's sidebar listing 38 items, most of them
  screens a writer opens a few times a year. Each user now picks a sidebar
  preset (`User.nav_preset`, stored server-side, so it follows them across
  devices and the first paint is already right). **Essentials** lists Home,
  Content, Media, Calendar, Tasks and Inbox, then the Configure hub for an
  admin and Your settings. **Everything** is the sidebar as it was. Only the
  sidebar filters (`KilnCMSWeb.ConsoleNav.sidebar/3`): the Configure hub and
  the ⌘K palette still read the full map, and the page you are on is drawn
  even when the preset would hide it. Switch with "Show all tools" / "Show
  essentials" at the foot of the sidebar or on Your settings. Either redraws
  the sidebar in place through the self-only `:set_nav_preset` action.

  Also: `/editor/settings` is titled **Your settings**, as the nav already
  named it, and "site settings" in ⌘K now finds the Configure hub first.

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

<a id="the-editor-says-when-a-headings-link-gets-a-number"></a>

- **The editor says when a heading's `#link` gets a number.** Public pages give
  every heading a GitHub-style id (#1439), and a heading whose slug is already
  taken — by an earlier heading with the same words, or by an id the page
  layout owns, such as `<main id="main">` — is numbered (`#main-1`), so a page
  never carries a duplicate id. `KilnCMS.HeadingAnchors.reserved_ids/0` names
  the layout's ids, and a controller test renders a public page and fails if
  the layout grows one the list doesn't. The SEO panel now reports each heading
  whose link isn't its plain slug, with the link it really has and a jump to
  it, so an author sharing a section link copies the right one.

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

<a id="a-notification-bell-in-the-console-top-bar-on-every-editor-page-an-unread-badge"></a>

- **A notification bell in the console top bar**, on every `/editor/*` page:
  an unread badge (capped at `8+`, with the real number in its accessible
  label), a dropdown of the eight most recent items — read ones included, since
  a list that empties itself takes each item's deep link with it — and
  mark-all-read. PubSub-driven: the badge moves when a notification arrives or
  is read elsewhere, without a reload. Clicking an item marks it read and
  navigates to the block, comment or task it concerns.

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

<a id="the-editor-opens-on-the-title-and-the-canvas"></a>

- **The editor opens on the title and the canvas.** A usability pass found
  writers met a Slug field, a URL line, SEO hints, a Path alias field with a
  paragraph of routing help and a redirects list before reaching the first
  block. Those are settings of the document, not its writing, so they now live
  in a **URL** section at the top of the inspector's Settings tab. Under the
  title a compact line shows the live address with an **Edit URL** button that
  opens Settings and focuses the slug. The inputs are still part of the editor
  form: auto-derived slugs, autosave and field locks work as before. A slug or
  path-alias error marks the Settings tab and the line under the title, and a
  save refused on either opens Settings → URL on the field instead of saying
  "fix the errors below" about a field that is off screen.

<a id="home-says-what-the-site-holds-asks-how-you-publish-and-doesnt-alarm-on-day-one"></a>

- **Home says what the site holds, asks how you publish, and doesn't alarm on
  day one.** Three findings from a live usability pass on kilncms.dev. The line
  under the Home heading was a tagline ("What needs you next — then eight
  domains around your content"); it is now the site's status in numbers every
  reader of the page may see — "71 published · 1 draft · 3 media items",
  pluralised, with "in review" only when something is. A seeded deploy never
  sees `/setup`, so nobody was ever asked who publishes and the console kept the
  newsroom default (editors submit for review); an admin of a site with no
  editorial-settings row now gets a one-time **How do you publish?** card —
  "Just me" lets editors publish, "I have a team" keeps review — written through
  the same save and OrgAdmin policy as Team's switch, and gone for good once any
  answer is recorded (`KilnCMS.CMS.EditorialSettings.chosen?/1`; the publish
  check's fail-closed read is unchanged). And a deployment where no backup was
  ever recorded now shows a neutral "Backups aren't set up yet" notice rather
  than the red alarm; a failed backup, or one that went stale, is still the
  alarm, and `KilnCMS.Backups.stale?/1` still counts "never" as stale.

<a id="the-ml-stack-behind-semantic-search-is-now-opt-in-kilnml1"></a>

- **The ML stack behind semantic search is now opt-in (`KILN_ML=1`).** A first
  `mix setup` fetched 773 MB of dependencies, 666 MB of it `deps/exla`, to back
  semantic search — which ships disabled. Bumblebee, Nx and EXLA now stay out of
  the dependency tree unless `KILN_ML` is set, taking a default `deps/` to
  102 MB and saving a one-time 110 MB archive download; `mix setup` prints one
  line saying so.

  Nothing is removed. `KilnCMS.Search.Embedder.Bumblebee` and
  `KilnCMS.Search.Reranker.Bumblebee` still exist and return
  `{:error, %KilnCMS.Search.ML.NotCompiledError{}}` in a lean build, so hybrid
  search falls back to its keyword legs and every caller's existing error
  handling covers it. A deployment that has set `semantic: true` is warned once
  at boot that its build cannot serve it.

  **Upgrading:** a deployment already running semantic search must build with
  `KILN_ML=1` — `KILN_ML=1 mix deps.get && KILN_ML=1 mix compile` — and keep the
  variable set for every `mix` invocation, including in its image build.
  Nothing in the database or configuration changes. Contributors touching the
  semantic path should read the `KILN_ML` note in `CONTRIBUTING.md`: a lean
  build compiles a different shape of those modules.

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
  missed sweep cannot leave anyone elevated. A loaded `role` is always the
  standing tier; every tier decision (`Checks.PlatformAdmin`,
  `Scoping.effective_tier/2`) applies a live grant through
  `RoleGrant.effective_role/1` at the moment it decides. An hourly AshOban sweep clears expired columns and drops the holder's live
  sockets. Grants are elevations only, and carry no scope axes. The window is one
  of five offered durations or an explicit UTC datetime.

<a id="admin-initiated-password-resets"></a>

- **Admin-initiated password resets.** `Accounts.send_user_password_reset/2`
  mails a named account a reset link and reports whether it went — which the
  anonymous form deliberately cannot, since it must stay indistinguishable for
  addresses that don't exist. It charges the per-address mail budget once and
  refuses by name when the budget is spent, rather than reporting "sent" for mail
  the sender would drop. "Sent" means the mail was queued. Erased accounts are
  refused.

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

<a id="mix-kiln-changelog-verify-no-longer-reports-a-loss-for-a-credited-pull-request"></a>

- **`mix kiln.changelog --verify` no longer reports a loss for a pull request
  `--condense` credited.** `docs/releasing.md` runs `--condense` and then
  `--verify`, and on `main` that failed with eight `MISSING:` paragraphs. Each
  was a summary condensed before its merge had a number: the next `--condense`
  found the pull request in git history and wrote it into the links line beside
  the long-form link, `([long form](…))` becoming `([#1496](…) · [long
  form](…))`. `--verify` drops link targets but kept link text, so the old
  `([long form])` no longer appeared anywhere and the summary read as lost.
  `--verify` now strips the links line — and an author's bare `(#1234)` — before
  comparing, the same way `--check` and `--condense` already do. Only a
  parenthetical made entirely of `#1234` and `long form` links is removed, so a
  sentence dropped from a summary or a long form is still a loss.

<a id="mix-kiln-changelog-condense-no-longer-breaks-on-a-shared-long-form"></a>

- **`mix kiln.changelog --condense` no longer breaks on a release where two
  summaries link one long form.** Under `## [Unreleased]`, the **Upgrade
  notes** entry for the sidebar presets pointed at the same archive anchor as
  the **Added** entry that introduced them. The archive holds one block under
  an anchor, so `--condense` handed that block to both summaries and wrote it
  out under both sections — and every run after that read an archive with two
  blocks under one `<a id>` and stopped. `--check` was green throughout,
  because it only ever looked at the archive on disk, so the failure landed on
  whoever condensed next, in a file they had not touched by hand. The upgrade
  note now has an anchor and a long form of its own (the `**Upgrading:**`
  paragraph about the column default, which is what an operator moving a pin
  is being sent to read), and `--check` fails a release whose summaries name
  one long form twice — where the fix is still one link to rename rather than
  an archive to unpick (#333).

<a id="a-menu-items-edit-form-no-longer-shares-input-ids-with-the-add-form"></a>

- **A menu item's Edit form no longer shares input ids with the Add form.**
  The "Add an item" card is always on the menu builder, and the inline Edit
  form was built from the same `item` params with no id prefix, so opening
  Edit rendered two `id="item_label"` inputs (and two of every other field).
  Clicking an Edit label focused the Add form's input, and LiveView's DOM
  patching could target the wrong element. The Edit form now keeps the
  `item[...]` param names but prefixes its ids with the item
  (`edit_item_<id>_label`), both when it opens and when a refused save
  re-renders it. This also removes an intermittent CI failure: LiveViewTest
  reports a duplicate id by messaging its own proxy after replying, so the
  existing Edit test only failed when the proxy got scheduled before the test
  exited.

<a id="editing-a-live-pages-body-no-longer-blanks-its-title"></a>

- **Editing a live page's body no longer blanks its title or strands the change
  in the working copy.** On a published document the editor autosaves the text
  into the working copy (docs/working-copy.md), which is written as a whole:
  both columns go out on every save. The params it submitted came from
  `AshPhoenix.Form.params/1`, which round-trips only *touched* fields — and the
  form is rebuilt from the record after every write, so it starts each round
  untouched. An edit that did not arrive through the form's own change event —
  the TipTap hook pushing a rich-text body, a media pick, any block operation —
  therefore submitted `blocks` with no `title` at all, and the absent param
  landed as an explicit `nil`. Two things followed: the title input went blank
  (the editor renders the working view of the row), and "Publish changes" then
  failed for good, because promoting the copy moved that `nil` onto a `title`
  the row will not accept — the body saved to the draft and never reached the
  live site, while the settings that save straight through `:update` kept
  publishing normally. An absent param now means *unchanged* on this path, and
  the throwaway form no longer pre-loads the basis title onto the struct it
  builds on: Ash drops a change whose value already equals the changeset's
  data, so a title submitted unchanged was dropped against that doctored struct
  and never written. A failed "Publish changes" also names the field that
  refused it instead of the blanket "That action isn't allowed right now."

<a id="notification-bell-and-inbox-fixes-from-review"></a>

- **Notification bell and inbox fixes from review.** A review of the
  notification centre (#1320) found real defects, now fixed:
  - **Clicking a bell item never marked it read.** LiveView's client swaps the
    page for a `navigate` link before running its `phx-click`, so the
    component's event had no target (LiveViewTest still passed). Items are
    buttons that mark read and then `push_navigate`; they carry
    `data-guard-nav`, which the editor's unsaved-changes confirm now covers.
  - **Notifications on dynamic content types linked nowhere.** `Entry` exports
    no `__kiln_content_type__`, so rows stored `"content"` and every channel
    linked `/editor/content/content/:id`; the type's own name now comes from the
    registry.
  - **Erasure left the actor's name in other people's inboxes.** Rows now record
    `actor_id` (new nullable column), and `anonymize_user` blanks
    `actor_name`/`actor_id` on every row that account caused.
  - Mark-read in the bell and inbox passes the tenant (a strict-tenancy build
    made every click a silent no-op); "Mark all read" announces once rather than
    per row and reports a failure instead of "Marked 0"; the bell re-reads on a
    refresh rather than on every console render; the inbox loads once per mount;
    a task on an unknown content type still emails and fires `task.assigned`;
    and a raise dispatching a workflow notification after the write committed
    is logged rather than crashing the caller.

<a id="five-editor-console-rough-edges-a-first-time-user-hit"></a>

- **Five editor-console rough edges a first-time user hit.** The path-alias
  field's placeholder (`/products/shoes/size/42`) read like a live address;
  it is now an obvious example, and the help text says to leave it blank to
  use the slug. The "N a11y issues" chip switched the inspector to Settings but
  left the Accessibility section six panels down, off screen; it now scrolls
  to that section and moves focus there. A crowded month cell's "+N more" was
  plain text; it links to the week holding that day, keeping the filters. The
  Team page listed only site memberships, so an admin created by `/setup`
  (admin by account role, no membership) was missing and a fresh install read
  "Members (0)"; site admins are now listed and counted, labelled "Site admin",
  with no site-tier controls that would not apply to them. And info flashes
  such as "You are now signed in" close after five seconds (paused while
  hovered or focused); error flashes still wait to be closed.

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

<a id="the-console-sidebar-no-longer-slides-in-with-its-labels-cropped"></a>

- **The console sidebar no longer slides in with its labels cropped.** A
  usability pass saw "Home" read "me" and "KilnCMS" read "CMS". The sidebar's
  `transition-transform` exists for the mobile drawer but ran on desktop too, so
  a window crossing 64rem (a resize, a snap, a zoom) slid the rail in from
  off-canvas for ~150ms. It now animates only as a drawer. The same pass found
  the content column was a bare `1fr`, which never shrinks below its content's
  min-content width: one long `<pre>` or wide table scrolled the whole console
  sideways even when that element scrolls itself. The column is
  `minmax(0, 1fr)` now. A Playwright spec pins both, and fails without the fix.

<a id="with-every-write-anchoring-on-a-system-actor-write-no-longer-crashes-in"></a>

- **With every-write anchoring on, a system-actor write no longer crashes in
  `AnchorVersion`; its anchor is attributed to `actor_id: nil`.**
  ([#1402](https://github.com/The-Verscienta/kiln_cms/issues/1402), [#910](https://github.com/The-Verscienta/kiln_cms/issues/910))

<a id="developers-no-longer-links-to-a-swagger-ui-and-openapi-spec-that-404"></a>

- **`/developers` no longer links to a Swagger UI and OpenAPI spec that 404,
  and the GraphiQL playground is reachable in dev again.** Production turns
  `:api_docs` off, so the page now shows those links only when
  `API_DOCS_ENABLED` serves them. The dev-only `/gql/playground` forward was
  declared after the `/gql` catch-all and never matched; it now comes first.

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

<a id="firing-no-longer-fails-or-mints-an-unattributed-anchor-with-every-write"></a>

- **Firing no longer fails, or mints an unattributed anchor, with every-write anchoring on.**
  `:reindex_search_text` is skipped by `AnchorVersion` as PaperTrail already skips it.
  ([#910](https://github.com/The-Verscienta/kiln_cms/issues/910))

