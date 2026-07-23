defmodule KilnCMS.CMS.Condition do
  @moduledoc """
  A Condition — a KilnCMS content type. All of its behaviour (block editor,
  publishing workflow, version history, search, SEO, and the standard
  relationships) comes from `KilnCMS.CMS.Content`; add only what is unique to
  a Condition below.
  """
  use KilnCMS.CMS.Content, type: :condition, excerpt?: true, published?: true
end
