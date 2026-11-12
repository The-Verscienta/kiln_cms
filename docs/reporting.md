# SQL reporting views

Kiln stores custom fields in one JSONB map per record, so a BI tool cannot
`SELECT price FROM posts`. The `kiln_reporting_v1` Postgres schema gives
analysts read-only views over published content instead: the core columns
plus a `custom_fields` map that holds only fields that are safe to export,
and a tall one-row-per-field view that Metabase, Superset or Looker Studio can
filter and pivot. This guide is for the operator who sets the role up and the
analyst who queries it.

The views are a public SQL contract, additive-only in 1.x
([decision 0015](decisions/0015-reporting-views-are-a-versioned-additive-only-sql-contract.md)).
A breaking change would ship as a new `kiln_reporting_v2` schema next to this
one, not as an edit to it.

## What the views are

Every content table gets two views, in the `kiln_reporting_v1` schema:

| View | One row per | Use it for |
|---|---|---|
| `kiln_reporting_v1.pages`, `.posts`, `.entries` (and one per overlay content type) | published record | listing records, with `custom_fields` as JSONB |
| `kiln_reporting_v1.<table>_field_values` | published record and allowed field | filtering and pivoting one field across records |

`entries` holds every dynamic content type (those created in the type
builder). An overlay type made with `mix kiln.gen.content` gets its own pair,
named after its table.

They are plain views, not materialized ones: every query reads the live
tables, so there is nothing to refresh and a change takes effect on the next
query. They are created by a normal migration; there is no runtime DDL and
nothing to switch on.

### Columns of the wide view

| Column | Meaning |
|---|---|
| `id`, `org_id` | the record and its site (organization) |
| `title`, `slug`, `locale`, `audience` | as in the editor |
| `state` | always `published` (see the row filter) |
| `published_at`, `inserted_at`, `updated_at` | timestamps |
| `custom_fields` | JSONB: field name to stored value, allowed fields only; `{}` when none |

