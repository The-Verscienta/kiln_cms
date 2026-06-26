defmodule Kiln.Block.Policy do
  @moduledoc """
  Field-/block-level authorization for typed blocks (Kiln v2 — decision matrix in
  `docs/policy-matrix.md`, plan D-J).

  A field may declare `editable_by: [roles]`; absent that, any editor may edit it.
  Admins may edit everything. This is the access control that lives *next to the
  schema* — e.g. an editor can edit a `Quote`'s text but not its `featured` flag.
  The editor calls `authorize_changes/3` before persisting block edits.
  """

  @doc "Field names a role may edit on a block module."
  @spec editable_fields(module(), atom()) :: [atom()]
  def editable_fields(module, role) do
    module
    |> Kiln.Block.Info.fields()
    |> Enum.filter(&role_can?(&1, role))
    |> Enum.map(& &1.name)
  end

  @doc "Whether `role` may edit `field_name` on `module`."
  @spec can_edit_field?(module(), atom(), atom()) :: boolean()
  def can_edit_field?(module, field_name, role) do
    case Enum.find(Kiln.Block.Info.fields(module), &(&1.name == field_name)) do
      nil -> false
      field -> role_can?(field, role)
    end
  end

  @doc """
  Authorize a set of changed field names for `role`.
  `:ok` if all allowed, else `{:error, forbidden_field_names}`.
  """
  @spec authorize_changes(module(), atom(), [atom()]) :: :ok | {:error, [atom()]}
  def authorize_changes(module, role, changed_fields) do
    case Enum.reject(changed_fields, &can_edit_field?(module, &1, role)) do
      [] -> :ok
      forbidden -> {:error, forbidden}
    end
  end

  # Admins edit everything; otherwise honor editable_by (nil = any editor).
  defp role_can?(_field, :admin), do: true
  defp role_can?(%{editable_by: nil}, _role), do: true
  defp role_can?(%{editable_by: roles}, role) when is_list(roles), do: role in roles
end
