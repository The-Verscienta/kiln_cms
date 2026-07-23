defmodule KilnCMS.CMS.Faq do
  @moduledoc """
  A Faq — a KilnCMS content type. All of its behaviour (block editor,
  publishing workflow, version history, search, SEO, and the standard
  relationships) comes from `KilnCMS.CMS.Content`; add only what is unique to
  a Faq below.
  """
  use KilnCMS.CMS.Content, type: :faq, published?: true
end
