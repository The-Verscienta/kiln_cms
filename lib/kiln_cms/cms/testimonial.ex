defmodule KilnCMS.CMS.Testimonial do
  @moduledoc """
  A Testimonial — a KilnCMS content type. All of its behaviour (block editor,
  publishing workflow, version history, search, SEO, and the standard
  relationships) comes from `KilnCMS.CMS.Content`; add only what is unique to
  a Testimonial below.
  """
  use KilnCMS.CMS.Content, type: :testimonial, excerpt?: true, published?: true
end
