# 0014. A built-in name always wins; `custom_filter` / `custom_sort` are the stable form

- **Status** — accepted; unreleased. The alias rewrite, `custom_sort` on search
  and the client changes are in
  [#2292](https://github.com/The-Verscienta/kiln_cms/issues/2292)'s change.
- **References** — [#2292](https://github.com/The-Verscienta/kiln_cms/issues/2292);
  builds on the `custom_filter` / `custom_sort` arguments and
  [#1746](https://github.com/The-Verscienta/kiln_cms/issues/1746) (keyset
  pagination breaks when a sort is added in a read hook).
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md);
  the vocabulary table is in [json-api.md](../json-api.md).

## The problem

Admin-defined custom fields live in one `custom_fields` JSONB map and were
queried through a side channel, `custom_filter[price]=10` and
`custom_sort=-price`. Clients expect them to behave like columns:
`filter[price]=10`, `sort=-price`.

`ash_json_api` parses `filter[...]` and `sort=` against the resource's public
attributes, calculations, aggregates and relationships *before* the read action
runs, and answers 400 for any other name. The engine behind `custom_filter`
therefore never sees such a name, and a site's custom field can be named like a
column (`title`, `tags`), since `FieldDefinition.name` is only a regex.

So a name can mean two things, and the API has to say which wins, without
breaking any request that succeeds today.

## Decision

**A built-in name always wins and keeps its meaning. Any other name in
`filter[...]` / `sort=` is a custom field. `custom_filter` / `custom_sort`
always mean a custom field and are the stable form.**

The rewrite is a purely lexical step in the router's `before_dispatch`
(`KilnCMSWeb.CustomFieldAliases`). It moves a non-built-in head from `filter`
to `custom_filter` and a non-built-in sort token to `custom_sort`. It reads no
registry, checks no tier and parses no Entry scope: whether a field exists, and
whether the caller may see it, stays the existing preparation's decision alone,
so a private field and an unknown one answer identically.

## The options

**(1) Built-in wins, `custom_*` is the escape hatch** (chosen). Additive: no
request that succeeds today changes meaning. A custom field named `title` stays
reachable as `custom_filter[title]`.

**(2) Custom field wins on a clash** (rejected). It silently changes what an
existing `filter[title]=…` returns the day an admin defines a field called
`title`, on a site that did nothing.

**(3) A registry-aware rewrite** (rejected). It keeps ash_json_api's native "no
such field" error for typos, at the price of a second copy of what
`CustomFieldQuery` already decides (existence, visibility tier, Entry scope,
tenant) and an extra read on anonymous requests. The cost of the lexical
version is one changed error body for an already-failing request.

**(4) Redesign the GraphQL filter and sort inputs** (rejected). They are static
per-resource types and cannot gain per-site fields; `customFilter` /
`customSort` already carry the full vocabulary.

## Consequences

- **The alias is not stable against future built-ins.** If a later 1.x release
  adds a public attribute or calculation named like a site's custom field,
  `filter[x]` changes from the custom field to the built-in. Additive-only
  policy allows adding the built-in. Programmatic consumers should use
  `custom_filter` / `custom_sort`, and the official clients keep emitting them
  for custom fields. `filter[x]` is the convenience form.
- **A typo's error body changed.** `filter[ttile]=x` used to get ash_json_api's
  "No such field" and now gets `400 invalid_argument`, `unknown custom field
  "ttile"`. Still a 400; no successful request changes.
- **The rewrite never answers a request.** `before_dispatch`'s result goes
  straight to the controller with no `halted` check, so wherever a rewrite
  would be refused the parameter is left as written and ash_json_api rejects it
  natively. *Amended (#2356):* a custom sort token before a built-in one
  (`sort=price,title`) used to get the native `invalid_sort`, because custom
  sorts apply after built-in ones. It is now one combined order: the leading
  built-ins stay in `sort`, the rest move to `custom_sort` with later built-ins
  spelled `_native:<name>`. Group conditions (`filter[or]` over a custom field,
  #2355) move to `custom_filter[_or]` the same way.
- **Custom sorts are always nulls-last;** a native `-x` is plain descending.
- **Reference and media fields stay unsortable.** A stored snapshot title goes
  stale on target rename and would leak the relative order of masked targets.
  A readability-aware sort key is a separate piece of work.
- **`custom_sort` on search** is declared only on the public keyword and
  semantic search actions, not the shared facet arguments, so the internal
  title/alias legs that decide which rows count as "named" are unaffected.
  Precedence is explicit `sort`, then `custom_sort`, then relevance or
  distance. On semantic search a leading custom sort replaces distance ordering
  (the vector index cannot serve it) and demotes the named-first rule, as an
  explicit `sort` already does.
- **OpenAPI's `sort` format lists built-ins only,** so a strictly validating
  client rejects `sort=price`; such clients use `custom_sort`.
- **Anonymous typos cost a registry read.** The field-definition read is not
  cached; `custom_filter[zzz]` already had this cost and the alias makes it
  reachable by the most common typo.
