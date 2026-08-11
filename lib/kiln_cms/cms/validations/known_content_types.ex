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

  ## Only what the write supplies

  `Ash.Changeset.get_attribute/2` falls back to `get_data/2`, so validating
  unconditionally re-judged the row's **stored** list on every update — and an
  entry can go stale without anyone touching the group (archiving a dynamic type
  drops it from `ContentTypes.dynamic_all/1`). That froze the record: renaming or
  repositioning it was rejected on a field the write never mentioned, from
  AshAdmin, seeds and the code interfaces alike, with no way back except editing
  the column by hand.

  It also contradicted the feature's own UI, which deliberately renders a stale
  entry as `"<name> (unknown)"` — i.e. the row is expected to persist and stay
  editable so an admin can fix it.

  So this validates only when the write is actually changing `content_types`.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.ContentTypes

  @impl true
  def validate(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :content_types) do
      validate_supplied(changeset)
    else
      :ok
    end
  end

  defp validate_supplied(changeset) do
    case changeset
         |> Ash.Changeset.get_attribute(:content_types)
         |> unknown_types(org_id(changeset)) do
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

  # The writer's org. `to_tenant` (an id via `Ash.ToTenant`, matched as a struct
  # too) is populated at changeset-build time, so it is the value validations can
  # trust — the `org_id` ATTRIBUTE is not stamped from the tenant until the action
  # runs, and its function default is lazy, so on `:create` it is still nil here.
  # Reading it instead resolved every scoped create under the DEFAULT org, which
  # rejected a non-default org's own dynamic types. Falls back like `Scoping`.
  defp org_id(%{to_tenant: org_id}) when is_binary(org_id), do: org_id
  defp org_id(%{to_tenant: %{id: org_id}}) when is_binary(org_id), do: org_id

  defp org_id(changeset),
    do: Ash.Changeset.get_attribute(changeset, :org_id) || KilnCMS.Accounts.default_org_id()
end
