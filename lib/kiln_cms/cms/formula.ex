defmodule KilnCMS.CMS.Formula do
  @moduledoc """
  A Formula — a KilnCMS content type. All of its behaviour (block editor,
  publishing workflow, version history, search, SEO, and the standard
  relationships) comes from `KilnCMS.CMS.Content`; add only what is unique to
  a Formula below.
  """
  use KilnCMS.CMS.Content, type: :formula, excerpt?: true, published?: true
end
