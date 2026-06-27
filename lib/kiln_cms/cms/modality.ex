defmodule KilnCMS.CMS.Modality do
  @moduledoc """
  A Modality — a KilnCMS content type. All of its behaviour (block editor,
  publishing workflow, version history, search, SEO, and the standard
  relationships) comes from `KilnCMS.CMS.Content`; add only what is unique to
  a Modality below.
  """
  use KilnCMS.CMS.Content, type: :modality, table: "modalities", excerpt?: true, published?: true
end
