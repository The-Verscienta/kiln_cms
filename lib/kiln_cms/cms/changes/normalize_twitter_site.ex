defmodule KilnCMS.CMS.Changes.NormalizeTwitterSite do
  @moduledoc """
  Canonicalizes `twitter_site` to `@handle` before it is stored (#2258), so
  `kilncms`, `@kilncms` and `https://x.com/kilncms` are the same row value.

  Runs as a change (not in the LiveView) so the invariant holds for every
  caller, like `KilnCMS.CMS.Changes.NormalizeBrandColor`. Invalid values are
  left untouched for `KilnCMS.CMS.Validations.BrandTokens` to reject with a
  proper field error; silently nulling them here would swallow the mistake.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.Validations.BrandTokens

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :twitter_site) do
      value when is_binary(value) and value != "" ->
        case BrandTokens.normalize_twitter_site(value) do
          nil -> changeset
          normalized -> Ash.Changeset.force_change_attribute(changeset, :twitter_site, normalized)
        end

      _ ->
        changeset
    end
  end
end
