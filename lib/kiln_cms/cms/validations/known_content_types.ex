defmodule KilnCMS.CMS.Validations.KnownContentTypes do
  @moduledoc """
  Validates that every entry in a `:content_types` LIST names a real, registered
  content type — compiled or one of the writer org's dynamic (D17) types.

  The list variant of `KilnCMS.CMS.Validations.KnownContentType`: `TagGroup`
  scopes to content types by public type-name string, and `content_types` is in
  `default_accept`, so AshAdmin, seeds and the `create_tag_group`/`update_tag_group`
  code interfaces all write it unchecked — the LiveView checkboxes are a UI-level
  guard on a data-level invariant (#526). An entry naming no type (a typo like
  `"posts"`, or a `TypeDefinition` renamed/archived out from under it) makes the
  group match nothing, forever, silently: its tags vanish from every picker.

  Resolution is org-aware — dynamic types are per-org — via
  `ContentTypes.get/2` under the group's own `org_id`.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.ContentTypes

  @impl true
  def validate(changeset, _opts, _context) do
    org_id =
      Ash.Changeset.get_attribute(changeset, :org_id) || KilnCMS.Accounts.default_org_id()

    case changeset |> Ash.Changeset.get_attribute(:content_types) |> unknown_types(org_id) do
      [] ->
        :ok

      unknown ->
        {:error,
         InvalidAttribute.exception(
           field: :content_types,
           message: "names unknown content type(s): %{unknown}",
           vars: [unknown: Enum.join(unknown, ", ")],
           value: unknown
         )}
    end
  end

  defp unknown_types(nil, _org_id), do: []
  defp unknown_types(types, org_id), do: Enum.reject(types, &ContentTypes.get(&1, org_id))
end
