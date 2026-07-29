defmodule KilnCMS.CMS.Changes.NormalizeBrandColor do
  @moduledoc """
  Canonicalizes `brand_color` to lowercase `#rrggbb` before it is stored, so
  `#F00` and `#ff0000` are the same row value.

  Runs as a change (not in the LiveView) so the invariant holds for every
  caller — seeds, the API, and tests included. Invalid values are left
  untouched for `KilnCMS.CMS.Validations.BrandTokens` to reject with a proper
  field error; silently nulling them here would swallow the user's mistake.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.Validations.BrandTokens

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :brand_color) do
      value when is_binary(value) and value != "" ->
        case BrandTokens.normalize_color(value) do
          nil -> changeset
          normalized -> Ash.Changeset.force_change_attribute(changeset, :brand_color, normalized)
        end

      _ ->
        changeset
    end
  end
end
