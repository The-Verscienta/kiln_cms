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
  more specific level, widening means clearing the broader level); the
  `field_grants` map resolves **per type key** across the levels.

  **Affiliation is fail-closed.** A user who holds memberships — the multi-org
  model — gets NO editorial scope on an org they have no membership for: the
  org resolves from the client-controlled host, so falling back to the (often
  empty = unrestricted) user column there would let a scoped editor escape
  their restriction by switching hosts. A user with no memberships at all
  (pre-#336 data that missed the backfill) keeps the user-column behavior
  everywhere. The tenant comes from the query/changeset under authorization;
  a tenant-less request resolves against the default org — the same org those
  writes stamp.

  Called from the content policy checks (`EditableContentType` /
  `ReadableContentType`) and the `EnforceFieldGrants` change — the single
  choke points every surface (LiveView, JSON:API, GraphQL, MCP) authorizes
  through. The membership lookup is one indexed `(user_id, organization_id)`
  get (role loaded alongside), memoized per process for a few seconds
  (several checks run per request), and short-circuits for non-editor actors
  — the anonymous delivery hot path never pays it.
  """

  alias KilnCMS.Accounts

  @axes [:editable_types, :readable_types]

  # How long a resolved affiliation may be reused within one process. Bounds
  # both the per-request duplicate lookups (policy checks + changes each
  # resolve) and staleness in long-lived LiveView processes.
  @memo_ttl_ms 5_000

  @doc """
  Whether `type_name` is inside the actor's effective scope for `axis`.

  An empty effective scope means unrestricted (`true` for every type); a
  non-empty scope admits only the listed type names; a foreign-org actor (no
  membership for the request's org while holding memberships elsewhere) is
  denied every type. A `nil` type name (a resource outside the content macro)
  only passes an unrestricted scope.
  """
  @spec permitted?(map(), Ash.Query.t() | Ash.Changeset.t() | nil, atom(), String.t() | nil) ::
          boolean()
  def permitted?(actor, subject, axis, type_name) when axis in @axes do
    case scope(actor, subject, axis) do
      :denied -> false
      [] -> true
      scope -> type_name in scope
    end
  end

  @doc """
  Whether a **non-empty** effective scope for `axis` names `type_name`.

  Unlike `permitted?/4`, an empty (unrestricted) scope returns `false` — used
  where only an explicit grant should carry extra meaning (e.g. an explicit
  `editable_types` entry implies editorial visibility, but "may author
  everything" must not dissolve a `readable_types` restriction).
  """
  @spec explicitly_permits?(
          map(),
          Ash.Query.t() | Ash.Changeset.t() | nil,
          atom(),
          String.t() | nil
        ) :: boolean()
  def explicitly_permits?(actor, subject, axis, type_name) when axis in @axes do
    case scope(actor, subject, axis) do
      :denied -> false
      [] -> false
      scope -> type_name in scope
    end
  end

  @doc """
  The actor's effective per-field write grant for `type_name` (slice 3).

  `field_grants` is a map of content-type name → list of attribute names the
  editor may change (`%{"post" => ["title", "blocks"]}`). Resolution is
  **per type key** across the levels (membership → role → user) — an override
  for one type at a more specific level never discards a broader level's
  restriction on a *different* type. Returns `nil` when no level grants an
  entry for `type_name` (no per-field restriction), the list of permitted
  attribute names otherwise, and `[]` (nothing changeable) for a foreign-org
  actor. Non-list grant values are ignored defensively — the write-time shape
  validation is the real guard.
  """
  @spec field_grant(map(), Ash.Changeset.t() | nil, String.t() | nil) :: [String.t()] | nil
  def field_grant(_actor, _subject, nil), do: nil

  def field_grant(actor, subject, type_name) do
    case affiliation(actor, org_id(subject)) do
      {:member, membership} ->
        grant_key(membership, type_name) ||
          grant_key(role_of(membership), type_name) ||
          grant_key(actor, type_name)

      :unaffiliated ->
        grant_key(actor, type_name)

      :foreign_org ->
        []
    end
  end

  @doc """
  The actor's **effective capability tier** on the org the subject runs under
  (#419 — per-org tiers): `:admin` | `:editor` | `:viewer` | `:none`.

    * a **platform admin** (`User.role == :admin`) is `:admin` everywhere —
      the operator break-glass; org administration itself stays global;
    * a member's tier on an org is their **membership's** `role` there (what
      `/editor/team` assigns);
    * an affiliated user has **no tier** (`:none`) on an org they hold no
      membership for — fail-closed, matching the scope axes;
    * a user with no memberships at all keeps `User.role` (pre-#336 data).

  `subject` may be the query/changeset under authorization, a raw org id
  (what the web layer passes from `current_org`), or nil (default org).
  """
  @spec effective_tier(map() | nil, Ash.Query.t() | Ash.Changeset.t() | String.t() | nil) ::
          :admin | :editor | :viewer | :none
  def effective_tier(%{role: :admin}, _subject), do: :admin

  def effective_tier(%{} = actor, subject) do
    case affiliation(actor, subject_org_id(subject)) do
      {:member, membership} -> membership.role
      :unaffiliated -> Map.get(actor, :role) || :none
      :foreign_org -> :none
    end
  end

  def effective_tier(_actor, _subject), do: :none

  defp subject_org_id(org_id) when is_binary(org_id), do: org_id
  defp subject_org_id(subject), do: org_id(subject)

  defp scope(actor, subject, axis) do
    case affiliation(actor, org_id(subject)) do
      {:member, membership} ->
        list_axis(membership, axis) || list_axis(role_of(membership), axis) ||
          list_axis(actor, axis) || []

      :unaffiliated ->
        list_axis(actor, axis) || []

      :foreign_org ->
        :denied
    end
  end

  # A list axis counts as configured only when non-empty.
  defp list_axis(nil, _axis), do: nil

  defp list_axis(source, axis) do
    case Map.get(source, axis) do
      scope when is_list(scope) and scope != [] -> scope
      _ -> nil
    end
  end

  defp grant_key(nil, _type_name), do: nil

  defp grant_key(source, type_name) do
    with grants when is_map(grants) <- Map.get(source, :field_grants),
         fields when is_list(fields) <- Map.get(grants, type_name) do
      fields
    else
      _ -> nil
    end
  end

  defp role_of(%{custom_role: %{} = role}), do: role
  defp role_of(_membership), do: nil

  # ── membership affiliation ─────────────────────────────────────────────────

  # The actor's relationship to the org, memoized per process:
  #   {:member, membership} — a membership row exists for this org;
  #   :foreign_org          — the user holds memberships, none for this org;
  #   :unaffiliated         — the user holds no memberships at all (legacy).
  defp affiliation(%{id: user_id}, org_id) when is_binary(user_id) and is_binary(org_id) do
    memo({__MODULE__, user_id, org_id}, fn -> resolve_affiliation(user_id, org_id) end)
  end

  defp affiliation(_actor, _org_id), do: :unaffiliated

  defp resolve_affiliation(user_id, org_id) do
    case Accounts.get_org_membership(user_id, org_id,
           authorize?: false,
           not_found_error?: false,
           load: [:custom_role]
         ) do
      {:ok, %{} = membership} -> {:member, membership}
      _ -> if any_membership?(user_id), do: :foreign_org, else: :unaffiliated
    end
  end

  defp any_membership?(user_id) do
    case Accounts.list_memberships_for_user(user_id, authorize?: false, query: [limit: 1]) do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end

  defp memo(key, fun) do
    now = System.monotonic_time(:millisecond)
    ttl = memo_ttl_ms()

    case Process.get(key) do
      {value, at} when now - at < ttl ->
        value

      _ ->
        value = fun.()
        Process.put(key, {value, now})
        value
    end
  end

  # Config-overridable so tests (which mutate memberships/roles mid-process)
  # can turn the memo off; production keeps the default.
  defp memo_ttl_ms do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(:memo_ttl_ms, @memo_ttl_ms)
  end

  # The org the authorization runs under. Queries/changesets carry the resolved
  # tenant in `to_tenant` (an id via `Ash.ToTenant`, defensively also matched
  # as a struct) or `tenant`; a tenant-less subject falls back to the default
  # org — the org that tenant-less writes stamp content with (`global?: true`).
  defp org_id(%{to_tenant: org_id}) when is_binary(org_id), do: org_id
  defp org_id(%{to_tenant: %{id: org_id}}) when is_binary(org_id), do: org_id
  defp org_id(%{tenant: %{id: org_id}}) when is_binary(org_id), do: org_id
  defp org_id(%{tenant: org_id}) when is_binary(org_id), do: org_id
  defp org_id(_subject), do: Accounts.default_org_id()
end
