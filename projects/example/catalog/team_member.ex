defmodule Example.Catalog.TeamMember do
  @moduledoc """
  A TeamMember — one of the fictional "Acme" company's staff bios. All of its
  baseline behaviour (block editor, publishing workflow, version history,
  search, and the standard relationships) comes from `KilnCMS.CMS.Content`;
  it is registered on the `Example.Catalog` domain so the reusable KilnCMS
  core stays project-agnostic.

  `schema_org_type: "Person"` is the type-specific opt-in here — the fired
  JSON-LD node describes a person rather than the macro's `"Article"`
  default. Its `title`/`department`/`social_links` custom fields (see
  `example_field_definitions.exs`) show the admin-defined `FieldDefinition`
  registry — no resource code needed for per-type custom fields.
  """
  use KilnCMS.CMS.Content,
    type: :team_member,
    domain: Example.Catalog,
    excerpt?: true,
    schema_org_type: "Person"
end
