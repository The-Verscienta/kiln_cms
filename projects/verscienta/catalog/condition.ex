defmodule Verscienta.Catalog.Condition do
  @moduledoc """
  A Condition — a Verscienta content type (migrated from Directus). All behaviour
  comes from `KilnCMS.CMS.Content`; it is registered on the `Verscienta.Catalog`
  domain so the reusable KilnCMS core stays project-agnostic.
  """
  use KilnCMS.CMS.Content,
    type: :condition,
    domain: Verscienta.Catalog,
    excerpt?: true,
    published?: true
end
