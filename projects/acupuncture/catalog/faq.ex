defmodule Acupuncture.Catalog.Faq do
  @moduledoc """
  A Faq — an acupuncture-site content type (migrated from Sanity). All of its
  behaviour (block editor, publishing workflow, version history, search, SEO,
  and the standard relationships) comes from `KilnCMS.CMS.Content`; it is
  registered on the `Acupuncture.Catalog` domain so the reusable KilnCMS core
  stays project-agnostic.
  """
  use KilnCMS.CMS.Content,
    type: :faq,
    domain: Acupuncture.Catalog,
    published?: true
end
