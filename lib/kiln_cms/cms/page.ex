defmodule KilnCMS.CMS.Page do
  @moduledoc """
  A Page — strongly-modeled content with an embedded block tree (D3), full
  version history, a publishing workflow, and the standard content
  relationships. All of that behaviour comes from `KilnCMS.CMS.Content`; a Page
  adds nothing beyond it.
  """
  # Pages fire their :json_ld main node as a WebPage (not an Article) — the
  # accurate schema.org type for standalone site pages (#357, GEO).
  use KilnCMS.CMS.Content, type: :page, schema_org_type: "WebPage"
end
