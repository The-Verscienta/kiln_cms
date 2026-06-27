defmodule KilnCMS.CMS.Practitioner do
  @moduledoc """
  A Practitioner — a KilnCMS content type. All of its behaviour (block editor,
  publishing workflow, version history, search, SEO, and the standard
  relationships) comes from `KilnCMS.CMS.Content`; add only what is unique to
  a Practitioner below.
  """
  use KilnCMS.CMS.Content, type: :practitioner, excerpt?: true, published?: true
end
