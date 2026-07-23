defmodule KilnCMS.CMS.Changes.DeriveSlug do
  @moduledoc """
  Fills a blank/omitted `slug` from the `title` (stop words stripped — see
  `KilnCMS.Slug.derive/1`), so authors and headless API clients only have to
  supply a title. An explicit slug always wins; on update it only fires when
  the slug is deliberately cleared, which regenerates it from the title.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    with blank when blank in [nil, ""] <- Ash.Changeset.get_attribute(changeset, :slug),
         title when is_binary(title) <- Ash.Changeset.get_attribute(changeset, :title),
         slug when slug != "" <- KilnCMS.Slug.derive(title) do
      Ash.Changeset.force_change_attribute(changeset, :slug, slug)
    else
      # Slug present, no title yet, or an unsluggable title ("!!!") — leave the
      # changeset alone and let the usual required/format validations speak.
      _ -> changeset
    end
  end
end
