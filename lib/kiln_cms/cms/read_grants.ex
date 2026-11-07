defmodule KilnCMS.CMS.ReadGrants do
  @moduledoc """
  The two consistency guards behind `field_read_grants` (#2281), which need the
  site's field definitions and so cannot live in the pure
  `KilnCMS.CMS.FieldAccess`:

    * `invalid_entries/2` — which entries of a role's or membership's read
      grant name a field that exists but is **not private**. A read
      restriction only means something for a private field (a non-private one
      is world-readable on published content), so it is refused when saved
      (`Accounts.Validations.ReadGrantsPrivate`). A name no field has is left
      alone: the pickers show it as "(not found)" and let the admin untick it.
    * `named?/3` — is a field named by any read grant of the site's roles and
      memberships? A field so named cannot stop being private
      (`Validations.ReadGrantedStaysPrivate`), or the restriction would
      silently stop hiding it.

  User-level grants are not checked by either: they have no site, and a
  restriction on a field that is not private hides nothing
  (`FieldAccess.hidden_names/3`), so the worst a stale one does is nothing.
  """

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.FieldAccess
  alias KilnCMS.CMS.Housekeeping

  @doc """
  The entries of `grants` (type name → entries, a read grant) that are not
  legal for the type's definitions on `org_id`, as `[{type, entry}]`. A type
  this site does not have is skipped.
  """
  @spec invalid_entries(map(), Ash.UUID.t() | nil) :: [{String.t(), String.t()}]
  def invalid_entries(grants, org_id) when is_map(grants) do
    for {type, entries} <- grants,
        is_binary(type) and is_list(entries),
        definitions = definitions(type, org_id),
        is_list(definitions),
        entry <- entries,
        is_binary(entry),
        not FieldAccess.valid_read_entry?(entry, definitions),
        do: {type, entry}
  end

  @doc """
  Is the top-level field `name` of the type `type` named by a read grant of a
  role or a membership of `org_id`?
  """
  @spec named?(Ash.UUID.t() | nil, String.t(), String.t()) :: boolean()
  def named?(nil, _type, _name), do: false

  def named?(org_id, type, name) do
    key = FieldAccess.key([name])

    # Read-only and bounded to one site's roles and memberships, which the
    # acting site admin may be unable to list (roles are platform-admin only);
    # only a yes/no leaves this module.
    # authorize?: false — bounded to one site, only a boolean leaves
    roles = Accounts.list_roles_for_org!(org_id, authorize?: false)
    # authorize?: false — bounded to one site, only a boolean leaves
    memberships = Accounts.list_memberships_for_org!(org_id, authorize?: false)

    Enum.any?(roles ++ memberships, fn holder ->
      case Map.get(holder.field_read_grants || %{}, type) do
        entries when is_list(entries) -> key in entries
        _none -> false
      end
    end)
  end

  @doc "The grant key of the type a `FieldDefinition` belongs to (`nil` when unknown)."
  @spec type_name(map(), Ash.UUID.t() | nil) :: String.t() | nil
  def type_name(%{type_definition_id: id}, org_id) when is_binary(id) do
    org_id
    |> ContentTypes.dynamic_all()
    |> Enum.find_value(fn
      %{definition: %{id: ^id}, type: type} -> to_string(type)
      _other -> nil
    end)
  end

  def type_name(%{content_type: type}, _org_id) when not is_nil(type), do: to_string(type)
  def type_name(_definition, _org_id), do: nil

  defp definitions(type, org_id) do
    opts = [actor: Housekeeping.system(:cms_registry), authorize_with: :error, tenant: org_id]

    case ContentTypes.get(type, org_id) do
      %{source: :dynamic, definition: %{id: id}} ->
        CMS.field_definitions_for_definition!(id, opts)

      %{type: atom} ->
        CMS.field_definitions_for!(atom, opts)

      _unknown ->
        nil
    end
  end
end
