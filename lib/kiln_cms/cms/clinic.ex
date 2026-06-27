defmodule KilnCMS.CMS.Clinic do
  @moduledoc """
  A Clinic — a KilnCMS content type. All of its behaviour (block editor,
  publishing workflow, version history, search, SEO, and the standard
  relationships) comes from `KilnCMS.CMS.Content`; add only what is unique to
  a Clinic below.
  """
  use KilnCMS.CMS.Content, type: :clinic, excerpt?: true, published?: true
end
