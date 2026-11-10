# 0025. A site declares which custom fields get range and sort indexes, in config

- **Status** — accepted (2026-11-10).
- **References** — [#2359](https://github.com/The-Verscienta/kiln_cms/issues/2359),
  tier 2 of [#2291](https://github.com/The-Verscienta/kiln_cms/issues/2291)
  (the GIN index of PR #2321); D4 and D17 in `KilnCMS_Project_Plan.md`.
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md).

## The problem

`custom_filter` and `custom_sort` read a JSONB map. The global GIN index of
#2291 serves containment (`eq`, `in`, list membership). Range (`gt`…`lte`) and
sort need a btree, and a btree is per field. Field names are per-site runtime
data (`FieldDefinition` rows), but D4 and D17 rule out runtime DDL and the
project rule is that migrations are written by `mix ash.codegen` from the
resource, never by hand or by a task that reads the database. The `pages`,
`posts` and `entries` resources are core's, so a site had nowhere to say
"index `price`".

## Decision

- **The names are config, read at compile time.**
  `config :kiln_cms, :indexed_custom_fields` is a list (every content table)
  or a map of table to list. `KilnCMS.CMS.Content` turns each name into two
  `custom_indexes` entries per table, so `mix ash.codegen` writes the
  migration and the resource snapshot. The default is empty: core ships no
  such index, and no site pays for one it did not ask for. The names are
  validated when the build compiles (a strict pattern, 24 characters,
  Postgres's 63-byte index-name limit per table) rather than when a migration
  fails.
- **Two btrees per name and table, `org_id` first.** The indexed expression is
  the one `custom_sort` already orders by, a `CASE` that reads a stored JSON
  `null`, array or object as `NULL`, over `custom_fields -> 'name'`. A btree
  cannot serve `DESC NULLS LAST` backwards, so each direction has its own.
  The same expression serves the range operators, which now compare it for
  every field (see below). `org_id` leads because under strict tenancy every
  API read carries `org_id = ?`; an index without it would walk other
  tenants' rows for a sort with a limit.
- **Only a listed name is inlined as a SQL literal.** Postgres matches an
  expression index against the query, and a generic plan (what a prepared
  statement gets after its fifth execution) sees a bound field name as an
  unknown. The query therefore inlines the name, after checking it is in the
  config for that table and matches the pattern. Everything else keeps a bound
  name.
- **The semantics do not depend on the config.** Range predicates compare the
  `CASE` expression for every field, indexed or not, so the same request
  returns the same rows on every site. This changes one accidental behavior:
  a stored array or object used to satisfy `gt` against a number. It is in
  the changelog.
- **`mix kiln.custom_fields.index --check` is read-only.** It reports, in both
  directions, a listed name with no or an invalid index, an index no name asks
  for, a name no field carries and an ineligible type. It never creates or
  drops anything.
- **Integer, float, date and datetime only.** A string btree can exceed the
  ~2.7 KB index row limit; a boolean has no selectivity.

## Rejected

- **Promote the field to a compiled attribute (the D4 answer) and do nothing
  else.** Right for a field every page has; wrong for a long-tail field an
  admin defined in the UI that a site range-filters on. It stays the advice
  where it fits.
- **A task that creates indexes from the registry, or `CREATE INDEX` at
  runtime.** Runtime DDL (D4/D17), and renames, retypes and deletes would leave
  stale indexes while environments drift.
- **A flag on `FieldDefinition`.** The registry is data; an index is schema.
  The flag could be set without an index existing, and the index would exist
  without anything in the repository saying why.
- **One expression index for all names.** Not possible: a btree orders one
  expression.
- **`all_tenants?: true` (an index without `org_id`).** Smaller, and what a
  tenant-less delivery read would use, but a sorted, limited read in one
  tenant would walk the others.

## Consequences

- Each name costs two index updates on every save of a record, whether or not
  the save touches the field (`custom_fields` is rewritten whole, and an
  expression index over it is not a heap-only-tuple candidate). The cost is
  measured in the benchmarks and stated in the API guide; the per-table map
  keeps a site from indexing `entries` for a field only `posts` has.
- Adding a name is an additive concurrent index build and removing one a
  `DROP INDEX`; neither reads data, so both pass the expand/contract check
  and the previous release ignores the indexes. A queried name answers
  correctly, from the table, until its build finishes.
- The list is compile-time, so an overlay keeps it in its own config and runs
  `mix ash.codegen` in its build, like any overlay schema; the core's CI
  drift check sees an empty list.
- A delivery read with no tenant (`strict_tenancy: false`) cannot use the
  `org_id`-leading indexes for a sort. A site on a single tenant is unaffected.
