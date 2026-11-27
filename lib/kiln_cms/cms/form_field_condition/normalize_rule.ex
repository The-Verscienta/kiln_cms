defmodule KilnCMS.CMS.FormFieldCondition.NormalizeRule do
  @moduledoc false
  # String keys and operators throughout, so the stored rule reads back as it
  # was written (jsonb has no atoms) and the shape check sees what is stored.
  # A rule that normalizes to nothing is left to `allow_nil?`.
  use Ash.Resource.Change

  alias KilnCMS.CMS.Conditions

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :rule) do
      rule when is_map(rule) ->
        Ash.Changeset.force_change_attribute(changeset, :rule, Conditions.normalize(rule))

      _other ->
        changeset
    end
  end
end
