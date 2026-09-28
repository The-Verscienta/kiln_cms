defmodule KilnCMS.Accounts.Changes.NormalizeOrgSlug do
  @moduledoc """
  Trim and downcase an organization's slug when it is being set (#1710), so
  `Acme` is stored as the `acme` a browser's host resolves to. Runs before
  `KilnCMS.Accounts.Validations.OrgSlugIsHostLabel`, which then checks what
  will actually be stored. See `KilnCMS.Accounts.OrgSlug`.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.OrgSlug

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :slug) do
      case Ash.Changeset.get_attribute(changeset, :slug) do
        slug when is_binary(slug) ->
          Ash.Changeset.force_change_attribute(changeset, :slug, OrgSlug.normalize(slug))

        _other ->
          changeset
      end
    else
      changeset
    end
  end
end
