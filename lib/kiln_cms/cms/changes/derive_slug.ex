defmodule KilnCMS.CMS.Changes.DeriveSlug do
  @moduledoc """
  Fills a blank/omitted `slug` from the `title` (stop words stripped — see
  `KilnCMS.Slug.derive/1`), so authors and headless API clients only have to
  supply a title. The derived slug is deduped pathauto-style
  (`Slugs.ensure_unique/2`): a second "Guide to the Kiln" becomes
  `guide-kiln-2` instead of failing the `unique_slug` identity, and a
  root-served page can't derive a slug that a section route would shadow.

  An explicit slug always wins (surfacing the normal identity error on a
  collision); on update this only fires when the slug is deliberately
  cleared, which regenerates it from the title.
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
    pattern = pattern_for(changeset)
    Slugs.derive_base(pattern, pattern_context(changeset, pattern))
  end

  # Compiled types carry their pattern as a compile-time marker; dynamic
  # entries resolve theirs with one keyed read of their TypeDefinition row.
  # The row id is globally unique, so this is tenant-correct even though the
  # org_id attribute isn't materialized until after action changes run.
  defp pattern_for(changeset) do
    resource = changeset.resource

    if Code.ensure_loaded?(resource) and
         function_exported?(resource, :__kiln_content_slug_pattern__, 0) do
      resource.__kiln_content_slug_pattern__()
    else
      dynamic_pattern(changeset)
    end
  end

  defp dynamic_pattern(changeset) do
    with definition_id when not is_nil(definition_id) <-
           attribute_if_present(changeset, :type_definition_id),
         {:ok, definition} <-
           KilnCMS.CMS.get_type_definition(definition_id,
             authorize?: false,
             tenant: changeset.tenant
           ) do
      definition.slug_pattern
    else
      _ -> nil
    end
  end

  defp pattern_context(changeset, pattern) do
    %{
      title: Ash.Changeset.get_attribute(changeset, :title),
      seo_keywords: attribute_if_present(changeset, :seo_keywords),
      category_slug: pattern_category_slug(changeset, pattern),
      # Stable date anchor: publish date when set, else the scheduled date,
      # else the record's creation date (nil on create → today, which then IS
      # the creation date). Never re-read from the wall clock afterwards.
      date:
        Ash.Changeset.get_attribute(changeset, :published_at) ||
          Ash.Changeset.get_attribute(changeset, :scheduled_at) ||
          Map.get(changeset.data, :inserted_at)
    }
  end

  # One small read, and only when the pattern actually mentions [category].
  defp pattern_category_slug(changeset, pattern) do
    with true <- KilnCMS.Slug.Pattern.uses?(pattern, "category"),
         category_id when not is_nil(category_id) <-
           attribute_if_present(changeset, :category_id),
         {:ok, category} <-
           KilnCMS.CMS.get_category(category_id, authorize?: false, tenant: changeset.tenant) do
      category.slug
    else
      _ -> nil
    end
  end

  # The `unique_slug` scope of the record being written, plus the root-segment
  # guard for types served at `/<slug>`.
  defp scope(changeset) do
    [
      resource: changeset.resource,
      root?: ContentTypes.root_served?(changeset.resource),
      locale: Ash.Changeset.get_attribute(changeset, :locale),
      org_id: attribute_if_present(changeset, :org_id),
      type_definition_id: attribute_if_present(changeset, :type_definition_id),
      tenant: changeset.tenant,
      exclude_id: Map.get(changeset.data, :id)
    ]
  end

  defp attribute_if_present(changeset, name) do
    if Ash.Resource.Info.attribute(changeset.resource, name),
      do: Ash.Changeset.get_attribute(changeset, name)
  end
end