`entries` adds `type_definition_id`, `type_name` (the type's name) and
`type_slug` (its URL path segment). `search_text`, embeddings, working copies
and the access password hash are in no view.

### Columns of the field-values view

| Column | Meaning |
|---|---|
| `org_id`, `record_id` | the site and the record (`id` of the wide view) |
| `type_name` | `page` / `post` for those tables, the type's name for `entries` |
| `field_name`, `field_type` | the field's name and its type (`string`, `integer`, `reference`, ...) |
| `multiple` | whether the field holds a list |
| `value_text` | the value as plain text: a string without quotes, a number, a list as JSON; a single reference reads as its id |
| `value_json` | the value as JSONB |

### Which rows and fields appear

A row is visible while it is `published`, not archived, has no access
password, and has the `public` audience. Drafts, scheduled and archived
records, gated and members-only content never appear, so this is not a
full-data role.

A field appears only while a live field definition of that record's own site
and type names it, and the definition is not `private`, not a `user` field,
and not a link field or a group sub-field. The list is read live: flipping a
field to private, renaming, retyping or deleting it changes the next query.
Keys with no definition (orphans) are dropped. A per-role read restriction
on private custom fields ([granular-rbac.md](granular-rbac.md#per-custom-field-grants-and-read-restrictions))
changes nothing here: the views read as a Postgres role with no Kiln user, and
already leave out every private field. Reference values are reduced
to `{"id", "type"}`; see the limits below.

## Set up a read-only role

Kiln prints the SQL; it never runs it, and it connects to no database.

1. Print the script and save it:

   ```bash
   mix kiln.reporting.sql --role kiln_bi --database kiln_cms_prod > kiln_bi.sql
   ```

   In a release, run the same task from your build checkout (the output
   depends on the compiled content types, not on the database). `--role`
   defaults to `kiln_bi`; `--database` is optional and adds a `CONNECT` grant.
   Both must match `^[a-z_][a-z0-9_]{0,62}$`, or the task refuses.
2. Open `kiln_bi.sql` and replace `REPLACE_WITH_A_LONG_RANDOM_PASSWORD`. Do not
   commit the file.
3. Run it as a role that may create roles:

   ```bash
   psql "$ADMIN_DATABASE_URL" -f kiln_bi.sql
   ```

   Managed Postgres often withholds `CREATEROLE` from the app user; use the
   provider's console or admin role.
4. Point the BI tool at the new role. Its `search_path` is set to
   `kiln_reporting_v1`, so `SELECT * FROM posts` reads the view.

The script creates the login role, grants `USAGE` on the schema and `SELECT`
on each view, and sets `statement_timeout` to `60s` and
`default_transaction_read_only` to `on`. It touches nothing in `public`.

**Re-run the grants after an upgrade that adds views, and after a demo reset.**
A `GRANT` covers the views that exist when it runs: a new content type or a
new release adds views the role cannot yet read. A demo reset drops and
re-creates the schema, so grants on it need applying again. The `CREATE ROLE`
line fails harmlessly when the role exists; the `GRANT` lines are idempotent.

### Replica, SSL and timeouts

- **Connect to a read replica**, not the primary. BI queries scan a lot, and
  a replica also makes read-only a property of the server.
- **Require SSL** on that connection (`sslmode=verify-full`).
- **The role settings are advisory.** A role can `SET` them for its own
  session, including turning `default_transaction_read_only` off. They guard
  against mistakes. The role still has `SELECT` only, so it cannot write, but
  only a replica enforces read-only.

## Query examples

The wide view, one field out of the JSONB:

```sql
SELECT title, custom_fields ->> 'region' AS region
FROM posts
WHERE custom_fields ->> 'region' = 'EU';
```

The tall view, a typed aggregate. There are no typed columns in v1, so cast
the text yourself and guard the cast, because the table can hold off-type
values (a retype leaves old values behind):

```sql
SELECT v.org_id,
       sum(v.value_text::numeric) AS total
FROM entries_field_values v
WHERE v.type_name = 'product'
  AND v.field_name = 'price'
  AND v.field_type IN ('integer', 'float')
  AND v.value_text ~ '^-?[0-9]+(\.[0-9]+)?$'
GROUP BY v.org_id;
```

Filtering on `field_type` and the regular expression keep a stray value from
raising "invalid input syntax" in the middle of a report. For dates use
`v.value_text::timestamptz` the same way, after checking the shape.

### In Metabase

1. Add the database with the `kiln_bi` credentials, SSL on.
2. Open **New > SQL query** and paste a query like the one above.
3. Save it as a question. Metabase reads the column types from the result, so
   the cast gives it a numeric column to chart. To reuse it, save it as a
   model and build questions on the model.

## Limits to know before you rely on it

- **Every site's rows are in the views.** `org_id` is a column, and the role
  is deployment-wide. There is no per-site filtering inside the database. Do
  not give this role, or a BI tool connected as it, to a tenant.
- **No typed columns in v1.** Field definitions are per site, so site A's
  `price` can be an integer and site B's text; one deployment-wide view cannot
  type it. Use `value_text` / `value_json` and cast, as above.
- **Published, public rows only.** There is no view of drafts.
- **References are `{id, type}` only.** The stored title and slug are not
  exposed, because they were captured whatever state the target was in and
  can name a draft. The target ids are visible, and a view does not check
  that the target is public. Join `<table>.id` to resolve a title.
- **Media is exposed as stored.** A media field carries the snapshot a
  published page already links to: `id`, `url`, `alt`, `width`, `height`,
  `mime_type`, `focal` and `variants` with their urls.
- **Locales and shared fields.** A view shows what is stored on the record
  itself. A sibling locale that lacks a value, or a field shared with another
  record, may show less than the API serves.
- **`unpublish_at` lags.** A record past its `unpublish_at` stays visible
  until the minute sweep unpublishes it, the same as on delivery.
- **Delete, then recreate, a field and the old value returns.** Stored values
  are never cleared when a definition goes. Create a field of the same name
  again and the old value is exposed again, if the new definition is not
  private. Retyping behaves the same: off-type values stay.
- **A stored computed value outlives a private flip.** A computed field stores
  its result, and a field that was public when it was computed may later be
  made private; the stored value is only recomputed on the next save of the
  record.

## Upgrading and rolling back

The views arrive with a migration, so they exist after the deploy that
includes it. Rolling the pin back does not run the migration's `down`: the
views stay in place and keep working, and the older release ignores them.
A migration that changes a column a view reads must drop the views first;
[`releasing.md`](releasing.md#migrations-expand-migrate-contract) has the rule.

Overlay projects: existing `mix kiln.gen.content` types do not have views yet.
Run `mix ash.codegen` and commit the migration it writes before deploying; see
the upgrade notes for v1.9.0 in `CHANGELOG.md`.

## What can go wrong

| You see | It means |
|---|---|
| `permission denied for schema kiln_reporting_v1` | the role has no `USAGE`; re-run the script |
| `permission denied for view ...` or `relation "..." does not exist` | the view is new since the grants ran, or it is missing because the migration has not run; re-run the grants and check `mix ecto.migrations` |
| `permission denied for table posts` | the query names a base table; the role reads views only |
| `canceling statement due to statement timeout` | the 60s limit; narrow the query, or raise the role's `statement_timeout` |
| `cannot execute INSERT in a read-only transaction` | working as intended |
| `invalid input syntax for type numeric` | an off-type or text value reached a cast; filter on `field_type` and the value's shape first |
| `CREATE ROLE` says the role exists | fine on a re-run; the grants after it still apply |
| `kiln.migrations.check` reports `reporting_view_pin` | a migration changes a column the views read; see `releasing.md` |
