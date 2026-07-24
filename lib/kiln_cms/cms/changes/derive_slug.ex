defmodule KilnCMS.CMS.Changes.DeriveSlug do
  @moduledoc """
  Fills a blank/omitted `slug` from the type's slug pattern (#454) or the
  default chain (focus keyphrase → title, stop words stripped), deduped
  pathauto-style (`Slugs.ensure_unique/2`) — so authors and headless API
  clients only have to supply a title, and a second "Guide to the Kiln"
  becomes `guide-kiln-2` instead of failing the `unique_slug` identity.

  An explicit slug always wins (surfacing the normal identity error on a
  collision); on update this only fires when the slug is deliberately
  cleared, which regenerates it.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Slugs

  @impl true
  def change(changeset, _opts, _context) do
    with blank when blank in [nil, ""] <- Ash.Changeset.get_attribute(changeset, :slug),
         base when base != "" <- derived_base(changeset) do
      slug = Slugs.ensure_unique(base, scope(changeset))
      Ash.Changeset.force_change_attribute(changeset, :slug, slug)
    else
      # Slug present, no title yet, or an unsluggable title ("!!!") — leave the
      # changeset alone and let the usual required/format validations speak.
      _ -> changeset
    end
  end

  # The single derivation entry point shared with the editor (#454): the
  # type's slug pattern when one is set, else the default chain, with the
  # empty-expansion and no-usable-text guard rails in Slugs.derive_base/2.
  defp derived_base(changeset) do
    pattern = Slugs.pattern_for(changeset, :slug)
    Slugs.derive_base(pattern, Slugs.changeset_context(changeset, pattern))
  end

  # The `unique_slug` scope of the record being written, plus the root-segment
  # guard for types served at `/<slug>`.
  defp scope(changeset) do
    [
      resource: changeset.resource,
      root?: ContentTypes.root_served?(changeset.resource),
      locale: Ash.Changeset.get_attribute(changeset, :locale),
      org_id: Slugs.changeset_attribute(changeset, :org_id),
      type_definition_id: Slugs.changeset_attribute(changeset, :type_definition_id),
      tenant: changeset.tenant,
      exclude_id: Map.get(changeset.data, :id)
    ]
  end
end
