defmodule KilnCMS.CMS.Validations.TagGroupInTenant do
  @moduledoc """
  A `Tag`'s `tag_group_id`, when set, must name a `TagGroup` in the tag's own
  organization.

  `tags.tag_group_id` is a plain FK to `tag_groups(id)` with **no org component**
  (a composite FK is deliberately not the fix — see #526), while both resources
  are `strategy :attribute` multitenant on `org_id`. Nothing else stops
  `create_tag!(%{tag_group_id: <org B's group>}, tenant: org_a)` — reachable from
  the MCP `create_tag` tool and the AshAdmin form. #513 made such a tag
  *survivable* in the picker (it falls back to "Ungrouped" instead of vanishing),
  but the write should be rejected at the source.

  Resolves the group under the tag's resolved `org_id`, so the group is required
  to be same-org whether or not the deployment runs strict tenancy (a provided
  tenant scopes the read even under `global?: true`).
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :tag_group_id) do
      nil ->
        :ok

      group_id ->
        case KilnCMS.CMS.get_tag_group(group_id, authorize?: false, tenant: org_id(changeset)) do
          {:ok, _group} ->
            :ok

          _not_in_org ->
            {:error,
             InvalidAttribute.exception(
               field: :tag_group_id,
               message: "is not a tag group in this site",
               value: group_id
             )}
        end
    end
  end

  # The writer's org. `to_tenant` (an id via `Ash.ToTenant`, matched as a struct
  # too) is populated at changeset-build time, so it is the value validations can
  # trust — the `org_id` ATTRIBUTE isn't stamped from the tenant until the action
  # runs, so on `:create` it is still nil here. Reading it instead resolved every
  # scoped create under the DEFAULT org, which INVERTED this control: a foreign
  # group filed under a non-default tenant resolved as the default org's and was
  # wrongly accepted, while a legitimate same-org group was rejected. Falls back
  # like `Scoping`.
  defp org_id(%{to_tenant: org_id}) when is_binary(org_id), do: org_id
  defp org_id(%{to_tenant: %{id: org_id}}) when is_binary(org_id), do: org_id

  defp org_id(changeset),
    do: Ash.Changeset.get_attribute(changeset, :org_id) || KilnCMS.Accounts.default_org_id()
end
