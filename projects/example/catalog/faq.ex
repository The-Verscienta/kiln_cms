defmodule Example.Catalog.Faq do
  @moduledoc """
  A Faq — one of "Acme"'s frequently-asked questions. All of its baseline
  behaviour (block editor, publishing workflow, version history, search, and
  the standard relationships) comes from `KilnCMS.CMS.Content`; it is
  registered on the `Example.Catalog` domain so the reusable KilnCMS core
  stays project-agnostic.

  `schema_org_type: "FAQPage"` opts into an FAQPage-shaped JSON-LD node
  instead of the macro's `"Article"` default. `example_import.exs` seeds one
  entry in two locales (`en`/`es`, same slug) — the worked example of
  multi-locale content, since a locale is just another attribute on the same
  `:create` action.
  """
  use KilnCMS.CMS.Content,
    type: :faq,
    domain: Example.Catalog,
    schema_org_type: "FAQPage"
end
