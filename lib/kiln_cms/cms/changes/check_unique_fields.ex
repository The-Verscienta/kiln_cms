defmodule KilnCMS.CMS.Changes.CheckUniqueFields do
  @moduledoc """
  Re-checks a record's `unique` custom fields (#2276) when it comes back from
  the trash.

  A trashed record is invisible to the uniqueness lookup, so while it sat in
  the trash another record may have taken its value. `:restore` skips
  `Changes.ApplyCustomFields` (the stored map is not re-coerced), so this adds
  the same lock and check on its own, for every unique field the record holds
  a value for. `:unarchive` needs none: a workflow-archived record still
  counts. See `KilnCMS.CMS.UniqueValues`.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.Changes.ApplyCustomFields
  alias KilnCMS.CMS.UniqueValues

  @impl true
  def change(changeset, _opts, _context) do
    defs =
      ApplyCustomFields.definitions(
        changeset.resource,
        Ash.Changeset.get_attribute(changeset, :type_definition_id),
        changeset.to_tenant
      )

    UniqueValues.register(changeset, defs, all?: true, kind: :restored)
  end
end
