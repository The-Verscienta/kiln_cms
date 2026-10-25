defmodule KilnCMS.CMS.Changes.PrivateUserField do
  @moduledoc """
  Makes every `:user` `FieldDefinition` private (#2044).

  A `:user` field names a console `KilnCMS.Accounts.User`, and Kiln never
  delivers a console account: `User` is not on JSON:API, and a content item's
  own `author` is never in an artifact. A field pointing at one keeps the
  same rule, so it is private whatever was submitted
  (`KilnCMS.CMS.PrivateFields`).
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :field_type) == :user,
      do: Ash.Changeset.force_change_attribute(changeset, :private, true),
      else: changeset
  end
end
