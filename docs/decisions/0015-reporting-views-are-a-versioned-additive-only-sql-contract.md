# 0015. The reporting views are a versioned, additive-only SQL contract

- **Status** — accepted; unreleased.
- **References** — [#2295](https://github.com/The-Verscienta/kiln_cms/issues/2295); guide: [docs/reporting.md](../reporting.md).
- **Changelog** — the Unreleased Added section of [CHANGELOG.md](../../CHANGELOG.md).

## The problem

Custom fields live in one JSONB map per record, so a BI tool cannot select
`price` as a column. Analysts want SQL. Giving them the base tables would
expose private fields, drafts, console accounts, embeddings and password
hashes, and the JSONB shape is not a contract. Any SQL we do give them
becomes something people build dashboards on.

## Decision

**Kiln ships plain, read-only views in a versioned schema,
`kiln_reporting_v1`, and treats their columns as a public contract that is
additive-only in 1.x.** A breaking change ships as `kiln_reporting_v2` beside
it, never as an edit to v1.

- **Plain views, not materialized.** A materialized view is stale between
  refreshes, and staleness here is a leak window: a field flipped to private
  would stay exported until the next refresh. It would also need a refresh
  job, a unique index and refresh locks. Where BI load hurts, the answer is a
  read replica, which is infrastructure.
- **No runtime DDL.** The views come from a normal `mix ash.codegen`
  migration (a `custom_statements` entry of `KilnCMS.CMS.Content`), the same
  as the other DDL Kiln owns. Field definitions are per site, so a typed view
  per field would be data-driven DDL at deploy time, with the lock, rollback
  and multi-node race problems already rejected for dynamic types. Because the
  allowlist reads `field_definitions` live, adding, renaming or privatising a
  field needs no regeneration.
- **An allowlist, not a denylist.** A key reaches a view only while a live,
  non-private, non-`user`, top-level definition of the record's own site and
  type names it. A denylist would leak orphaned and undefined keys, and
  anything a later field type adds.
- **Published, public rows only; ids for references.** A stored reference
  snapshot carries the target's title and slug as of when it was taken,
  whatever the target's state, so the views project it to `{id, type}`.
- **No typed columns in v1.** `value_text` / `value_json` are exposed and the
  analyst casts. Cast helper functions were rejected: `text::date` and
  `text::timestamptz` are STABLE, so marking them immutable is wrong, and
  exception blocks open a subtransaction per row.
- **The role is a script, not a migration.** `mix kiln.reporting.sql` prints
  it. Managed Postgres often lacks `CREATEROLE` for the app user.
- **Tenancy is a column.** There is no row-level security and a `current_setting`
  filter is resettable by the session, so the role is deployment-wide and the
  docs say not to hand it to a tenant.

## Consequence for migrations

Postgres refuses to alter or drop a column that a view reads, so the views
**pin** the columns they reference: the content-table columns, and the
`field_definitions` / `type_definitions` columns the allowlist joins. A
migration that removes, renames or retypes one fails at deploy even when
expand/contract says the old release no longer reads it. The rule, enforced by
`mix kiln.migrations.check` and described in
[docs/releasing.md](../releasing.md#migrations-expand-migrate-contract): the
migration drops **both** views of the pair first and recreates them, in the
same function. It applies to `up` and `down`, to the Ecto DSL and raw SQL, and
to the definition tables (every viewed table's pair). A `kiln:contract-ok`
marker does not excuse it, since the failure does not depend on what the old
release reads.

## Rejected

- Typed wide per-type views, generated at deploy or by a job.
- Materialized views, or a separate replica schema.
- Reference `_label` and media `_url` columns (stale snapshots re-expose
  unpublished titles).
- A shared SQL types module, until the other typed-SQL work has code.
- Row filtering by a session setting.
