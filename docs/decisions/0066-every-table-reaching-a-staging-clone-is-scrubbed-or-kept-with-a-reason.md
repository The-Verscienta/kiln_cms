# 0066. Every table reaching a staging clone is scrubbed or kept with a reason, and a plugin's undeclared table stops the scrub

- **Status** — accepted (2026-11-16).
- **References** — [#2975](https://github.com/The-Verscienta/kiln_cms/issues/2975)
  (plugins declare a staging scrub), building on
  [#2970](https://github.com/The-Verscienta/kiln_cms/pull/2970), which made
  the core scrub cover every core table and fixed
  [#2721](https://github.com/The-Verscienta/kiln_cms/issues/2721). The guide
  is [staging-environments.md](../staging-environments.md#plugin-tables).
- **Changelog** — Unreleased, under Added
  ([long form](../changelog/unreleased.md#plugin-staging-scrub)) and Breaking
  ([long form](../changelog/unreleased.md#plugin-staging-scrub-refuses-undeclared)).

## The problem

`mix kiln.staging.scrub` turns a clone of production into something an
operator can hand to a reviewer. It is only as good as its list of tables:
a table it does not know about reaches the clone with production's rows in
it, and nobody is told.

For the core, #2970 closed that: `KilnCMS.Staging.Scrub.dispositions/0` is
derived from the lists the scrub works through, and
`test/kiln_cms/staging/scrub_coverage_test.exs` reads every table in the
test database and fails on one that is neither in it nor in a keep-list with
a reason. A new core table cannot reach a clone until someone decides.

That test runs in the core's CI, against the core's schema. An overlay's
domains, and the plugins in `projects/`, add tables the core has never seen.
Until this change the guide said so and left it there: "Tables a plugin
owns. The scrub only knows the core schema."

## The decision

**Every table that reaches a staging clone is purged, rewritten, or kept
with a reason. For the core that is a test. For a plugin or an overlay it is
a declaration, checked by the scrub itself against the database it is about
to change, and the scrub refuses to run while a table has none.**

### The declaration

A plugin declares `c:Kiln.Plugin.staging_scrub/0` (`kiln_plugin` 1.5): a list
of `{:purge, Resource}`, `{:rewrite, Resource, set: [attribute: value]}` and
`{:keep, Resource, "reason"}`. It defaults to `[]`.

It names **Ash resources, not tables**. A resource tells the scrub which
domain owns it, so a plugin can only declare its own tables and never a
core one, and it tells the scrub each attribute's type, source column,
nullability, identities and relationships, so a rewrite is checked before it
runs: the value must cast and dump to the column's type, `nil` must be
allowed, and a rewrite of a primary key, an identity's attribute, the tenant
attribute or a `belongs_to` attribute is refused (purge the table instead).

It is **plain data, no functions**. A function could do anything, and the
scrub would only learn what when it ran it, half-way through changing the
clone. Data can be read and checked in full first.

### Which tables count

The AshPostgres resources of each plugin's `c:Kiln.Plugin.domains/0`, and
their AshPaperTrail version resources, which are tables of their own: a
rewrite that clears `email` leaves every old value in the version table.
A domain in `:ash_domains` that is neither the core's nor any plugin's is an
overlay's, and its tables count too, reported under "(no plugin)". Nothing
can declare those except a plugin, so the fix is to move the domain into a
plugin's `domains/0`.

### Content is kept without an entry

A content type's table, its version table and a graduated join table are
kept unless a column looks personal (`KilnCMS.Staging.PluginScrub.personal_column?/2`,
the same test the core coverage test applies to the core's kept tables).
Content is what a staging clone is for, and the core keeps its own the same
way. A content type with an `email` or an `ip` column is the exception the
author has to think about, so it must be declared.

### Refuse before anything changes

`KilnCMS.Staging.PluginScrub.plan!/1` reads every declaration strictly and
checks it against the database before the first row changes: a callback that
raises or returns the wrong shape, an entry naming a resource the plugin
does not own, a rewrite the database would reject (a generated column, a
non-nil value under a unique index, `nil` under `NOT NULL`), an undeclared
table that exists, and a foreign key with `ON DELETE RESTRICT` or
`NO ACTION` that would stop a purge part-way. `KilnCMS.Staging.scrub!/1`
runs it before it pauses any queue, and `KilnCMS.Staging.Scrub.run/1` runs
it again so no caller can skip it.

A refusal leaves the clone as production had it. That is not safe to share
either, but it is obviously not scrubbed. A clone scrubbed half-way looks
done and is not.

### Plugin tables first, in one transaction

The plugin steps run before anything in the core, in one transaction. The
checks cannot see everything (a `CHECK` constraint, an expression index, a
trigger), and a step that fails on one rolls back every plugin table with no
core row changed yet. Going first also means a plugin row that references a
core row the scrub empties is already gone when the core gets there.

### The doctor checks the declaration; the scrub enforces coverage

`mix kiln.plugins.doctor` fails on an unusable declaration, the same checks
`plan!/1` makes short of the database. An undeclared table is only a note
there: a site that never clones production into staging is not broken by
one, and failing precommit would push its authors to write keeps they had
not thought about. A plugin's own test suite can hold it to the rule with
`KilnCMS.Staging.PluginScrub.assert_covered!/2`, which needs no database.

## What was rejected

- **The column heuristic alone** (scrub any table with a personal-looking
  column, keep the rest). Column names do not say what a `notes` or a
  `payload` holds. The heuristic is a second net, for the core's kept tables
  and for content kept by default; on its own it would keep exactly the
  tables nobody looked at.
- **Purge undeclared tables by default.** It would delete data the operator
  wanted (a venue list, a price table) without asking, and staging would stop
  being a copy of production. It also has to guess an order across foreign
  keys. A refusal costs one line of declaration; a silent purge costs a
  confusing staging site.
- **Warn and carry on.** The scrub runs inside `scripts/staging.sh up`,
  unattended. A warning scrolls past and the clone is shared with the table
  in it, which is the failure this exists to prevent.
- **Functions or MFAs for rewrites.** Arbitrary side effects, run mid-scrub,
  that nothing can check beforehand.
- **Table names instead of resources.** No owner, so a plugin could name a
  core table or another plugin's, and no types, so a rewrite could not be
  checked until the database rejected it.
- **An operator keep-list in config** (`config :kiln_cms, :staging_scrub,
  keep: [...]`). Every plugin that owns tables is an overlay its operator
  can edit, so the declaration is already theirs to write. A config keep
  would be a second, unreviewed keep-list beside the one in the plugin's
  code.
- **The doctor failing on an undeclared table.** See above: it would break
  precommit for overlays that never stage.

## What is accepted

- **A table made by a raw migration, with no Ash resource, is not seen.**
  The scrub finds plugin tables through their resources. For the core, the
  coverage test reads the database itself and catches such a table; there is
  no equivalent for an overlay's schema. An overlay that creates a table
  outside Ash owns the decision about it.
- **`:context` multitenancy is refused, not handled.** A schema per tenant is
  out of the scrub's reach, so a resource that uses it makes the declaration
  unusable rather than silently skipped.
- **The doctor and `assert_covered!/2` cannot see the database**: unique
  indexes, generated columns, `CHECK` constraints and foreign keys are
  checked only by `plan!/1` when the scrub runs, and what it cannot see is
  caught by the transaction.
- **An existing overlay with a non-content table has to add a declaration**
  before its next staging scrub. That is the point of the change, and the
  Breaking entry says what to write.
