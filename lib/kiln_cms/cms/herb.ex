defmodule KilnCMS.CMS.Herb do
  @moduledoc """
  A Herb — a KilnCMS content type. All of its behaviour (block editor,
  publishing workflow, version history, search, SEO, and the standard
  relationships) comes from `KilnCMS.CMS.Content`; add only what is unique to
  a Herb below.
  """
  use KilnCMS.CMS.Content, type: :herb, excerpt?: true, published?: true
end
