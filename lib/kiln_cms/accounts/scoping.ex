defmodule KilnCMS.Accounts.Scoping do
  @moduledoc """
  Resolves an actor's *effective* content-type scope for the request's site
  (granular RBAC #332 × multi-tenancy #336).

  A scope axis (`:editable_types` — which types an editor may author;
  `:readable_types` — which types an editor may see beyond published;
  `field_grants` — which attributes they may change per type) lives in three
  places, resolved most-specific-first:

    1. the user's `KilnCMS.Accounts.OrgMembership` for the request's org —
       the **per-org, per-user** value, so one account can be a blog editor on
       site A and unrestricted on site B;
    2. the membership's assigned `KilnCMS.Accounts.Role` (slice 4) — the named
       bundle, so "Blog editor" is defined once and assigned many times;
    3. `KilnCMS.Accounts.User` itself — the pre-#336 single-org column, kept
       as the final fallback.

  A **non-empty** value wins at each level (empty means "unrestricted", which
  is indistinguishable from "unconfigured" — narrowing is always possible at a
  more specific level, widening means clearing the broader level). The tenant
  comes from the query/changeset under authorization; a tenant-less request
  resolves against the default org — the same org those writes stamp.

  Called from the content policy checks (`EditableContentType` /
  `ReadableContentType`) and the `EnforceFieldGrants` change — the single
  choke points every surface (LiveView, JSON:API, GraphQL, MCP) authorizes
  through. The membership lookup is one indexed `(user_id, organization_id)`
  get (role loaded alongside) per policy evaluation and short-circuits for
  non-editor actors, so the anonymous delivery hot path never pays it.
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
    membership = membership(actor, org_id(subject))

    first_configured([
      fn -> list_axis(membership, axis) end,
      fn -> list_axis(role_of(membership), axis) end,
      fn -> list_axis(actor, axis) end
    ]) || []
  end

  @doc """
  The actor's effective per-field write grant for `type_name` (slice 3).

  `field_grants` is a map of content-type name → list of attribute names the
  editor may change (`%{"post" => ["title", "blocks"]}`). The membership →
  role → user resolution applies to the **whole map**. Returns `nil` when the
  effective map has no entry for `type_name` — no per-field restriction — or
  the list of permitted attribute names.
  """
  @spec field_grant(map(), Ash.Changeset.t() | nil, String.t() | nil) :: [String.t()] | nil
  def field_grant(_actor, _subject, nil), do: nil

  def field_grant(actor, subject, type_name) do
    membership = membership(actor, org_id(subject))

    grants =
      first_configured([
        fn -> map_axis(membership) end,
        fn -> map_axis(role_of(membership)) end,
        fn -> map_axis(actor) end
      ]) || %{}

    Map.get(grants, type_name)
  end

  # First non-nil ("configured") value in resolution order.
  defp first_configured(levels), do: Enum.find_value(levels, & &1.())

  # A list axis counts as configured only when non-empty.
  defp list_axis(nil, _axis), do: nil

  defp list_axis(source, axis) do
    case Map.get(source, axis) do
      scope when is_list(scope) and scope != [] -> scope
      _ -> nil
    end
  end

  # The field-grants map counts as configured only when non-empty.
  defp map_axis(nil), do: nil

  defp map_axis(source) do
    case Map.get(source, :field_grants) do
      grants when is_map(grants) and map_size(grants) > 0 -> grants
      _ -> nil
    end
  end

  defp role_of(%{custom_role: %{} = role}), do: role
  defp role_of(_membership), do: nil

  # The actor's membership for the org, with its custom role loaded — one
  # indexed get, `authorize?: false` (the caller *is* the authorization).
  defp membership(%{id: user_id}, org_id) when is_binary(user_id) and is_binary(org_id) do
    case Accounts.get_org_membership(user_id, org_id,
           authorize?: false,
           not_found_error?: false,
           load: [:custom_role]
         ) do
      {:ok, %{} = membership} -> membership
      _ -> nil
    end
  end

  defp membership(_actor, _org_id), do: nil

  # The org the authorization runs under. Queries/changesets carry the resolved
  # tenant attribute value in `to_tenant` (set by `Ash.ToTenant` from the org
  # struct or id); a tenant-less subject falls back to the default org — the
  # org that tenant-less writes stamp content with (`global?: true`).
  defp org_id(%{to_tenant: org_id}) when is_binary(org_id), do: org_id
  defp org_id(%{tenant: %{id: org_id}}) when is_binary(org_id), do: org_id
  defp org_id(%{tenant: org_id}) when is_binary(org_id), do: org_id
  defp org_id(_subject), do: Accounts.default_org_id()
end
