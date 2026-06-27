defmodule Verscienta.Catalog.Herb do
  @moduledoc """
  A Herb — a Verscienta content type (migrated from Directus). All behaviour
  comes from `KilnCMS.CMS.Content`; it is registered on the `Verscienta.Catalog`
  domain so the reusable KilnCMS core stays project-agnostic.
  """
  use KilnCMS.CMS.Content,
    type: :herb,
    domain: Verscienta.Catalog,
    excerpt?: true,
    published?: true
end
