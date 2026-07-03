defmodule KilnCMS.CMS.Entry do
  @moduledoc """
  The **generic entry** — one shared resource (and table) holding the records
  of every admin-defined dynamic content type (decision D17,
  `docs/dynamic-content-types-plan.md`).

  A compiled content type gets its own module and table; a dynamic type is a
  `TypeDefinition` row, and its records are entries scoped by
  `type_definition_id` — with the identical content behaviour (block tree,
  paper-trail history, publishing workflow, optimistic locking, scheduled
  publishing, soft-delete, custom fields, search columns) via
  `KilnCMS.CMS.Content`. The `dynamic?: true` option scopes slugs and the
  public reads by type and omits the per-type JSON:API/GraphQL surface —
  dynamic types are delivered through the fired-artifact API and, later, one
  generic `entries` surface.

  `excerpt?: true` puts the column on every entry; whether a given dynamic
  type *uses* it is `TypeDefinition.has_excerpt`, enforced in the editor UI.
  """
  use KilnCMS.CMS.Content,
    type: :entry,
    plural: "entries",
    table: "entries",
    excerpt?: true,
    dynamic?: true
end
