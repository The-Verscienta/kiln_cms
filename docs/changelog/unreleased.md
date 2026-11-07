# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="builtin-field-type-names-upgrade"></a>

- **The field type names `email`, `telephone`, `color`, `slug`, `time` and `json` are reserved (#2278).**
  Kiln now ships a built-in type under each name (see
  [Built-in format types](../extending-content.md#built-in-format-types)), and
  a name can be registered only once.
  - **Overlays and plugins.** A `Kiln.FieldType` that registers one of these
    names must be renamed, in the module's `name/0` and in any stored
    `FieldDefinition.field_type`. `mix kiln.plugins.doctor` fails with *collides
    with a built-in field type* until you do.
  - **Stored definitions.** A `FieldDefinition` whose `field_type` already
    holds one of these names is now cast by the built-in type, not yours.
    Values that do not pass its check (a malformed address, a domestic phone
    number) are refused the next time that record is saved; stored values are
    not rewritten. If the data matters, rename your type and migrate the
    definitions before upgrading.
  - **Rolling back.** No migration. Rolling the pin back restores the old
    type; values saved meanwhile in the built-in's tidied form (a lowercased
    domain, `+442079460958`) stay as stored.

<a id="backup-history-upgrade"></a>

- **Run `mix ash.migrate` for the backup history, and add `KilnCMS.Backups` to
  an overlay's `:ash_domains` (#2217).** The migration
  (`20261107205448_add_backup_runs`) creates one table, `backup_runs`. It is
  expand-only and changes no existing data, so rolling the pin back is safe;
  the table is simply unused.
  - **Overlays that restate `:ash_domains`.** `KilnCMS.Backups` is now an Ash
    domain (it was a plain module). `:ash_domains` replaces rather than merges,
    so an overlay's `config/project.exs` that lists the core domains must add
    `KilnCMS.Backups` (next to `KilnCMS.Billing`), as
    `projects/example/project.exs` now does. Without it the resource sits
    outside every configured domain and `mix ash.codegen` offers to drop the
    `backup_runs` table. See [the overlay contract](../overlay-contract.md).
  - **Nothing else to set.** No new environment variables; `manifest.json`,
    `Backups.status/0` and the overview strip are unchanged, so cron-based
    deployments keep working untouched.
  ([#2217](https://github.com/The-Verscienta/kiln_cms/issues/2217))

<a id="breached-password-upgrade"></a>

- **Run `mix ash.migrate` for the breached-password check, and decide whether
  your deployment may call a third party (#2240).** The migration
  (`20261107194057_add_site_password_policy`) creates one table,
  `site_password_policy` (one row per organization, created lazily when an
  admin saves the setting). It is expand-only and changes no existing data, so
  rolling the pin back is safe; the table is simply unused.
  - **New outbound call, on by default.** Setting a password (register, change,
    reset, first-run setup) now sends the first five characters of the
    password's SHA-1 hash to `api.pwnedpasswords.com`. The password, the full
    hash and the account never leave the server. If the service is slow or
    down, the password is accepted.
  - **Air-gapped or no-egress deployments.** Set `BREACHED_PASSWORD_CHECK=false`
    to make no call at all. Firewalls that allow only listed hosts should allow
    `api.pwnedpasswords.com:443` instead, or the check quietly does nothing
    (it fails open, logging a warning and emitting the telemetry event).
  - **Overlays.** Run `mix ash.codegen` only if your overlay adds its own
    resources; core's migration ships the table. See also the Breaking entry
    for `Bootstrap.create_first_admin/1`.
  ([#2240](https://github.com/The-Verscienta/kiln_cms/issues/2240))

<a id="reject-invalid-bearer-default-on"></a>

- **An unverifiable bearer token is a `401` by default (#2161).** The
  previous release added `KILN_API_REJECT_INVALID_BEARER`, off; this one turns
  it on, as [ADR 0012](../decisions/0012-headless-services-get-a-draft-write-api-key-scope-not-oidc-pass-through.md)
  committed to. An `Authorization: Bearer …` header whose JWT does not verify
  (garbled, expired, or signed by another instance) is now answered `401` with
  the standard error envelope (`code: "invalid_token"`) and
  `WWW-Authenticate: Bearer error="invalid_token"` on `/api/json`, `/gql` and
  the other `/api` routes. Before, it was served as anonymous: the client got
  `200` and public content, and took that for success.
  - **Who notices.** Only a consumer that sends a bearer token that does not
    verify. A request with no `Authorization` header, or another scheme, is
    still anonymous. A valid JWT and a valid `kiln_` API key are unchanged, and
    a bad `kiln_` key was already a `401`.
  - **What to do.** Before upgrading, look for clients that send a token they
    never refresh: a static site build or a mobile app holding an old JWT, or
    one built against another instance's secret. Have them sign in again, or
    move them to an API key, or send no `Authorization` header when they mean
    to read as the public. Turning the flag on in the previous release
    (`KILN_API_REJECT_INVALID_BEARER=true`) shows the same `401`s ahead of time.
  - **Opting out, for one release.** `KILN_API_REJECT_INVALID_BEARER=false`
    restores the anonymous fallback. The variable is removed in the next
    release, after which an unverifiable bearer is always a `401`; use it only
    to buy time while you fix the client.
  - Unset now means on. Nothing to migrate and no config to change if your
    clients send valid tokens or none.

<a id="search-name-lexemes-upgrade"></a>

- **Content tables gain `name_lexemes`, a generated column; overlays run
  `mix ash.codegen` to add it to their own content types.** The column is
  `GENERATED ALWAYS … STORED` from `search_weighted`, so the migration
  fills it for every existing row and Postgres keeps it current on every
  write. Adding a stored generated column rewrites the table under an
  exclusive lock: seconds for a catalogue of a few thousand rows, longer for
  a very large table. Until an overlay's own types have the column, their
  alias and compound legs answer empty and log why, so generate and migrate
  before deploying. No re-fire is needed: a row written before 1.8, with no
  `search_weighted`, still takes the full match.

<a id="reporting-views-upgrade"></a>

- **Overlays: run `mix ash.codegen` and commit the migration; existing content
  types gain the reporting views.** The reporting views (below) are created
  by `use KilnCMS.CMS.Content`, so a project's own `mix kiln.gen.content` types
  show codegen drift on the first release that has them. Run `mix ash.codegen`,
  review and commit the migration it writes, and deploy it with the update.
  Until then those types have no views; nothing else is affected. The
  migration is additive (a schema, and two views per content table) and
  rolling the pin back leaves them in place, unused. Core's own views arrive
  by core's migration with nothing to do. A BI role made earlier does not exist
  yet; when you create one (`mix kiln.reporting.sql`), re-run its `GRANT` lines
  after every upgrade that adds views, and after a demo reset.


<a id="custom-fields-gin-upgrade"></a>

- **Content tables gain a GIN index on `custom_fields`, built concurrently;
  overlays run `mix ash.codegen` to add it to their own content types.** The
  migration builds `pages_custom_fields_gin_index`,
  `posts_custom_fields_gin_index` and `entries_custom_fields_gin_index` with
  `CREATE INDEX CONCURRENTLY`, so writes continue during the build, but the
  build reads the whole table and can run for a long time on a large
  `entries`. Plan for it as a slow migration, not a hang, and do not kill the
  deploy halfway. If a build fails or is interrupted, Postgres leaves an
  `INVALID` index behind that is maintained on every write but never used.
  Find it with `SELECT indexrelid::regclass FROM pg_index WHERE NOT
  indisvalid;`, drop it with `DROP INDEX CONCURRENTLY <name>;`, and run
  `mix ash.migrate` (or your release's migrate command) again. Each index is
  roughly 26% of its table's size. The change is additive and safe to roll
  back: the previous release ignores the indexes, and the migration's `down`
  drops them. See [Custom fields](../json-api.md#which-custom-filters-use-an-index).

<a id="robots-flags-upgrade"></a>

- **Content tables gain `noindex` and `nofollow`; `type_definitions` gains
  `noindex_default` and `nofollow_default`. Overlays run `mix ash.codegen` for
  their own content types.** All four are `boolean NOT NULL DEFAULT false`, so
  the migrations are expand-only: the previous release ignores the columns and
  gets `false` on insert. No re-fire is needed.

<a id="field-validation-upgrade"></a>

- **Field definitions gain a `validation` column (#2276).** `field_definitions.validation` is `jsonb NOT NULL DEFAULT '{}'`: additive, instant, and every existing field starts with no constraints, so nothing about stored data or writes changes until an admin sets one. Rolling the pin back is safe (the old release ignores the column). Overlays that carry their own migrations run `mix ash.codegen` and commit the result.
  - **Unique is not a database constraint.** Once an admin marks a field `unique`, the write path enforces it; raw SQL and a database restore bypass it. Run `mix kiln.fields.duplicates` (read-only, exits non-zero on repeats) after bulk imports or restores.

## Breaking

<a id="breached-password-bootstrap-return"></a>

- **`KilnCMS.Accounts.Bootstrap.create_first_admin/1` returns `{:ok, user, notices}` (#2240).**
  `notices` is `[:password_breach]` when the typed password is in a known
  breach and the site's policy allowed it, `[]` otherwise. Before it returned
  `{:ok, user}`. The core `/setup` wizard is updated; an overlay or script that
  matches `{:ok, user}` on this call must match the three-tuple. The error
  returns (`{:error, :already_bootstrapped}`, `{:error, changeset_error}`)
  are unchanged. The breach lookup now happens before the advisory-locked
  transaction, so the lock is never held while waiting on the third party.
  ([#2240](https://github.com/The-Verscienta/kiln_cms/issues/2240))

## Added

<a id="builtin-format-field-types"></a>

- **Six built-in custom field types check and tidy a value: `:email`, `:telephone`, `:color`, `:slug`, `:time` and `:json` (#2278).**
  An editor can no longer save a malformed address, colour or time, and an
  API client or import gets the same check. Admins pick them in the fields
  admin like any type. Guide: [Built-in format types](../extending-content.md#built-in-format-types).
  - `:email`: shape check, domain lowercased. `:telephone`: a *format* check
    only, stored as E.164; it requires a leading `+` (or `00`) and refuses
    domestic numbers and extensions. `:color`: `#rgb`/`#rrggbb`, stored
    lowercase `#rrggbb`; a text input rather than `type="color"`, so an
    optional field can stay empty. `:slug`: slugified text, with no uniqueness
    check and no auto-fill (use `:computed`; uniqueness waits on #2276).
    `:time`: `HH:MM`, no date or zone.
  - **Lists.** Email, telephone, color, slug and time fields appear in the
    content list's Columns picker, filter (email/telephone/slug: Is, Contains,
    Empty or not; color: Is, Empty or not; time: Is, From, Until, Empty or not)
    and sort. Condition values are tidied the way the field tidies a saved
    value.
  - **`:json`.** An object or array, edited in a monospace textarea. It is
    filterable only for "Empty or not", not sortable, and not in the Columns
    picker, but a `searchable` flag indexes the strings and numbers nested in
    it (not the keys). Limits: 256 KB of input, 64 KB re-encoded, depth 32,
    5,000 values; NUL is refused.
  - **Not yet.** A key/value or link type, number options (step, prefix,
    suffix, range), a colour palette, JSON Schema validation.
  - The six names are reserved; see the upgrade note
    [above](#builtin-field-type-names-upgrade).

<a id="backup-history"></a>

- **Backups has a History: every backup attempt, app-made and cron-made, with
  its outcome and whether its files are still on disk (#2217).** `/editor/backups`
  (platform admins) lists runs newest first, 25 to a page, each with trigger,
  status (Succeeded, Failed, Running, Skipped), Database and Media badges, size,
  `Verified` / `Not verified` / `unverified (imported)`, destinations and the
  local state of its files: `on disk`, `missing`, `pruned (retention)`,
  `expired` or `off-site only`.
  - **Worker.** Each attempt writes a run; a failed run write never fails the
    backup. A refused attempt (no `pg_dump`) is a `skipped` run and still leaves
    `manifest.json` untouched. A job that was killed mid-run is marked failed
    ("Interrupted") by a sweep once it is 2h15m old.
  - **Cron's backups.** `KilnCMS.Backups.Importer.run/0` records
    `kiln-db-<stamp>` / `kiln-media-<stamp>` files found under `BACKUP_DIR` that
    have no run: when a platform admin opens the page, at the end of each worker
    run, and from `bin/kiln eval "KilnCMS.Backups.Importer.run()"`. It is
    idempotent by stamp, waits until a stamp's newest file is 10 minutes old and
    has no `.partial`, and never hashes or verifies a file, hence "unverified
    (imported)". `backup.sh db` and `backup.sh media` as separate cron entries
    have different stamps and appear as two runs.
  - **Missing is computed on read**, for the visible page only. `BACKUP_DIR` is
    host-local: on a multi-node deployment a run recorded by another node reads
    `missing`. `expired` is a heuristic for imported runs older than the
    retention window plus a day (cron records no prune).
  - **Secrets.** Text stored in a run goes through `KilnCMS.Backups.Redact`
    (URL userinfo, `key=value` credentials, rclone connection-string remotes).
    The status panel's off-site remote and `manifest.json`'s `offsite` are now
    redacted too.
  - **Access.** `KilnCMS.Backups.Run` is read-only for platform admins and
    written only by the `:backups` system actor (worker, importer, stale sweep).
    `Worker.run/1` still works; it is now `run(trigger, job_id \\ nil)`.
    `Staging.Scrub` purges runs (`backup_runs_purged`).
  - **Reserved** for the rest of the epic (#2216): `parts` and `sha256` (#2218),
    `destinations` (#2220), `encrypted?` (#2224).
  ([#2217](https://github.com/The-Verscienta/kiln_cms/issues/2217))

<a id="ip-block-rules"></a>

- **Site admins can block an IP address or range from `/editor/ip-blocks`
  ("Blocked addresses") (#2242).** A blocked address gets an empty `403` on
  every dynamic route and is refused on the `/live`, `/ws/gql`, `/ws/collab`
  and `/ws/bridge` sockets. Rules take an IPv4 or IPv6 address or CIDR range,
  an optional note and an optional expiry, and belong to one site. Guard rails:
  loopback is never blocked, `/up` and `/ready` are exempt, ranges wider than
  `/8` (IPv4) or `/16` (IPv6) are refused, and a rule that includes the admin's
  own address asks for confirmation. Rules are cached for a minute per node and
  cleared on every node when one is added or removed; if the list cannot be
  read, requests pass.
  - **Limits.** Static assets and `/uploads/*` are served before the site is
    known and are not covered: refuse those at a CDN or proxy. Behind a reverse
    proxy, set `TRUSTED_PROXIES` (or `CLIENT_IP_HEADER`) first, or a rule
    matches the proxy's address and blocks every visitor.
  - **Operators.** One new table, `ip_block_rules`, additive; rolling back
    leaves it unused. No new environment variables. If an admin locks
    themselves out, `DELETE FROM ip_block_rules WHERE ...` in SQL; it takes
    effect within the one-minute cache. Expired rules are not swept and still
    hold their slot until removed in the console.
  - **Developers.** The resource, `KilnCMS.CMS.IpBlockRule`, is org-admin only
    and deliberately absent from JSON:API, GraphQL and MCP. The request path
    reads it as the `:ip_block` system actor. New counter
    `kiln_cms.ip_block.refused.count`, tagged `surface`, never the address.
  See [ip-blocking.md](../ip-blocking.md).

<a id="conditional-custom-fields"></a>

- **A custom field can be shown only when another field has a given value, and required only then (#2277).**
  Open a field in `/editor/fields` (admins), expand **Conditions**, and set
  **Show when** and/or **Required when**: one or more tests on a field beside
  it ("Kind is one of Event, Talk"), joined by "All of these are true" or "Any
  of these is true". In the content editor the field appears and disappears as
  the editor changes the other value, with no round trip to the server, and
  a **Required when** field blocks the save only while its rule holds. The
  same fields work on a group's sub-fields, where a sub-field reads the other
  sub-fields of the same row. The how-to is in
  [extending-content.md](../extending-content.md#make-a-field-conditional).
  - **For developers.** `field_definition` gains two attributes,
    `visible_when` and `required_when`: plain JSON (`{"field", "op", "value"}`
    leaves under `{"all": [...]}` / `{"any": [...]}`; ops `eq`, `neq`, `in`,
    `empty`, `not_empty`, `gt`, `lt`; at most 3 levels and 10 nodes). They
    show up in `?include=field_definitions`, the OpenAPI document and the
    `read_field_definitions` MCP tool; creating or updating a definition is
    still admin-only and goes through the `CMS.create_field_definition` /
    `CMS.update_field_definition` code interfaces. The rule logic is
    `KilnCMS.CMS.Conditions`; the editor runs a JavaScript twin
    (`assets/js/conditions.js`) held to the same fixture
    (`test/support/fixtures/conditions_cases.json`).
  - **Hidden is an editor concept, not a privacy control.** A hidden field
    keeps its stored value, and that value is still delivered by the JSON:API,
    GraphQL, search and computed fields. Use **Private** for a value that
    must not be public. A value written through the API to a hidden field is
    still checked and stored.
  - **How it is enforced.** On a normal write, a hidden field is never
    required and a **Required when** field is required while its rule
    holds, judged on the merged view (what the request sends over what is
    stored). A restore, and a copy that drops custom fields, skip
    **Required when**, and a record saved before a rule existed is not
    rechecked by an unrelated write. There is no cascade: a field hidden by
    its own rule still counts with its stored value when another rule reads
    it, on the server and in the browser alike.
  - **Keeping rules consistent.** A rule can read only a plain value field
    (text, number, date, yes/no, choice) in the same scope, not itself, not a
    private field, and without a cycle. Deleting a field other rules read is
    refused, naming them; changing its type or making it private is refused
    when a rule would stop being valid; renaming it rewrites the rules that
    read it in the same transaction.
  - **Limits.** `gt` / `lt` compare numbers and ISO dates or datetimes, and
    are false when a side can't be read as one. A datetime needs seconds
    (`2026-11-07T10:00:00`): the browser's `datetime-local` input posts none,
    so a `gt` / `lt` test on such a field never holds, in the editor and on the
    server. A rule nested beyond one level (possible only through the code
    interface) is shown read-only in the admin UI until you remove it.
    Link fields, computed fields and a group as a whole carry no conditions.
  - **Upgrade.** Run migrations: two nullable columns are added to
    `field_definitions`, nothing is backfilled and the `kiln_reporting_v1`
    views are untouched. The change is expand-only, so rolling the pin back is
    safe (the older release ignores the columns). Overlays: run
    `mix ash.codegen` and commit the migration if you carry a copy of the
    resource. CI gains a step, `npm test --prefix assets`, that runs the
    JavaScript evaluator against the shared fixture.

<a id="breached-password-check"></a>

- **Admins choose what happens when a new password is in a known breach (#2240).**
  A new page, **Organization → Password policy** (`/editor/password-policy`, admins
  only), sets one of three stances for the site: **Off** (no warning),
  **Warn** (the default: accept the password and say so) or **Block** (refuse
  it for administrators; editors and viewers are still only warned).
  Passwords are checked when someone registers, changes their password, resets
  it, or when the first-run wizard creates the first admin. Sign-in is not
  checked.
  - **How a password is checked.** Kiln hashes the password with SHA-1 and
    sends only the first five characters to `api.pwnedpasswords.com` (the
    k-anonymity range API, with `Add-Padding`), through `KilnCMS.SafeFetch`.
    The match is made locally. Nothing is cached and no password, hash or
    address is logged.
  - **Fails open.** A timeout (3 s overall), an error status or a malformed
    answer accepts the password, logs a warning and emits
    `[:kiln_cms, :password, :breach_check]` with `result: :error` and a
    `reason`. An outage at a third party never stops anyone setting a password.
  - **Who counts as an administrator.** The stricter of the account's role
    (including a temporary role) and its membership tier on the site being
    used. `Block` is evaluated against the site the request is on.
  - **What people see.** Blocked: a field error on the password, "This password
    has appeared in a known data breach. Choose a different one." Warned after
    a password change or first-run setup: the message appears with the redirect
    to sign-in. Warned after registering or resetting: shown after the next
    password sign-in (a one-time note kept for ten minutes on that node, so on a
    multi-node deployment without sticky routing it can be missed).
  - **Operators.** `BREACHED_PASSWORD_CHECK=false` turns the check off for the
    whole deployment; `BREACHED_PASSWORD_POLICY=off|warn|block` sets the default
    for sites that have not saved a choice. See
    [Environment variables](../environment-variables.md#breached-password-check-2240).
  - **Not covered.** Admin-triggered password resets, magic links, SSO and
    passkey sign-up, account anonymization, seeds, the beta round and the
    staging scrub do not check. See the [threat model](../threat-model.md#breached-passwords).
  - **Developers.** `SitePasswordPolicy` is a new org-scoped resource
    (`CMS.list_site_password_policy/1`, `save_site_password_policy/2`,
    `reset_site_password_policy/2`); the four password actions on `User` carry
    a `:password_breach` metadata key. See `KilnCMS.Accounts.PasswordPolicy`
    and `KilnCMS.Accounts.BreachedPassword`.
  ([#2240](https://github.com/The-Verscienta/kiln_cms/issues/2240))

<a id="webhook-rotate-secret"></a>

- **Admins can rotate a webhook endpoint's signing secret (#2347).** Each row
  on `/editor/webhooks` has a **Rotate secret** button (admin only, with a
  confirmation). It replaces the secret and reveals the new one so you can
  copy it into the receiver. Before this, the only way to change a secret was
  to delete the endpoint and add it again, which also lost its settings.
  Rotation takes effect immediately and there is no dual-secret window: it is
  the remedy for a leaked secret, so the old one must stop working. Queued and
  retried deliveries sign at send time and use the new secret; one attempt
  already in flight can fail and is retried. Health counters
  (`consecutive_failures`, `auto_disabled_at`) are not touched, so an endpoint
  near the auto-disable limit can tip over while the receiver still holds the
  old secret. The old ciphertext is never decrypted, so an endpoint whose
  secret is unreadable after `SECRET_KEY_BASE` was lost can be rotated back to
  health; the unreadable-secret message now points at the button. Rotation
  logs `webhook secret rotated endpoint_id=… org_id=… actor_id=…` at info
  level (never the secret) and leaves no other audit trail. Over code it is
  `KilnCMS.CMS.rotate_webhook_secret/2`. No migration, no env var, no upgrade
  step; rolling the pin back is safe. See
  [Rotate a webhook signing secret](../webhooks.md#rotate-a-webhook-signing-secret).

<a id="graphql-custom-where"></a>

- **GraphQL filters custom fields with typed operators (`customWhere`, #2290).**
  Every GraphQL list that takes `customFilter` (published, keyword and semantic
  search, their `…Published` twins, for compiled types and `Entry`) also takes
  `customWhere: [CustomFieldCondition!]`. A condition is `name` plus exactly one
  kind key (`string`, `int`, `float`, `boolean`, `date`, `dateTime`) holding that
  kind's operators, so a wrong operand (`float: {gt: "abc"}`) fails GraphQL
  validation. Conditions are ANDed. `customFilter` and `customSort` are unchanged.
  - **One authority.** The conditions are translated into `customFilter`'s own
    conditions inside `CustomFieldQuery`, so casting, jsonb comparison, tenant and
    Entry scoping, and privacy are the same code. The kind given must be the
    field's (`FieldKind`); a mismatch names the field's actual kind. A private
    field is the same `unknown custom field` error as a missing one below editor.
  - **Not typed in v1.** A `multiple` field takes only `string: {eq | in}` (list
    contains, as before); reference, media, group, geolocation, link fields and the
    relationship operators stay on `customFilter`.
  - **New operators.** `contains` and `startsWith` match text case-insensitively
    and take `%`, `_` and `\` literally. `customFilter` accepts them as
    `contains` / `starts_with` (additive; text-like fields only).
  - **Limits.** At most 10 conditions per query, 50 values in an `in`; each
    condition adds 5 to the query's complexity. Nothing indexes these predicates
    beyond the equality index of #2321.
  - **API surface.** Additive. `docs/api/schema.graphql` and
    `docs/api/openapi.json` gain the argument (the JSON:API routes list
    `custom_where` as an array of objects; the GraphQL mutations that load a
    record list it beside `customFilter`).

<a id="move-to-trash-in-editor"></a>

- **Admins can move one document to the trash from its row menu in the
  content list, or from the content editor's Settings tab.** Until now the
  only way to trash content in the UI was to tick it and use the bulk bar's
  Delete, which nobody found from inside a document
  ([#2137](https://github.com/The-Verscienta/kiln_cms/issues/2137)).
  - **Where.** The row's **⋯** menu ends with **Move to trash**, set apart by
    a divider and in red. The editor's Settings tab ends with a **Trash**
    section: a note on what trashing does, and a **Move to trash** button.
    There is no header button. The bulk bar is unchanged.
  - **Who.** Admins only, whatever the document's state, because it is the
    same `:destroy` policy as the bulk Delete and the API's `DELETE`. Editors
    are not shown either control, and a forged event is refused before the
    write.
  - **What it does.** The same soft delete as before: the document leaves the
    list, the API and the live site, and an admin restores it from Trash
    (`/editor/trash`) within the retention period (30 days by default). The
    confirm prompt names the document and the period; for a published
    document it adds that it comes off the site now and that restoring it puts
    it back.
  - **Unsaved edits.** In the editor, an edit still waiting for autosave is
    saved first, so a restore brings back what was on screen; if that save
    fails, nothing is trashed and the error says why. On a published
    document, Settings-tab changes held for **Save** are not saved first, as
    with the other workflow buttons.
  - **Known limitation.** Another session still open on the document (another
    editor tab, the in-context editor, the API or MCP) can keep writing into
    the trashed row, and **Publish changes** on a held live page can publish
    it again. Tracked in
    [#2332](https://github.com/The-Verscienta/kiln_cms/issues/2332).
  - **Developers.** New `KilnCMS.CMS.ContentTypes.can_destroy?/4` asks the
    destroy policy for one record (`tenant:` in the options), and
    `KilnCMSWeb.ContentTrash` holds the write and the copy both screens share.
    No migration, no config, nothing to run. Guide:
    [Trash and restore](../trash.md).

<a id="content-list-field-columns"></a>

- **The content list can show custom fields on each row.** Pick one content
  type in the list's type filter and a **Columns** button appears in the list's
  header bar. Tick the fields to show; each row then carries a small strip of
  `label value` pairs under its meta line. The choice is the person's own, kept
  per site and per content type, and is not part of the URL or of saved views.
  - **What it offers.** Fields of type string, text, integer, float, boolean,
    date, datetime, url, select, reference, user and media, single-valued only.
    Groups, geolocation, date ranges, recurrence, computed and multi-valued
    fields are not offered. Up to 6 are remembered per type and the first 4
    (in field order) are shown. Private fields are offered, because editors
    already see them in the content editor; the list is editor-only.
    With "All types" selected on a site with several types, no picker is
    shown (field names collide across types) and a hint says to choose a type.
  - **What a cell shows.** A reference shows the target's current title, read
    afresh as the viewer, or "Unavailable" when it cannot be read or no longer
    exists; the title stored in the field is never shown. A user field shows
    the person's name only ("Unnamed user" without one, never the email). A
    select shows the option's label, a boolean Yes or No, a media field its
    alt text or file name, and an empty value shows a dash. Long values are cut
    at 80 characters. References are looked up once per page of rows, not per
    row.
  - **Developers.** Choices live in a new nullable `users.content_list_columns`
    map (`%{org_id => %{type => [field name]}}`), written only by the new
    `:set_content_list_columns` action (`Accounts.set_content_list_columns/5`,
    self only). It merges one site/type entry into the stored map under a row
    lock, so a stale tab cannot overwrite another site's choice, and checks the
    names against the site's field definitions; a field deleted later drops out
    silently. Which fields may be offered is decided in one place,
    `KilnCMS.CMS.ListFields.readable_fields/4`. The attribute sits behind the same field policy as
    `status_marks`: only the user and platform admins can read it, so it
    reaches no API caller as a byline field.
  - **Upgrade.** Additive: one nullable `users` column with no default, added
    by the migration that runs on deploy. No upgrade step, no environment
    variable, and rolling the pin back leaves an unread column. Filtering,
    sorting and exporting by field are not part of this change.

<a id="content-list-field-filter-sort"></a>

- **The content list can be filtered by custom fields and sorted by one.** Pick
  one content type, open **More filters**, and add up to four conditions under
  **Field conditions** (a field, a condition, a value); each becomes a chip you
  can remove. **Sort by** gains a **Field** group (*Field: Price (↑)* / *(↓)*).
  Both are in the URL and in saved views, and "Load more" keeps them. This is
  the second half of #2293; the first was the Columns picker.
  - **What it offers.** Per field type: string and url (is, contains, empty or
    not), text (contains, empty or not), integer and float (is, greater than,
    at least, less than, at most, empty or not), boolean, date and datetime
    (from, until, by whole days), select, and reference, user and media by id.
    Only single-valued string, text, integer, float, boolean, date, datetime,
    url and select fields can be sorted by; records with no value sort last in
    either direction. Private fields are offered (the list is editor-only); a
    person who cannot read a field cannot filter or sort by it. With "All
    types" the panel says to choose a type, since names repeat across types,
    and changing the type clears the conditions and the field sort.
  - **The count.** With field conditions the count stops past 1000 and the
    header reads "1000+ items", because a field condition scans the site's
    records of that type. Without conditions it is exact.
  - **Saved views.** A view whose field was deleted, made private or retyped
    shows a warning icon, and opening it says the condition was left out; the
    other conditions still apply. If a field changes while the list is open and
    the read can no longer run, the field query is cleared with a notice, not
    left as an error.
  - **Developers: a URL contract.** State travels in two parameters:
    `cf=field:op:value;...` (up to four, field and value URL-encoded, canonical
    order by field then op, at most 600 characters; a saved view allows 600 for
    `cf` and keeps 200 for every other value) and `sort=field:<name>` /
    `-field:<name>`. Saved views store this, so treat the format as a contract.
    Anything invalid for the single type in play reads as absent.
    `KilnCMS.CMS.ListFieldQuery.arguments/3` is the only place that names the
    `custom_filter` / `custom_sort` read arguments; `ContentTypes.list!/2` and
    `count!/2` take an `arguments:` option, and `count!/2` honours a `limit` in
    `query:`. Guide: [Filter and sort the content list by custom fields](../extending-content.md#filter-and-sort-the-content-list-by-custom-fields).
  - **Upgrade.** No migration, no config. `saved_views.params` is an existing
    map, now allowed a `cf` key; rolling the pin back leaves such a view with an
    unknown key an older list ignores.

<a id="content-list-export"></a>

- **The content list can be downloaded as CSV or JSON.** On `/editor`, editors
  and admins get an **Export** menu in the list's header bar with **Download
  CSV** and **Download JSON**, and the bulk bar gains **Export selected** (CSV,
  the ticked rows). This is the third part of #2293, after the Columns picker
  and field filter and sort.
  - **What is exported.** The rows the list shows for the same type, status,
    search, field conditions and field sort, as the person asking (a record
    they cannot read is absent). Columns are `id,type,title,slug,status,locale,updated_at`
    plus the person's saved list columns for the type, nothing else; the panel
    says *Exports the columns shown in the list.* The scope is the types the
    editor can author, as in the list. With "All types" the types come one
    after another, not merged into the list's order. Export selected takes at
    most 100 rows and ignores every filter but the type.
  - **Private fields.** Left out unless **Include private fields** is ticked
    (shown when the type has any); every user field counts as private. A `cf`
    condition on a private field is accepted even when the column is not
    exported, as in the list.
  - **Values.** The file is data, not the screen: booleans are `true` / `false`
    (not Yes / No), media is the file name (not the alt text), select is the
    stored value, long values are not cut. A reference is its readable title
    (JSON `{id, label}`); an unreadable or deleted target is `Unavailable`
    (JSON `{id: null, label: "Unavailable"}`), never the title stored in the
    field. CSV starts with a UTF-8 byte order mark for Excel.
  - **Limits.** More than 10,000 rows is HTTP 413 with a message, never a
    truncated file; a download is stopped after 60 seconds; 10 downloads a
    minute per account, 429 with `Retry-After`. The rate limit is counted per
    node, and a refused request also spends it. A download stopped part-way
    drops the connection unfinished: a CSV ends mid-file and a JSON array is
    never closed, so a file that parses is complete.
  - **Operators and developers.** Optional
    `config :kiln_cms, :content_export, max_rows: 10_000, time_limit_ms: 60_000`.
    Each download logs `content export` and emits
    `[:kiln_cms, :content_export, :stop]` (`%{rows: n}`; metadata `user_id`,
    `org_id`, `type`, `format`, `rows`, `columns`, `include_private`), never a
    value or filter text. There is no audit trail of exports yet. Routes:
    `GET /editor/content/export.csv` and `.json`, editor-only, session auth.
    Guide: [Export the content list as CSV or JSON](../extending-content.md#export-the-content-list-as-csv-or-json).
  - **Upgrade.** No migration, no required config; rolling the pin back
    removes the menu and the routes.

<a id="custom-field-native-filter-sort"></a>

- **A custom field can be named like a column in `filter[...]` and `sort=`, and
  `custom_sort` works on the search routes.** `GET /api/json/posts?filter[price][gt]=10&sort=title,price`
  now means what `custom_filter[price][gt]=10&custom_sort=title,price`
  did, as long as no public attribute, calculation, aggregate or relationship
  has that name (a built-in always wins). The built-in relations take their
  set operators natively too: `filter[tags][has][]=<id>`,
  `filter[related_posts][has_none]=<id>`. `custom_sort` (GraphQL
  `customSort`) is a new argument on `search`, `search/published`,
  `semantic-search` and `semantic-search/published`, with the precedence
  explicit `sort` > `custom_sort` > relevance or distance > recency. A leading
  custom sort on semantic search replaces distance ordering (the vector
  index cannot serve it) and the rule that a name match comes first. The
  null test `is_nil` is accepted as a synonym of `null` on custom fields. See
  [Naming a custom field like a column](https://github.com/The-Verscienta/kiln_cms/blob/main/docs/json-api.md#naming-a-custom-field-like-a-column).

  What to know before relying on it:

  - `custom_filter` / `custom_sort` remain the stable form. They always mean a
    custom field, they are the only way to reach one named like a column,
    and a later built-in with the same name would start shadowing `filter[x]`.
    The official clients keep emitting `custom_*`; new `customSort` /
    `:custom_sort` options on their search calls.
  - A typo such as `filter[ttile]=x` used to get ash_json_api's "No such
    field"; it is now `400` `invalid_argument` with detail
    `unknown custom field "ttile"` and no `source` member. Code that matched
    the old message needs updating. An anonymous typo costs one uncached
    field-registry read before it is refused.
  - Custom sorts must come last in `sort`: `sort=title,price` works,
    `sort=price,title` is `invalid_sort`. Custom sorts are nulls-last; a native
    `-x` is plain `desc`.
  - The OpenAPI `sort` parameter's `format` lists built-in fields only, so a
    client that validates it strictly rejects `sort=price`. Use `custom_sort`.
  - `links.self` echoes the URL as sent.
  - On `/entries` without `filter[type_name]`, a bare name declared with
    different types by different dynamic types is refused ("has a different
    type per content type"), as `custom_filter` already was.
  - Sorting by `media` / `reference` custom fields is still unsupported.

<a id="reject-invalid-bearer"></a>

- **`KILN_API_REJECT_INVALID_BEARER` (#2161).** With it on, an `Authorization: Bearer` token that
  fails verification gets a 401 `invalid_token` envelope instead of silently reading as anonymous.
  Off by default for this release, because a consumer sending a stale token today gets 200;
  the default flips next release, so announce it in that release's upgrade notes.

<a id="change-severity"></a>

- **Change severity: how much a published edit matters, stored per edit.**
  A site lists the fields it treats as safety-relevant, per content type, at
  `/editor/safety-fields` ("every field" is one switch; computed fields should
  not be listed). An edit that changes a listed field of published content, or
  first publishes one with a non-empty listed field, is recorded with a
  severity — `critical`, `notable` or `routine` — in a new nullable
  `change_severity` column of the content `*_versions` tables, so it belongs to
  that edit and the next edit starts clean. Versions written before this read
  as no severity.
  - **Admin editor.** "Publish changes" and a first publish ask "How much does
    this change matter?" when the edit touches a listed field; nothing is
    preselected and the publish does not go through until one is chosen. Saving
    a working copy and autosave never ask. The content list, calendar and bulk
    publish refuse such an edit with a pointer to the editor.
  - **API, MCP, GraphQL and automated writers.** `update` and
    `publish` take an optional `change_severity` (`publish_changes` and
    `restore_version` have no public route and default to `notable`); omitted, the edit is recorded `notable` — never routine, never empty.
    There is no batch endpoint, so it is per request.
  - **Read back.** `latest_edit_severity` and `latest_edit_at` are public
    calculated fields on JSON:API and GraphQL (readable with a viewer key) and
    sibling fields on every `/api/sync` upsert item. They describe the latest
    *safety* edit (a later edit of an unlisted field does not move them) and
    are `null` when the document is unpublished or has none. No artifact
    `format_version` change. Webhooks and the change feed do not carry the
    severity yet.
  - **Upgrade.** Additive: a nullable column on each `*_versions` table and one
    new settings table. Overlays run `mix ash.codegen` for their own content
    types. Until a site lists a field, nothing changes.

<a id="reporting-views"></a>

- **Read-only SQL views of published content, for BI tools.** Custom fields
  live in one JSONB map, so Metabase or Superset could not select a field as
  a column. The new `kiln_reporting_v1` schema has, per content table, a wide
  view (core columns plus an allowlisted `custom_fields`) and a
  `<table>_field_values` view with one row per record and field
  (`value_text`, `value_json`). `mix kiln.reporting.sql` prints a script that
  creates a read-only role with `SELECT` on those views only. Guide:
  [docs/reporting.md](../reporting.md); the reasoning is
  [decision 0015](../decisions/0015-reporting-views-are-a-versioned-additive-only-sql-contract.md).
  - **What is exposed.** Published, unarchived, public-audience rows without an
    access password. A field appears only while a live definition names it and
    it is not private or a `user` field; the list is read live, so a flip to
    private applies on the next query. Reference values are `{id, type}` only.
    Media snapshots pass through as stored.
  - **Limits.** No typed columns (cast `value_text` / `value_json`; the guide
    has a recipe). Every site's rows are visible to the role, so it must not
    go to a tenant. Role settings (read-only, 60s timeout) are advisory; use a
    read replica to enforce.
  - **Developers.** The views are a versioned, additive-only contract; a
    breaking change would be `kiln_reporting_v2`. They pin the columns they
    read, so `mix kiln.migrations.check` now fails a migration that removes,
    renames or retypes one without dropping both views of the pair first
    (`kiln:contract-ok` does not excuse it); see `docs/releasing.md`. The
    demo reset now drops the schema before restoring, and
    the promotion column lookup filters on the current schema, so a view of the same name cannot add columns.
  - **Upgrade.** Additive, no environment variable. Overlays: see the upgrade
    note above.

<a id="custom-field-indexes"></a>

- **`custom_filter` equality, `in` and list membership on custom fields use an
  index, so a selective filter on a large catalogue no longer scans the
  table.** Equality used to compare `(custom_fields -> name) = value`, which no
  index can serve. Positive `eq` and `in` (and the list and single media or
  reference equivalents) now ask `custom_fields @> {name: value}`, which the new
  GIN `jsonb_path_ops` index on `custom_fields` answers; one index covers every
  field name of every dynamic type, because the name is inside the indexed
  value. On 100,000 pages in one tenant, a filter matching one row dropped from
  about 40 ms to about 3 ms. The results are the same rows as before.
  - **Accelerated:** `eq`, `in`, and membership in a multiple select, string,
    media or reference field (`eq`, `in`), and a single media or
    reference field by id.
  - **Not accelerated:** `not_eq`, `gt`/`gte`/`lt`/`lte`, `ilike`, `null` and
    `custom_sort`. `not_eq` keeps the old form on purpose: a record without the
    field must stay excluded from it. For range and sort, the compiled
    attribute remains the answer (see the D4 note in
    [dynamic-content-types-plan.md](../dynamic-content-types-plan.md)), or an
    expression btree per field as described in
    [Custom fields](../json-api.md#which-custom-filters-use-an-index).
  - **Cost.** About 26% of the table's size per index, about 25% slower bulk
    inserts and bulk `custom_fields` updates, and 10-35% slower single saves
    (within the run-to-run noise). `custom_fields` is rewritten on every save,
    so no update is a heap-only tuple once it is indexed. Measured on a loaded
    host: rerun [the benchmark](../benchmarks.md#custom-field-filters-at-100k-rows)
    before quoting absolutes.
  - **Developers.** `KilnCMS.CMS.Preparations.CustomFieldQuery.contains/3`
    builds the containment expression for a column, and `ash_type/1`, now
    public, gives the type a field's input is cast with.

<a id="plugin-plug-routes"></a>

- **A plugin can mount plain-Plug endpoints, such as a webhook receiver, a JSON
  API or a feed variant, with the new `plug_routes/0` callback
  (`kiln_plugin` 1.4.0).** Until now a plugin could only route to a LiveView
  page (`public_routes/0`), so an endpoint with no page had to be an overlay.
  A route is `{verb, path, plug_module, plug_opts}` (a Phoenix controller is a
  Plug whose opts is the action atom) or `{:forward, path, plug_module,
  plug_opts}`. The package needs only `plug`, so it works as a Mix dependency.
  - **What the core does.** Mounts the routes before the content-delivery
    catch-alls, in a scope with no session, no CSRF check and no `accepts`
    (`current_user` is never set; the plugin authenticates its own caller).
    `conn.assigns.current_org` is set, but the plugin passes `tenant:` to Ash
    itself. Requests are limited to 300 a minute per client address in their
    own `:plugin_endpoint` bucket. The body, of any content type
    except `multipart/*`, is also kept byte for byte in `conn.private[:raw_body]`,
    capped at 1 MB (over it, `413`), so an HMAC can be verified.
  - **Checks.** A malformed route stops the build, naming the plugin.
    `mix kiln.plugins.doctor` also reports a path under a root core routes own
    (`/editor`, `/api`, `/gql`, `/mcp`, …) and overlap with another plugin's
    plug or public routes. `mix kiln.plugins.list` and System → Plugins count
    plug routes.
  - **Upgrade.** Additive. A plugin that does not define `plug_routes/0`
    (including one built against `kiln_plugin` older than 1.4) declares none. A
    plugin using it requires `{:kiln_plugin, "~> 1.4"}`. See
    [Plugin extensibility](../plugin-extensibility.md).

<a id="graphql-typed-custom-fields"></a>

- **GraphQL reads admin-defined custom fields typed by kind, with no deploy
  and no schema change (#2290).** `customFields` stays a `JsonString`. Next to
  it every content type (`Page`, `Post`, a project type, `Entry`) and the
  `ContentRecord` interface gain `customString`, `customInt`, `customFloat`,
  `customBoolean`, `customDate` and `customDateTime` (each `(name: String!)`,
  nullable) and `fields(names: [String!]!): [CustomFieldValue!]!`. A field an
  admin adds is readable at once; the GraphQL schema is compiled and the same
  for every site, so what it types is the *accessor*, not the name.
  - **What is and is not checked.** `customFloat(name: "price")` is a `Float`
    or `null`. A typo, a rename, a deleted field, a field of another kind, a
    legacy value that no longer fits, or a private field read below editor is
    `null` (left out of `fields`), never an error. The server cannot catch the
    typo; the exported contract below does.
  - **`fields(names:)`.** `names` is required, at most 50. It returns the
    `CustomFieldValue` interface (`name` plus the kind's members: `StringValue`,
    `IntValue`, `FloatValue`, `BooleanValue`, `DateValue`, `DateTimeValue`,
    `ListValue { items }`, `GroupValue { fields }`, `ReferenceValue { ids }`,
    `MediaValue`, `GeolocationValue { lat lng label zoom }`,
    `JsonValue { value }`). A `multiple` field is a `ListValue`; computed
    fields, `datetime_range` and `recurrence` are `JsonValue`. Groups nest to depth 3. A reference field
    returns ids only: read the records through `references(field:)`. Cost is
    1 plus the selection once per name; an accessor costs 1; the 200 limit is
    unchanged.
  - **Visibility and locale.** Values come from the record as the caller reads
    it, so private fields read as unknown below editor. A
    `localization: :fallback` field does not inherit along the locale chain in
    this layer; name the locale you want. A page of records does one
    definitions read per type, not one per record.
  - **Typed contract per site.** `GET /api/schema?format=typescript` is the
    existing document as a `.d.ts`; `?format=typescript-graphql` is a `.ts`
    module that adds, per content type (and per `typeName` for dynamic types,
    selected on `publishedEntries(filter: {typeName: {eq: "…"}})`), a
    `<Type>CustomFields` interface and a ready `<Type>CustomFieldsFragment`.
    An unknown `format` is a `400` with code `invalid_format`; without
    `format` the response is the same JSON as before. Regenerate after an
    admin changes fields. `filter` and `sort` still use
    `customFilter`/`customSort`, unchanged.
  - **Plugins.** `Kiln.FieldType` gains an optional `graphql_kind/1`
    (`:string`, `:int`, `:float`, `:boolean`, `:date`, `:datetime`, `:json`)
    in `kiln_plugin` 1.4.0. A type without it, or compiled against an older
    SDK, is served as `JsonValue`, so nothing breaks. Publish the SDK to Hex
    before a plugin requires `~> 1.4`.
  - **Swift and Kotlin.** `?format=swift-graphql` and `?format=kotlin-graphql`
    add the same section to the native-app models: per content type a
    `<Type>CustomFields` result type (`Codable` struct / `@Serializable` data
    class) with the fragment as `fragment` / `FRAGMENT`, and a
    `KilnCustomFieldValue` enum / sealed interface for the `fields(names:)`
    kinds, `GeolocationValue` and `MediaValue` included, with an `unknown` case
    for a kind added later. Aliases, collision rules and fragment text are
    shared with the TypeScript emitter (`KilnCMS.SchemaExport.GraphQL`), so the
    three cannot disagree. The Kotlin form uses package `kiln`; call
    `KilnCMS.SchemaExport.Kotlin.emit_graphql/2` for another.
  - **Not yet.** Typed filter operators, a per-site SDL with a regenerate step,
    and typed writes.
  - **Upgrade.** Additive and org-independent: no migration, no config, and
    rolling the pin back removes the new fields only. The new fields
    are added to every content type in the schema's `:content_domains`, so an
    overlay's types get them without code changes.
    See [headless-graphql-api.md](../headless-graphql-api.md#read-custom-fields-typed-by-kind).

<a id="draft-write-api-keys"></a>

- **Drafts-only API keys for headless services (#2273).** A new `draft_write` access
  scope on API keys lets an app service (Verscienta's, for AI drafting) create drafts and edit
  drafts it authored, and nothing else: no publishing, submitting for review, deleting, media,
  tags or related links, and no edits to live or someone else's content. The bound is a policy
  on `Content` that sits above the admin bypass and ignores the owner's role, so promoting the
  owner later widens nothing. Keys are minted by an admin on a viewer-tier service account and
  capped at 30 days (`draft_write_key_max_ttl_days`). Drafts created this way record the key
  and an optional `X-Kiln-On-Behalf-Of` label (stored for display only, never used for
  authorization); the fields appear in the editor (not in version history, which a second key
  on the same owner can read) and, for editors, admins and the creating key only, on JSON:API, GraphQL and `/mcp` (never for anonymous, preview-link or
  viewer-tier callers, webhook payloads or the preview endpoint). A GraphQL query that selects
  those three fields as someone not allowed them gets `null` plus a `forbidden_field` entry in
  `errors`, so a codegen'd query that selects every field should drop them. See [decision 0012](../decisions/0012-headless-services-get-a-draft-write-api-key-scope-not-oidc-pass-through.md)
  and the headless consumer guide.

<a id="draft-write-key-rotation"></a>

- **Self-rotating drafts-only keys.** A `draft_write` key's 30-day cap meant a person re-minted
  the service's key every month. An admin can now give the key a rotation window at mint
  (`rotatable_until`; "Self-rotation" at `/editor/api-keys`, at most
  `draft_write_key_max_rotation_days`, default 365). Until then the service calls
  `POST /api/keys/rotate` with the key and gets a fresh one: same account, scope and name,
  expiring at the 30-day cap or the window's end, whichever is sooner. The old key is revoked in
  the same transaction, under a row lock, so a chain has one live key and never outlives the date
  the admin chose. The action takes no input; `read`/`read_write` keys, signed-in users and admins
  are refused, and an owner promoted to editor since the mint stops the chain. Presenting a
  rotated-away key to the endpoint again more than 120 seconds later revokes the whole chain and
  mails the platform admins. Keys without a window behave as before. New nullable `api_keys`
  columns `rotatable_until`, `lineage_id`, `rotated_from_id` (additive). See
  [decision 0012](../decisions/0012-headless-services-get-a-draft-write-api-key-scope-not-oidc-pass-through.md#rotation)
  and the headless consumer guide.

<a id="block-field-localization-config"></a>

- **A site can make core block fields per-locale from config.**
  `config :kiln_cms, :i18n, block_fields: %{"image" => [shared: [:media_id, :url], fallback: [:alt, :caption]]}`
  gives the core `image`, `video` and `audio` blocks (or any registered block
  except `gallery`, `fragment`, `rich_text`, `columns` and `file`) the same
  `shared:` / `fallback:` modes a block module declares with `localized:`. A
  site cannot edit a core block, so until now it could not share an image
  across locales. On a translation the editor now locks a shared field, with
  the *Shared: edited in the EN version* note and its library buttons
  disabled, and shows a fallback field's inherited value as a placeholder; the
  server refuses a pick into a locked field. Invalid entries are ignored with
  one warning per distinct config. With no `block_fields:` key nothing changes.
  Before enabling `:shared`: the next publish of the source variant overwrites
  each translation's own value of those fields, and edits to them are refused
  afterwards. Share `media_id` with `url`; a `:fallback` `alt` beside an
  unshared `url` can describe the wrong image; an image nested in a `columns`
  block exposes only `url` and `alt`. Removing the key is safe. No migration.
  See [Field-level localization](../field-level-localization.md#making-core-block-fields-per-locale-2270).

<a id="robots-flags"></a>

- **Editors can keep a document out of search engines.** Pages, posts and
  entries gain `noindex` and `nofollow` flags, edited under the canonical URL
  in the SEO panel (and subject to field grants). They render as
  `<meta name="robots">` and an `x-robots-tag` header, both built by one
  helper so they cannot disagree; the password-lock page keeps its
  unconditional `noindex, nofollow`. Noindex documents are left out of
  `sitemap.xml`, the news sitemap, `llms.txt` and every feed. Delivery is
  unaffected: the JSON:API, GraphQL, change feed and fired artifacts still
  carry them, and the `:json` artifact gains an optional `robots` object only
  when a flag is set (no `format_version` bump). Versions, working copies,
  duplicates, translations and export/import carry the flags; restoring a
  version written before the flags existed leaves the current values alone. A type can set
  `noindex_default` / `nofollow_default` (compiled option or Content-type
  setting) for new documents only. An advisory warns when a published page
  linked from an enabled menu item is set to noindex.

<a id="field-validation"></a>

- **Admins can constrain a custom field's values: a range, a length, a pattern, or "unique" (#2276).** In `/editor/fields`, a field's form has a **Validation (optional)** group with the controls its type takes. Numbers get `min`/`max`; `:string`, `:url` and plain `:text` get `min_length`/`max_length` and a whole-value `pattern` with an optional `pattern_message`; `:string`, `:url`, numbers and dates can be `unique`. The rules are stored in the new `validation` attribute of the field definition and checked on every write path (editor, JSON:API, GraphQL, MCP, importers), so an editor and an API client see the same error, naming the field (`SKU (sku) doesn't match the required format`).
  - **Existing data is left alone.** A value equal to the stored one is never re-checked, so tightening a rule does not block unrelated edits. Version restore, type promotion and content copy skip the value rules (they carry values that were valid when written); `unique` is still enforced for restores, and a duplicated document starts with its unique fields blank.
  - **Unique is enforced by the write path, not the database.** An advisory lock plus an in-transaction check makes two racing saves safe; matching is exact and case-sensitive, within the organization, content type and locale, ignoring the trash. A working copy only stages a value: the check runs when it reaches live `custom_fields`. Turning `unique` on is refused while values already repeat. Raw SQL and a database restore bypass it, so `mix kiln.fields.duplicates` audits for repeats.
  - **Patterns are safe to run.** The pattern must match the whole value, is at most 200 characters, and runs with match limits; a value over 2,000 characters or a runaway pattern counts as not matching.
  - **API and export.** Field definitions carry `validation` on JSON:API (and in `docs/api/openapi.json`). The schema export adds `x-kiln-minimum`, `x-kiln-maximum`, `x-kiln-min-length`, `x-kiln-max-length`, `x-kiln-pattern` and `x-kiln-unique` as annotations rather than JSON Schema assertions, since stored values may predate a rule; `pattern_message` is not exported.
  - Guide: [Constrain the values of a field](../extending-content.md#constrain-the-values-of-a-field).

## Changed

<a id="public-image-weight"></a>

- **The signed-out home page and the built-in logo no longer ship oversized
  images (#2165).** The home page loaded about 1,030 KB of images: four 2880x1800
  console screenshots, and a 278x379 PNG logo shown at 20 to 40 pixels. It now
  loads about 102 KB on a browser that takes WebP (about 63 KB on a small
  1x screen), and about 570 KB on the JPEG-only fallback.
  - **Screenshots.** Each is a `<picture>` with a WebP `srcset` and a 1440-wide
    JPEG fallback. The hero (the editor shot) is offered at 720, 1440 and 2880
    pixels wide, loads eagerly and with `fetchpriority="high"`, since it is
    the likely largest paint. The three tour shots are offered at 720 and 1440
    and load lazily.
  - **Logo.** When the brand's logo is the built-in one
    (`KilnCMS.Branding.default_logo_url/0`), the header, footer and
    sign-in brand render it through `KilnCMSWeb.Layouts.brand_mark/1` as a
    `<picture>` of `logo-mark-sm.webp` (6 KB) over `logo-mark-sm.png` (14 KB),
    88x120 with explicit width and height. A custom `logo_url` is rendered
    exactly as given. `logo-mark.png` is unchanged and is still the default
    `logo_url`, so the branding values in the headless and API responses are
    the same as before.
  - **Contributors.** Raw captures from `e2e/screenshots/home.spec.js` now go
    to the gitignored `e2e/screenshots/raw/`. `scripts/optimize_home_images.sh`
    is the only way to produce the files the page serves, and a new test
    (`home_image_weight_test.exs`) fails if the committed files go over a byte
    budget. See *Refreshing the home page screenshots* in `CONTRIBUTING.md`.
  - **Overlays.** An overlay that replaces `home.html.heex`, or renders
    `brand.logo_url` in its own `<img>`, does not get the right-sized images;
    it keeps what it renders today. To get them, call `Layouts.brand_mark/1`.
    Nothing to set, no migration, and rolling the pin back is safe.

<a id="csv-numbers-unguarded"></a>

- **A real number in a CSV export is written as itself.** The CSV writer
  prefixed any value starting with `-` with `'` to stop a spreadsheet running
  it as a formula, which turned the number -5 into the text `'-5`. A value that
  is a number (integer, float, decimal) now skips the guard; text is
  unchanged, so the string `-5` and `=1+1` are still prefixed, even in an
  integer field. Chosen as Changed rather than Fixed because it alters the
  bytes a CSV writes for a negative number, wherever `KilnCMSWeb.CSV.line/1`
  is given one (core exports mostly write counts, which are not negative; an
  overlay's may). `parse/1` reads
  both forms back to `-5`.

<a id="access-denied-page"></a>

- **A console page you lack the role for now lands on a persistent `/access-denied`
  page instead of bouncing you home with a toast (#2143).** Every console role
  guard (editor-only, admin-only and the instance-wide pages such as API keys,
  accounts, team, backups and system) used to flash "You need admin access to
  view that page." and redirect to `/`, so the explanation vanished in seconds
  and you landed somewhere unrelated. They now redirect to
  `/access-denied?needs=editor|admin|platform`, a `403` page that names the role
  the page needs, shows your own role on this site and what it can do, and says
  who to ask (an admin of the site, or whoever administers the installation for
  `platform`). A signed-out visitor gets a **Sign in** button; a signed-in editor
  or admin gets **Back to the console**. `needs` is whitelisted: any other value
  renders generic copy and is never echoed, your role is read from the session
  rather than the URL, and no return path is accepted. The page is sent with
  `x-robots-tag: noindex`. For overlay authors: build the URL with
  `KilnCMSWeb.AccessDenied.path/1` instead of a flash and `redirect(to: ~p"/")`.
  **`access-denied` is now a reserved root slug and path segment.** Content
  whose slug is `access-denied` at the site root is shadowed by the new page;
  the reserved list now refuses it as a content type path segment and a path
  alias, but nothing renames existing records, so change the slug or alias of
  any such page. There are no migrations, environment
  variables or upgrade steps; rolling the pin back restores the redirect and toast.
  ([#2143](https://github.com/The-Verscienta/kiln_cms/issues/2143))

<a id="team-scope-pickers"></a>

- **The scope of a custom role or a member on `/editor/team` is now picked
  instead of typed.** The role and member forms asked for comma-separated type
  names and a JSON object of field grants, which suited a developer but not
  the operator who manages a team (#2141). Each type axis (**Content types
  they may edit**, **Content types they may read in the editor**) is now a
  choice between no restriction (on a member: **Inherit (custom role, then
  account)**) and **Only these types**, with the site's types as checkboxes.
  Custom types are one choice, **Custom content types (all of them)**, stored
  as `entry` as before. **Field grants** has a row per content type with three
  choices: no restriction (key absent), **Only these fields**, or
  **No fields (can't change existing documents)**, which stores `[]`. "Only
  these…" with nothing ticked is refused rather than saved as `[]`, which on a
  type axis would mean every type.

  Saving merges onto the stored value: names this site doesn't recognize are
  shown "(not found)" and kept until unticked, so opening a form and saving it
  writes back exactly what was there. A role saved unchanged isn't written at
  all ("No changes."), so its members' live connections aren't dropped for
  nothing. The member form shows what an inherited axis currently resolves to.
  Who can change scope, the stored shapes, and `Accounts.update_role/3` and
  the membership actions are unchanged; the new
  `KilnCMS.CMS.Changes.EnforceFieldGrants.grantable_fields/1` lists the field
  names a grant can usefully name for a type. No migration, config or API
  change; rolling back the pin is safe. See
  [Scope a custom role](../granular-rbac.md#scope-a-custom-role).

<a id="effective-role-display"></a>

- **Every screen that shows a role now leads with the tier that applies now,
  and says in words when a temporary one ends and what it returns to.** The
  accounts register, an account's page, the team page and the account's
  Sites panel showed the standing role, a live grant and the account's status
  as look-alike badges side by side, with nothing saying which one counts
  (#2142). A platform admin's team row showed their membership tier, which the
  policies ignore.

  Each role now reads as one badge after a scope label: **Platform:** on
  `/editor/accounts` (the list and an account's header), and **On this site:**
  on `/editor/team`, an account's **Sites** panel, and a new **Your access**
  box in **Profile** on **Your settings**. The site tier is decided by the
  same function the policies use, so a platform admin reads as *Admin*, with
  the note "Site tier Viewer, overridden by the platform admin role." when
  their membership holds less. While a grant is live, a line under the badge
  says "Admin is temporary: until 2026-11-14 17:00 UTC (7 days left), then
  Viewer.", or names both steps when a second live grant outlasts the first.
  No line appears when nothing would change. **Your settings** also says
  "Your access to this console ends at …" when your tier will drop to viewer
  or no access. Platform admins who have no membership on a site are listed
  on its team page with **On this site:** *Admin*.

  Account status is now its own group of badges under the role. *unconfirmed*
  is now **Email not confirmed**, and the account page explains it: it doesn't
  affect the role or password sign-in, and only a site's own single sign-on
  waits for it. On the register, the filters read **Standing role** /
  **Any standing role** and **Email not confirmed**; they match the same
  rows as before (the role filter is still the stored role, not the badge).
  Role names are translated wherever they appear, including the owner label
  on API keys.

  For developers, `KilnCMS.Accounts.Scoping.tier_source/2` returns
  `{tier, source, record}`, the tier with the branch that decided it, and
  `effective_tier/2` now returns its first element (same decisions as before).
  `Scoping.tier_changes/2` lists `{expires_at, tier}` changes ahead; the
  `tier_source_for_membership/3` and `tier_changes_for_membership/3` twins take
  an already-read membership. `KilnCMSWeb.RoleDisplay` renders them. A page
  left open past an expiry still shows the old tier until it is reloaded; the
  policies stop honouring the grant on time regardless. No migration, config
  or API change; rolling back the pin is safe. See
  [See which role applies now](../account-administration.md#see-which-role-applies-now).

<a id="webhook-secret-masked"></a>

- **A webhook's signing secret is masked on `/editor/webhooks` until an admin
  reveals it, and a revealed secret has a Copy button.** The list printed
  every endpoint's secret in plain text, so a screen share, a screenshot or a
  saved copy of the page carried all of them (#2140). Each row now shows
  `••••` and the secret's last four characters (the dots alone for a secret
  under 16 characters), and the page holds nothing more until **Reveal** is
  clicked. Reveal reads the endpoint again as that admin on the current site
  before sending the secret, so an id from another site, or one deleted in the
  meantime, reveals nothing and says "Couldn't reveal that signing secret."
  A revealed secret has **Copy**, which puts it on the clipboard and says
  "Signing secret copied.", and **Hide**. A reveal lasts until **Hide** or a
  reload. A newly added endpoint's secret starts revealed, and the notice now
  reads "Webhook added. Copy its signing secret into your receiver." An
  unreadable secret (after a `SECRET_KEY_BASE` rotation) keeps its message,
  with no Reveal or Copy.

  Who can see a secret is unchanged: `/editor/webhooks` and the endpoint
  itself stay admin-only, and the API exposes no secret. Secrets still can't
  be rotated without deleting the endpoint (#2347). No migration, config or
  API change; rolling back the pin is safe. See
  [Copy a webhook signing secret](../webhooks.md#copy-a-webhook-signing-secret).

<a id="custom-field-history"></a>

- **Custom fields are individual fields in version compare, restore and the publish-conflict panel.**
  Until now a changed custom field read as one opaque "Custom fields" blob.
  The compare modal now lists each key with its definition's label, a typed
  value (select option labels, media filename, reference title, rich text
  without tags, group `Label: value` pairs) and an Added / Removed / Changed
  pill. Media and reference titles resolve as the signed-in reader, in one
  batched read; an unreadable target shows its stored id. A retired
  definition shows its raw key.
  *Restore* (from the compare modal and the history list) now opens a
  preview, **Restore this version?**, and writes only on *Restore this
  version*; it replaces the browser confirm. The preview runs the same
  `RestoreVersion.plan/3` as the action and lists stored custom keys no
  definition declares any more as discarded. An editor with a field grant is
  told restore needs full field access instead of being offered a confirm
  that would fail. The publish-conflict panel still shows one *Custom fields*
  row and still resolves the whole map with one choice (no per-key merge), but
  now lists the per-key draft-versus-live difference beneath it.
  No API, migration or config change; nothing to do on upgrade, and rolling
  back the pin is safe. The revisions API still carries `custom_fields` as one
  whole-map change; a per-key `changed_custom_fields` is deferred. See
  [Comparing and restoring versions](../working-copy.md#comparing-and-restoring-versions).

<a id="search-leg-performance"></a>

- **Global search is several times cheaper on a large catalogue.** A
  downstream catalogue of about 4,900 documents (2,047 herbs with three name
  fields) took 1.2–1.6 s per `/api/search` sweep, so 1.8's 1.5 s
  `query_budget` cut most queries short (`partial: true`). Three legs cost
  most of it, and each was a query-shape problem:
  - **Alias and compound legs.** The match runs "the query contains the
    name", so its tsquery is built from the row, and no index can serve it:
    every search unpacked every row's `custom_fields` and built a tsquery
    per name field. Both legs now first check the row's `name_lexemes` (the
    lexemes and Han runs of its title and names, from `search_weighted`'s
    `A` bucket) against the query's, the way the title leg checks its title
    lexemes, and run the phrase match only on the rows that share one. On a
    synthetic 2,047-row table of the same shape, the alias filter went from
    15 ms to 0.3 ms.
  - **Empty names.** A missing or empty name was matched as `''`, and
    `phraseto_tsquery('')` sends a `NOTICE` to the client for every row: about
    2,500 per herbs query on that catalogue. Empty names are now skipped.
  - **Tag leg.** Every section repeated the same nearest-tag vector search,
    then ran one query per tag. A sweep now looks the tags up once. Each
    section reads the documents carrying any of them in one query, and works
    out per tag which ones it carries. When that read hits its cap, the leg
    goes back to one query per tag, so results and distances don't change.

  Flagging a field `names_record` now also re-fires the type's published
  documents, as flagging it `searchable` already did: the flag reaches
  `search_weighted`, which weights `search_vector` and feeds the new
  prefilter. A draft picks it up on its next save. Before, the alias leg
  saw a new flag on the next search, while `search_vector` kept the old
  weights until each document was saved again. Type promotion
  (`mix kiln.promote_data`) no longer copies generated columns.

<a id="quiet-image-build"></a>

- **The release image builds without warnings or notices from Kiln's own
  steps.** The GHCR build log for v1.8.0 carried about 260 warnings and
  notices. Kiln's own steps produced four kinds, each now gone:
  - Tailwind's CSS optimizer warned that `::highlight(kiln-issue)` is not a
    valid pseudo-element. It is one (the CSS Custom Highlight API), but
    Lightning CSS doesn't know it. The rule now lives in `advisory_jump.js`
    as a constructed stylesheet, adopted the first time a highlight is drawn.
  - `npm ci` printed its "new major version" and "looking for funding"
    notices. The image pins its own npm, so the build passes
    `--no-update-notifier --no-fund`.
  - The two-scheduler `mix compile` pushed dozens of files past the
    "taking more than 10s" notice. The image build raises the threshold;
    dev keeps the default.
  - `mix release` printed "skipping elixir.bat/iex.bat for windows". The
    release now sets `include_executables_for: [:unix]`.

  On the dependency side, ash_phoenix 2.3.26, ash_paper_trail 0.8.1,
  ranch 2.3.0, makeup 1.2.3 and phoenix_template 1.1.0 compile cleanly on
  Elixir 1.20, removing about 20 warnings. The OTP 29 deprecation warnings
  in yamerl, gproc, gen_smtp and chatterbox (`catch Expr`, exported
  subexpression variables, `lists:zf/2`) are switched off for the
  `deps.compile` step only, through the compiler's own `nowarn_*` options.
  The app's sources still compile with every warning on. The rest are Elixir
  1.20 warnings inside third-party packages whose latest releases still
  carry them. Fixing those needs upstream releases.

<a id="feed-relay"></a>

- **The change feed's local fan-out no longer runs in the publisher's
  process (#2083).** `KilnCMS.Delivery.Feed.publish/4` used
  `Phoenix.PubSub.broadcast/3`, which sends to every subscriber on the
  calling node before it returns, so the editor's request (or the API call,
  or the Oban job) that published paid for every feed subscriber. It now
  hands this node's half of the event to a relay,
  `KilnCMS.Delivery.Feed.Relay`, with one cast. The relays run one per
  scheduler under a `PartitionSupervisor` (`KilnCMS.Delivery.Feed.Relays`,
  started after PubSub and before the endpoint), keyed by org id, so one
  site's events pass through one relay in the order they reach it. Remote
  nodes still get one `direct_broadcast` each from the publisher, as before.
  - **What improved, and what didn't.** In the live-blog benchmark with
    10,000 in-BEAM feed subscribers, publish p99 went from 1,474 ms to
    143 ms and p95 from 357 ms to 124 ms. The goal in #2083, a 10,000
    subscriber publish p95 within noise of the 0 subscriber one, is **not**
    met: on this branch the two were 124 ms and 33 ms. The publisher no
    longer sends to the subscribers, but once 10,000 of them become runnable
    at once, the rest of the publish waits for a scheduler behind them. The
    branch numbers come from 10-minute legs, against 30 minutes for the
    `main` figures, so treat the comparison as indicative. See
    [Live blog](../benchmarks.md#live-blog-an-update-every-few-seconds).
  - **Delivery is asynchronous.** When `publish/4` returns, local
    subscribers may not have the event yet. The new
    `KilnCMS.Delivery.Feed.sync/1` waits until every event the calling
    process published to a site has reached this node's subscribers. It is
    for tests and benchmarks: a test that asserts a feed event, or its
    absence, right after a publish calls `Feed.sync(org)` first.
  - **Telemetry moved earlier.** `[:kiln_cms, :delivery, :feed, :event]`
    still fires once per event in the publisher, but now at hand-off, before
    any local subscriber has it. A dashboard that read it as "delivered" now
    reads "handed off".
  - **Delivery is at most once, as PubSub's always was.** Events waiting in
    a relay are lost if it crashes or the node shuts down, and an event cast
    to a relay that crashed just then is lost too. If no relay is running,
    the publisher broadcasts locally itself, as before. `publish/4` never
    raises or exits into the caller.
  - **Upgrade.** Nothing to do: no migration, no config, no change to the
    topic, `subscribe/1` or the event shape. Rolling back the pin is safe.

<a id="essentials-hidden-screens-hint"></a>

- **The Essentials sidebar now tells an admin where Forms, Webhooks, API keys
  and Trash went, and how to get them back in the sidebar.** Essentials keeps
  the sidebar to the daily screens plus the Configure hub, so those four
  vanished from it with no clue where to look (issue #2144). Under the
  Configure link there is now one line: "Forms, Webhooks, API keys, Trash are
  under Configure. Use Show all tools to list every screen here." The names
  are read from the nav map for the signed-in user, so a screen they cannot
  open is left out (an organisation admin's line omits API keys). Everything,
  and users without the Configure hub such as editors, see no line. Nothing is
  added to the Essentials link list, no screen moved, and there is no
  migration or setting; the hint is hidden when the sidebar rail is collapsed.
  Nothing to do on upgrade.

## Fixed

<a id="custom-sort-json-null-last"></a>

<a id="auth-pages-landmarks-autocomplete"></a>

- **The sign-in, register and reset pages now have a header landmark, one `h1`,
  and `autocomplete` on their email and password boxes (#2162).** An
  accessibility audit found auth content outside any landmark, no `h1`, and
  fields a password manager had to guess at.
  - **Landmarks and heading.** The environment banner and logo row are a
    `<header>`, and the flash toast sits inside `<main id="main">`. The page
    carries one screen-reader-only `h1` holding the page title (the tab title
    the page already had), so it follows sign-in, register and reset as the
    view changes. Each view keeps its visible heading, which stays an `h2`.
    The two-factor prompt at `/sign-in/verify` follows the same rule: its
    visible "Two-factor authentication" heading is now an `h2`, under the
    hidden `h1`. Nothing looks different.
  - **`autocomplete`.** The email box on sign-in, register and the
    reset-request form has `autocomplete="email"`. The password box has
    `current-password` on sign-in and `new-password` on register and on the
    reset-token form, as do the confirmation boxes, so a password manager
    offers to save a new password and does not fill a saved one into a "choose
    a password" box (WCAG 1.3.5).
  - **Not covered.** The email box on the magic-link request form still has no
    `autocomplete`: it is rendered inside the library's component, and
    changing it would mean copying that whole component.
  - **For overlay authors.** Two more library renders are now Kiln copies:
    `KilnCMSWeb.AuthIdentityInput` (the email box) and
    `KilnCMSWeb.AuthResetRequestForm` (the `/reset` request form), next to
    `AuthSignInForm`, `AuthRegisterForm`, `AuthResetForm` and
    `AuthPasswordInput`. `KilnCMSWeb.AuthOverridesTest` renders the sign-in,
    register and reset-token forms against upstream's and fails if they differ
    by more than the `autocomplete` attribute, so re-run it when bumping
    `ash_authentication_phoenix`; the `/reset` request form is not in that
    comparison, so re-read `AuthResetRequestForm` against upstream's
    `Password.ResetForm` by hand.
    `AuthPasswordInput.password_field/1` and `password_confirmation_field/1`
    now require an `autocomplete` attribute; an overlay that calls them must
    pass one. No configuration, migration or upgrade step.

- **`custom_sort` treats a stored JSON `null`, array or object as no value, and
  page 2 of a keyset-paged `custom_sort` no longer fails on one.** On the
  JSON:API and GraphQL reads, a record whose custom field was stored as a JSON
  `null` used to sort first (Postgres orders a jsonb `null` below everything),
  and one holding an array or object sorted by jsonb order; if such a value
  was the last row of a page, the keyset read for the next page failed because
  the cursor could not be bound back into the filter. Now all three sort
  together with records that lack the key, last in ascending and descending
  order alike, and the next page reads. Callers sorting on a sortable scalar
  field see a change only if some record holds one of those values (for
  example after a field was retyped); everything else is unchanged. Not a
  breaking change, since the documented rule is "records without the field sort
  last".

<a id="form-field-rename"></a>

- **Renaming a form field's machine name saves on Enter, shows on the canvas,
  and the Entries tab no longer passes old keys off as current fields.** The
  field settings panel had no submit button, so Enter in **Machine name** did
  nothing and a reload showed the old name; a refused name snapped back with
  only a flash; the canvas never showed machine names; and the Entries tab
  printed each submission's raw keys, so entries received before a rename
  kept showing the old key (such as `string`) and looked as if the rename had
  not saved (#2139).

  The panel now has a **Save** button, and Enter in any input saves too. As
  you type, each change saves only the input it came from, so one refused
  value no longer blocks edits to the others. A refused value stays in its
  input, marked invalid, with the reason underneath; the panel says
  **Saved.** after a save that changed something. Each field on the canvas
  shows its machine name. Renaming a field on a form that has entries adds
  "Entries already received keep the old key “old”." to the panel, and the
  Machine name hint now says that entries keep the old key while exports and
  API clients use the new one. The Entries tab lists each value under its
  current field's label and machine name, and groups keys no current field
  has under **From a renamed or removed field**.

  Stored submissions are not rewritten. Still open: the CSV export drops an
  old key's values (#2342), an autoresponder `[field:old]` token renders
  empty after a rename (#2343), and there is no option to rewrite old keys
  (#2344). Nothing to configure or migrate. See
  [Edit and rename form fields](../forms.md#edit-and-rename-form-fields).

<a id="public-form-page"></a>

- **`/forms/<slug>` is the form's own page: an active form, inside the site's
  layout.** The form builder showed `/forms/<slug>` under every form's name,
  and that address answered 404: the only browser page for a form was the
  iframe document at `/forms/<slug>/embed`, which the forms list linked
  instead (#1783) and which looks unfinished outside a frame. A GET there now
  renders the form's name, description and fields in the site's header and
  footer, posting to `POST /forms/<slug>` like a form block. Under a language
  prefix (`/fr/forms/<slug>`) it posts back under the prefix, so a refused
  submission re-renders in the visitor's language. The page is served with
  `Cache-Control: public, max-age=60, stale-while-revalidate=300`,
  `Vary: Accept-Language` and `X-Robots-Tag: noindex`, matching the embed
  document's `noindex`; forms stay out of `sitemap.xml`.

  It is not a new route and `forms` is not a reserved path segment: the page
  is the last fallback of the delivery 404, the slot the event index already
  takes. A site with a content type of its own at `/forms` keeps its entries,
  and a path alias, redirect, lock page or teaser at the address still wins.
  An inactive form, an unknown slug and another site's slug 404 as before and
  are recorded on the 404s list.

  In the console, the builder's header links the page's full address on the
  site's host (or says "Not public while inactive.") and **Preview** opens it;
  the forms list's **Hosted form** address is now the page rather than
  `/embed`. The thank-you page after a submission is still the plain card
  without the site's layout. Nothing to configure or migrate. See
  [Share a form at its own address](../forms.md#share-a-form-at-its-own-address).

<a id="webhook-delete-labelled"></a>

- **A webhook's Delete is a labelled button on its row, and the edit form has
  one too.** Delete on `/editor/webhooks` was an unlabelled grey trash icon
  after three text buttons (Ping, Disable, Edit), easy to miss; an admin
  looking for it concluded an endpoint had to be disabled before it could be
  deleted. It never did, and the row now shows a red **Delete** with its icon
  for every endpoint, active or disabled. The edit form gains **Delete
  webhook** beside Save and Cancel. Both ask the same question, which now says
  what deleting does: "Delete this webhook? Queued deliveries, including
  retractions, won't be sent. Delivery history is kept." The old prompt said
  only that deliveries would stop. Who may delete is unchanged (admins only),
  and the `docs/webhooks.md` line that said deleting an endpoint takes its
  delivery history with it, untrue since deliveries outlive their endpoint,
  is corrected. On a narrow screen the row's actions now wrap below the
  endpoint's details instead of beside them. See
  [Delete an endpoint](../webhooks.md#delete-an-endpoint).

<a id="columns-child-fresh-form"></a>

- **Nested column events work on a freshly opened page.** `AshPhoenix.Form.params/1`
  carries only touched nested forms, so before the first `phx-change` it had no
  `"blocks"` key. `inject_children/2` then inserted `"blocks" => nil` and the next
  `Form.validate/2` crashed in `condense/2` (`Enumerable` not implemented for `nil`).
  Every `apply_children/2` caller (`col_add_child`, `col_remove_child`, `col_reorder`,
  `col_update_child`, …) now starts from `Preview.form_params_with_blocks/1`, which fills
  the list from the form's values, and `inject_children/2` no longer creates a nil key.

<a id="phoenix-1-8-16-subscription-pushes"></a>

- **The Phoenix stack moves to 1.8.16 (phoenix_pubsub 2.4.1, phoenix_live_view
  1.2.13, websock_adapter 0.7.0), together with absinthe_phoenix 2.0.6.** Phoenix
  1.8.16 replaces PubSub's custom dispatchers with per-subscription senders:
  Phoenix's channel server dispatcher now passes broadcasts to the default
  dispatch, which ignores the `metadata: {:fastlane, transport_pid, serializer, _}`
  shape. absinthe_phoenix 2.0.5 still subscribes each GraphQL subscription
  document with that metadata. On 1.8.16, a `subscription:data` broadcast
  therefore went to the channel process instead of the socket's transport.
  absinthe_phoenix's channel then dropped it in its catch-all `handle_info`. The
  result was that every subscription accepted the subscribe call and never
  pushed anything, in production as well as in tests (the six failing
  `assert_receive` cases in `graphql_subscription_test.exs` and
  `graphql_limits_test.exs`). absinthe_phoenix 2.0.6 subscribes with a sender
  instead (absinthe_phoenix#113/#114). `mix.exs` now requires
  `absinthe_phoenix >= 2.0.6` and `phoenix ~> 1.8.16`, so the lock can't pair
  them wrongly again.

<a id="exla-fine-pin"></a>

- **A from-scratch `KILN_ML=1` build compiles EXLA again.** The Phoenix
  1.8.16 bump above also moved the test-only `lazy_html` to 0.1.14, which
  requires `fine ~> 0.2.0`, so the lock took fine 0.2.0. EXLA 1.0.0 allows
  `fine ~> 0.1` but its NIF does not compile against 0.2 (`'try_decode' is
  not a member of 'fine::Decoder<xla::Shape>'`). Lean builds were
  unaffected. The `-ml` image and any overlay building with `KILN_ML` on
  failed, and an overlay could not pin around it, since
  `mix kiln.plugins.doctor` holds core dependencies at core's lock.
  Two guards now hold it, landed in parallel: the KILN_ML dependency list
  requires `fine ~> 0.1.0` (#2212), and `lazy_html` is capped below 0.1.14
  (#2213), so a lean lock refresh, where the KILN_ML list isn't loaded, can't
  pull fine 0.2.0 back in either. Both lock entries are back to their v1.8.0
  versions; lift both guards together once an EXLA release builds against
  fine 0.2. CI's ML leg missed the break because EXLA
  caches `libexla.so` under a key without `fine`, and the leg restored that
  cache on the lock change. It now rebuilds the NIF from source whenever its
  cache isn't an exact hit. Overlays that re-seeded `project.lock` from the
  1.8.16 bump re-seed once more.

<a id="new-menu-button"></a>

- **The content list's "New" menu is a real `<button>` with `aria-expanded`.**
  Past three content types, `/editor` folds its "New …" buttons into one
  menu. Its trigger was a `<summary>` styled as a button, with the marker
  hidden; an accessibility walkthrough found it wasn't announced as a button.
  It is now a disclosure: a `<button aria-expanded aria-controls>` that shows
  and hides the panel of per-type buttons. The shared `data-autoclose`
  handler in `app.js` closes it on a click outside or on Escape, and only
  claims Escape while the menu is open, so Escape in the search box or a
  modal keeps its focus. The old `<details>` also lost its `open` state on
  every LiveView patch, so a list refresh behind an open menu snapped it
  shut; the new one keeps its state across patches it didn't cause.

<a id="public-muted-text-contrast"></a>

- **Secondary text on public pages and in the shared form components moves from 50-60% to 70% opacity, so it clears WCAG 1.4.3 (4.5:1).**
  Muted text is `text-base-content` at reduced opacity, and nothing renders
  wrong when the opacity is too low. Measured against the theme tokens in
  `assets/css/app.css`, `/60` is 4.12:1 on the light theme's page background
  and `/50` is 3.09:1; `/70` is about 5.1:1 or better on every surface in both
  themes. The public templates (blog and event indexes, search, newsletter
  confirmation, the home page), the release preview, the setup wizard, public
  forms, the block components, form field hints, the empty-state text, the
  password show/hide toggle and the flash close icon (`opacity-40` to
  `opacity-70`) now use `/70`. Overlays and plugins that copy these classes
  are unaffected; nothing changes in markup structure or in any API.
  - **A guard keeps it that way.** `test/kiln_cms_web/muted_text_contrast_test.exs`
    scans `lib/kiln_cms_web` for `text-base-content/N` (and bare `opacity-N`)
    below 70. Public paths must be at zero. The console is a ratchet against
    `test/kiln_cms_web/muted_text_console_baseline.txt`: a file may not gain
    offenders, and the count only goes down. A non-text use (an icon glyph, a
    disabled control) is exempted with a `contrast-ok: <why>` comment on the
    same line or the line above.
  - **What the guard does not do.** It reads class names, not rendered
    contrast: it does not run axe (there is none in the repo), and it does not
    see templates authored outside this repo, such as a plugin's. The
    authenticated console still has muted text below the floor; it is counted
    in the baseline and lowered as files are touched.
  - **Contributors.** After lowering a console count, regenerate the baseline
    with `KILN_UPDATE_CONTRAST_BASELINE=1 mix test test/kiln_cms_web/muted_text_contrast_test.exs`
    and commit the file. See [Muted text](../design-language.md#muted-text).
  ([#2163](https://github.com/The-Verscienta/kiln_cms/issues/2163))

## Security

<a id="ecto-query-cache-advisory"></a>

- **ecto 3.14.3 fixes EEF-CVE-2026-118391 (unbounded query cache growth), and
  ash_sql 0.8.7 replaces the retired 0.8.4 (query cache returned wrong rows).**
  ecto 3.14.2's query cache grew without bound on queries with
  interpolated JSON paths or splice lists (high). ash_sql 0.8.4 was retired for security the
  same day: an Ecto query cache issue could make a query return
  unpredictable results. Both were published 2026-11-04, after 1.8.0, and
  fail `mix hex.audit` on every branch until taken. Lock-only: `mix
  deps.unlock ecto ash_sql`, nothing else moved.
  ([#2204](https://github.com/The-Verscienta/kiln_cms/pull/2204))

<a id="compound-leg-hoist"></a>

- **Global search's compound leg is about 3× cheaper per candidate name.**
  The leg matches a name written spaced or joined differently from the query
  (`huang qi` for Huangqi, `xiao yao san`). It rebuilt each rewrite's
  `to_tsvector` and each span's `phraseto_tsquery` for every candidate row ×
  variant, though neither depends on the row. Both are now scalar subselects
  Postgres runs once per statement, and a name's own tsvector and tsquery are
  built once per name in a `LATERAL ... OFFSET 0`. Same rows, same order;
  empty names are still skipped before any tsquery is built. On a synthetic
  2,047-row table with 16 variants, `EXPLAIN ANALYZE` went from about 30 ms to
  about 10 ms. Verscienta reported 1.6–4.0 s for the leg on multi-word queries
  after #2205; that figure has not been re-measured on their data.
  ([#2367](https://github.com/The-Verscienta/kiln_cms/pull/2367))
