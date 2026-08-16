defmodule Example.Catalog.Product do
  @moduledoc """
  A Product — one of the fictional "Acme" company's catalog items. All of its
  baseline behaviour (block editor, publishing workflow, version history,
  search, and the standard relationships) comes from `KilnCMS.CMS.Content`;
  it is registered on the `Example.Catalog` domain so the reusable KilnCMS
  core stays project-agnostic.

  The type-specific opt-ins here are the ones the macro leaves off by
  default:

    * `schema_org_type: "Product"` — the fired JSON-LD node describes a
      product instead of the macro's `"Article"` default.
    * `alias_pattern` — a multi-segment `path_alias` driven by the `category`
      custom field (`example_field_definitions.exs`), e.g.
      `/products/hardware/widget-pro`. `[field:category]` resolves through
      the same custom-field registry every other pattern token does.
    * `seo_title_pattern` — every product's delivered `<title>` carries the
      brand suffix without repeating it in each record.

  `example_import.exs` seeds one product gated by `audience: :member` and
  one gated by `access_password_hash` — both are plain attributes on
  `KilnCMS.CMS.Content`, not resource-code opt-ins, so they're demonstrated
  in the seed data rather than here.
  """
  use KilnCMS.CMS.Content,
    type: :product,
    domain: Example.Catalog,
    excerpt?: true,
    schema_org_type: "Product",
    alias_pattern: "/products/[field:category]/[slug]",
    seo_title_pattern: "[title] · Acme"
end
