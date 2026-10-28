defmodule KilnCMS.CMS.Changes.DeriveAlias do
  @moduledoc """
  Fills a blank/omitted `path_alias` from the type's **alias pattern** (#485
  follow-up), e.g. `"/products/shoes/size/[field:size]"` →
  `/products/shoes/size/42`. Runs after `DeriveSlug`, so the `[slug]`
  token sees the final (deduped) slug.

  An explicit alias always wins; clearing it on update regenerates —
  pathauto semantics, mirroring `DeriveSlug`. A colliding expansion is
  suffixed (`…-2`) rather than failing the write. Types without an alias
  pattern are untouched (flat URLs, alias stays manual).
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.Slugs
  alias KilnCMS.Slug.Pattern

  @impl true
  def change(changeset, _opts, _context) do
    # As in `DeriveSlug`: one pinned date for every formula the write evaluates.
    changeset = KilnCMS.CMS.Computed.Context.pin_today(changeset)

    with blank when blank in [nil, ""] <- Ash.Changeset.get_attribute(changeset, :path_alias),
         pattern when is_binary(pattern) <- Slugs.pattern_for(changeset, :alias),
         alias_path when is_binary(alias_path) <-
           Pattern.expand_path(
             pattern,
             Slugs.changeset_context(changeset, pattern),
             Slugs.changeset_token_definitions(changeset, pattern, :alias)
           ) do
      changeset
      |> Ash.Changeset.force_change_attribute(:path_alias, unique_alias(alias_path, changeset))
      # Recorded, not inferred later (#1890): see `Changes.TrackAliasDerivation`.
      |> Ash.Changeset.force_change_attribute(:path_alias_derived, true)
    else
      # Alias present, no alias pattern, or an all-empty expansion — leave the
      # record at its flat URL.
      _ -> changeset
    end
  end

  # Alias collisions can't be a DB constraint (aliases span every content
  # table), so dedupe like slugs: `…-2`, `…-3`, … on the last segment.
  defp unique_alias(alias_path, changeset) do
    locale = Ash.Changeset.get_attribute(changeset, :locale)
    tenant = changeset.tenant
    exclude_id = Map.get(changeset.data, :id)

    if Slugs.alias_taken?(alias_path, locale, tenant, exclude_id) do
      Enum.find_value(2..50, alias_path, fn n ->
        candidate = "#{alias_path}-#{n}"
        not Slugs.alias_taken?(candidate, locale, tenant, exclude_id) && candidate
      end)
    else
      alias_path
    end
  end
end
