defmodule KilnCMS.Accounts.Scoping do
  @moduledoc """
  Resolves an actor's *effective* content-type scope for the request's site
  (granular RBAC #332 × multi-tenancy #336).

  A scope axis (`:editable_types` — which types an editor may author;
  `:readable_types` — which types an editor may see beyond published) lives in
  two places:

    * on the user's `KilnCMS.Accounts.OrgMembership` for the request's org —
      the **per-org** value, so one account can be a blog editor on site A and
      unrestricted on site B; and
    * on `KilnCMS.Accounts.User` itself — the pre-#336 single-org column, kept
      as the fallback.

  Resolution: a **non-empty** membership scope wins; otherwise the user column
  applies. (An empty list means "unrestricted" on both levels, so an empty
  membership can't be distinguished from an unconfigured one — narrowing is
  always possible per-org, widening means clearing the user column. Slice 4's
  named roles subsume this.) The tenant comes from the query/changeset under
  authorization; a tenant-less request resolves against the default org — the
  same org those writes stamp content with.

  Called from the content policy checks (`EditableContentType` /
  `ReadableContentType`), which is the single choke point every surface
  (LiveView, JSON:API, GraphQL, MCP) authorizes through. The membership lookup
  is one indexed `(user_id, organization_id)` get per policy evaluation and
  short-circuits for non-editor actors, so the anonymous delivery hot path
  never pays it.
  """

  alias KilnCMS.Accounts

  @axes [:editable_types, :readable_types]

  @doc """
  Whether `type_name` is inside the actor's effective scope for `axis`.

  An empty effective scope means unrestricted (`true` for every type); a
  non-empty scope admits only the listed type names. A `nil` type name (a
  resource outside the content macro) only passes an unrestricted scope.
  """
  @spec permitted?(map(), Ash.Query.t() | Ash.Changeset.t() | nil, atom(), String.t() | nil) ::
          boolean()
  def permitted?(actor, subject, axis, type_name) when axis in @axes do
    case effective_types(actor, subject, axis) do
      [] -> true
      scope -> type_name in scope
    end
  end

  @doc """
  The actor's effective scope list for `axis` under `subject`'s tenant.
  `[]` = unrestricted.
  """
  @spec effective_types(map(), Ash.Query.t() | Ash.Changeset.t() | nil, atom()) :: [String.t()]
  def effective_types(actor, subject, axis) when axis in @axes do
    membership_types(actor, org_id(subject), axis) || user_types(actor, axis)
  end

  # The per-org value, when a membership exists and configures this axis.
  # Returns nil (→ user-column fallback) when there is no membership row or its
  # scope is empty/unset.
  defp membership_types(%{id: user_id}, org_id, axis)
       when is_binary(user_id) and is_binary(org_id) do
    case Accounts.get_org_membership(user_id, org_id,
           authorize?: false,
           not_found_error?: false
         ) do
      {:ok, %{} = membership} ->
        case Map.get(membership, axis) do
          scope when scope in [nil, []] -> nil
          scope -> scope
        end

      _ ->
        nil
    end
  end

  defp membership_types(_actor, _org_id, _axis), do: nil

  defp user_types(actor, axis) do
    case Map.get(actor, axis) do
      scope when is_list(scope) -> scope
      _ -> []
    end
  end

  # The org the authorization runs under. Queries/changesets carry the resolved
  # tenant attribute value in `to_tenant` (set by `Ash.ToTenant` from the org
  # struct or id); a tenant-less subject falls back to the default org — the
  # org that tenant-less writes stamp content with (`global?: true`).
  defp org_id(%{to_tenant: org_id}) when is_binary(org_id), do: org_id
  defp org_id(%{tenant: %{id: org_id}}) when is_binary(org_id), do: org_id
  defp org_id(%{tenant: org_id}) when is_binary(org_id), do: org_id
  defp org_id(_subject), do: Accounts.default_org_id()
end
