# Extending the content model

KilnCMS is built around editorial content (title/slug/SEO + a rich block tree),
but real projects also carry **structured reference data**, **relations that
carry data**, and **consumer-facing access tiers**. This guide covers the three
mechanisms that close that gap without forking the core model.

These exist because of decision **D4** (content *types* are compile-time Ash
resources, not a runtime meta-model). They make *fields*, *links*, and *access*
data-driven while keeping types — and their strong guarantees — in code.

## 1. Custom fields (admin-UI-defined schema)

Add typed fields to a content type from the admin UI (`/editor/fields`, admin
only) — no migration, no code change. This is the Directus "add a field in the
UI" workflow, scoped to fields.

- **Define**: `KilnCMS.CMS.FieldDefinition` rows describe each field
  (`content_type`, `name`, `label`, `field_type`, `required`, `options`,
  `help_text`, `position`, `default`). Field types: `:string`, `:text`,
  `:integer`, `:float`, `:boolean`, `:date`, `:datetime`, `:url`, `:select`.
- **Store**: values live in the `custom_fields` map on each content record.
- **Validate**: `KilnCMS.CMS.Changes.ApplyCustomFields` runs on every write — it
  coerces values to the declared type, enforces `required`, checks `:select`
  membership, applies defaults, and drops keys with no definition. Values are
  stored JSON-native (dates as ISO-8601 strings) so the jsonb column round-trips.
- **Edit**: the content editor renders one input per definition automatically.
- **Deliver**: `custom_fields` is public, so headless clients get the values.

```elixir
# Defined once in the UI (or in code/seeds):
CMS.create_field_definition!(%{
  content_type: :page, name: "toxicity_level", label: "Toxicity level",
  field_type: :select, options: ~w(none low moderate high), required: true
}, actor: admin)

# Then editors just fill it; the value is validated on save:
CMS.create_page!(%{title: "Aconite", slug: "aconite",
  custom_fields: %{"toxicity_level" => "high"}}, actor: editor)
```

**When to use a real attribute instead.** Custom fields cover the long tail of
editor-owned fields. A field that is core, frequently queried/sorted, or needs a
DB constraint/index still belongs as a hand-declared Ash attribute on the
resource (with a `mix ash.codegen` migration). Custom fields are jsonb — they are
not indexed columns.

## 2. Relations that carry data

`KilnCMS.CMS.ContentLink` links any two content records by id with a named
`kind`. Each link can also carry a payload — `metadata` (a free map) and an
optional `label` — so a relation can describe *itself* (a dosage and role on a
formula→ingredient link, jia-jian notes, an ordered "step N").

```elixir
CMS.create_content_link!(%{
  source_id: formula.id, target_id: ingredient.id,
  kind: :ingredient, label: "Chief herb",
  metadata: %{"dosage_g" => 9, "role" => "jun"}
}, actor: editor)
```

Read the payload from either end via the `content_links` (outgoing) and
`incoming_links` (reverse) relationships on any content record:

```elixir
formula = CMS.get_page!(id, load: [:content_links], actor: actor)
Enum.map(formula.content_links, & &1.metadata)
```

**When to use a dedicated join resource instead.** ContentLink covers the common
case with one table. If the link attributes are numerous, strongly typed, or
queried independently, write a typed Ash join resource (a normal resource with
two `belongs_to`s plus its own attributes) — the same way the codebase models any
first-class entity.

## 3. Consumer-facing access tiers (audiences)

Editorial `role` (`:admin`/`:editor`/`:viewer`) gates **authoring**. A separate
**audience** axis gates which signed-in end-users may **read** a published
record — independent of role. See `KilnCMS.CMS.Audiences` and
[policy-matrix.md](policy-matrix.md).

- Configure the tiers: `config :kiln_cms, :audiences, [:public, :professional, :patient]`
  (`:public` is always implied and must stay first). Compile-time, so the Ash
  `one_of` constraints validate statically.
- Tag content with one `audience` (default `:public`).
- Grant users audiences with the admin-only `:manage_access` action
  (`Accounts.manage_user_access/3`) — never self-service.
- The content read policy: editors/admins see everything; `:public` published
  content stays world-readable; audience-restricted published content is visible
  only to readers who belong to that audience.

To serve gated content on the public site, pass the signed-in user as the actor
on the delivery read — anonymous callers only ever see `:public` content.
