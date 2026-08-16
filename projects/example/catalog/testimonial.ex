defmodule Example.Catalog.Testimonial do
  @moduledoc """
  A Testimonial — a customer quote about one of "Acme"'s products. All of its
  baseline behaviour (block editor, publishing workflow, version history,
  search, and the standard relationships) comes from `KilnCMS.CMS.Content`;
  it is registered on the `Example.Catalog` domain so the reusable KilnCMS
  core stays project-agnostic.

  `schema_org_type: "Review"` opts into a review-shaped JSON-LD node instead
  of the macro's `"Article"` default. `example_import.exs` links each seeded
  testimonial to a `Product` via the standard related-content relationship,
  so this is also the worked example of cross-type linking.
  """
  use KilnCMS.CMS.Content,
    type: :testimonial,
    domain: Example.Catalog,
    excerpt?: true,
    schema_org_type: "Review"
end
