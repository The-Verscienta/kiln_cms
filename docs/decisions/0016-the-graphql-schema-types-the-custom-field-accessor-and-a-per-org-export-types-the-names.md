# 0016. The GraphQL schema types the custom-field accessor; a per-org export types the names

- **Status** — accepted; unreleased.
- **References** — [#2290](https://github.com/The-Verscienta/kiln_cms/issues/2290),
  shipped in [#2317](https://github.com/The-Verscienta/kiln_cms/pull/2317); guide:
  [docs/headless-graphql-api.md](../headless-graphql-api.md#read-custom-fields-typed-by-kind).
- **Changelog** — the Unreleased Added section of [CHANGELOG.md](../../CHANGELOG.md).

## The problem

An admin defines custom fields at runtime, per organization: `price` on `post`
for one site, `servings` on a dynamic `recipe` type for another. Over GraphQL
they were one `customFields: JsonString`, so every client parsed JSON and
guessed each value's type. A GraphQL consumer expects `price: Float`, with
codegen that knows it.

The obstacle is that a GraphQL schema is one compiled artifact. Absinthe
builds it at compile time from the Ash resources, and the result is shared by
every organization on the node. A field an admin adds on Tuesday cannot become
a field on `Post` without that artifact changing, and the artifact is not
per-site.

## Decision

**The schema stays static and org-independent. It types the accessor. A
per-org exported contract types the names.**

- Every content type (`Page`, `Post`, each project type, `Entry`) and the
  `ContentRecord` interface get `customString`, `customInt`, `customFloat`,
  `customBoolean`, `customDate` and `customDateTime`, each taking `name:`, and
  `fields(names:)` returning the `CustomFieldValue` interface. The *return type*
  is typed (`customFloat(name: "price")` is `Float`); the *name* is a string
  the schema cannot check. `CustomFieldValue` has one member per kind
  (`FloatValue`, `MediaValue`, `GroupValue`, `GeolocationValue`, …), so a field
  with no scalar accessor is read through `fields`.
- `GET /api/schema?format=typescript-graphql` is the contract that types the
  names. For one organization's definitions, as of now, it emits per content
  type a `<Type>CustomFields` interface and a `<Type>CustomFieldsFragment` that
  spells out the right accessor and alias for each field. A client commits the
  file, spreads the fragment, and gets `price: number | null` from the
  compiler. It sits beside the existing `json` and `typescript` formats (a
  closed set; anything else is `400`), and the default stays JSON.
- A kind registry, `KilnCMS.CMS.FieldKind`, maps a field definition to the
  GraphQL kind that serves it. It is the single source for the accessor, the
  union member and the export, so the three cannot disagree. A plugin field
  type may name its kind through the optional `graphql_kind/1` on
  `Kiln.FieldType`; one that does not is served as `JsonValue`.
- Private fields are enforced by reading the parent record again as the
  request's actor, so the existing private-field masking applies unchanged. A
  test fails if that read ever becomes `authorize?: false`.

## Options rejected

**Runtime, per-org schema (recompile Absinthe when definitions change).**
This gives the ideal `price: Float` on `Post`, and it was rejected on cost and
on mechanism:

- Compiling a schema takes seconds and holds the result in memory. Doing that
  for every organization multiplies both by the tenant count, and an admin
  editing a field would trigger it on a request path.
- Absinthe schemas name types and fields with atoms; admin-chosen names would
  mint atoms at runtime, which the VM never reclaims. An admin who can create
  field names would be able to exhaust the atom table.
- There is no cluster-wide recompile signal. Definitions change on one node
  and the others keep serving the old schema until something tells them. The
  platform's real-time model is `Phoenix.PubSub` for notifications, not a
  coordinated hot-code swap, and building one for this is a larger system than
  the feature.

**Promotion-time codegen (`mix kiln.gen.content`).** Generating a real
resource per field, as the existing promote-a-dynamic-type path does for a
type, makes the field a first-class GraphQL field. It requires a code change
and a deploy for each field an admin adds, which defeats the reason the fields
are admin-defined. It remains the right tool for a type that has outgrown
being dynamic. It is not the tool for adding `servings`.

## Consequences

- **A wrong name returns `null`, not an error.** A typo, a renamed or deleted
  field, a field of another kind, a stored value that no longer fits its
  definition, and a private field read below editor are all `null` (and absent
  from `fields`). This is deliberate for the last case, so a client cannot
  learn which private fields exist, and the same shape is the price of the
  others. The compile-time check is the generated file.
- **Regenerate after an admin edits definitions.** The export reflects the
  definitions *now*. A client that commits the file should regenerate in CI and
  fail on a diff. The response is cached for five minutes and refreshed when a
  content type or field definition is written.
- **Filters stay untyped.** `customFilter` (JSON) and `customSort` (String)
  are unchanged and still take field names as strings. Only reads are typed.
- **Plugin kinds are scalar or JSON only.** `graphql_kind/1` can name a
  scalar kind or `:json`; it cannot describe an object shape. A plugin
  field type that needs a structure is `JsonValue` until it is promoted into
  core.
- **Geolocation is typed in core** (`GeolocationValue { lat lng label zoom }`)
  because it is a core field type that needs more than a scalar, which is the
  one case where core has a member the plugin contract cannot express.
- **Locale fallback is not followed.** The typed layer serves the record's own
  value; a `localization: :fallback` field does not inherit along the locale
  chain, unlike a read that resolves it. Read the record in the locale you want.
- **The plugin SDK changes additively.** `graphql_kind/1` is an optional
  callback in `kiln_plugin` 1.4.0 (not yet released); older plugins serve as
  `:json`.
- **Cost is bounded.** `names` is required and at most 50; a page of records
  reads the definitions once per scope, not per record.

## Follow-ups

- Swift and Kotlin emitters for the GraphQL section of the export (the
  TypeScript one ships first).
- Typed filter and sort operators.
- Typed writes (`updatePost(input: { customFields: … })` stays a JSON map).
- Release `kiln_plugin` 1.4.0 before this reaches a release.
- If an organization needs the field on the schema itself, promotion
  (`mix kiln.gen.content`) is the path; this record does not change it.
