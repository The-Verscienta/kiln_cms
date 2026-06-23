defmodule KilnCMS.CMS.Page do
  @moduledoc """
  A Page — strongly-modeled content with an embedded block tree (D3), full
  version history, a publishing workflow, and the standard content
  relationships. All of that behaviour comes from `KilnCMS.CMS.Content`; a Page
  adds nothing beyond it.
  """
  use KilnCMS.CMS.Content, type: :page
end
