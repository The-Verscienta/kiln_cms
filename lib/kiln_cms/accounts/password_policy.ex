defmodule KilnCMS.Accounts.PasswordPolicy do
  @moduledoc """
  What the breached-password check does for one password being set (#2240):
  `:off`, `:warn` or `:block`.

  ## The ladder

  The request org's `KilnCMS.CMS.SitePasswordPolicy` row, then the operator's
  default (`BREACHED_PASSWORD_POLICY`, `KilnCMS.Accounts.BreachedPassword`),
  then `:warn`. With the deployment switch off (`BREACHED_PASSWORD_CHECK=false`)
  the answer is `:off` whatever any row says.

  `:block` only ever applies to an account whose tier is `:admin`; for an
  editor or a viewer it reads as `:warn`. The tier is the **target** account's
  (the one whose password is being set), never the actor's: a reset is done by
  the owner of an account an attacker may already hold, and a registration has
  no actor.

  ## The target's tier

  `target_tier/2` is the stricter of the account's standing or granted tier
  (`KilnCMS.Accounts.RoleGrant.effective_role/1`) and its tier on the request's
  org (`KilnCMS.Accounts.Scoping.effective_tier/2`), so an account that is a
  viewer globally but an admin of this org by membership gets `:block`.

  ## Every org the target administers (#2408)

  An account that administers several sites is held to the **strictest**
  policy among them, whichever site the password is set on:

      policy = strictest(downgrade(request org's, tier),
                         strictest(policy of each org the target administers))

  ordered `:off < :warn < :block`. The request org's policy is downgraded for
  a non-admin target as above; an admin org's is not (the target is its admin).
  An admin org with no row brings in the operator's default, so a site's `:off`
  does not spare an account that administers another site that checks.
  "Administers" is `KilnCMS.Accounts.Scoping.admin_org_ids/1`: every org for a
  platform admin, else the orgs where an `:active` membership is effectively
  `:admin`, live temporary grants included; none for an erased account.
  `resolve_for/3` takes the target; `resolve/2` is `resolve_for(nil, …)`, for
  an account that does not exist yet (a registration, the first-run setup).

  The rows are read in a bounded number of queries, whatever the number of
  orgs: one membership query and one `org_id in …` read for a member; for a
  platform admin, one read of the distinct values across every org, and only
  when the operator default could change the answer, a count of rows against
  a count of orgs.

  ## At sign-in (#2407)

  `sign_in/1` answers a different question: whether an administrator's
  password is looked up as they sign in, and under which policy. Only the
  orgs they administer whose row has `check_on_sign_in` on take part, the
  strictest of their policies decides, and the request's org plays no part.
  It reads the same rows through the same cross-org actions, and fails open
  to "not checking".

  ## Failing open

  The row is read as `KilnCMS.OrgSettings.system(:accounts)` with
  `authorize_with: :error`, so a refused read is an error and not "no row". An
  unreadable row (refusal, missing table mid-deploy, pool timeout) is logged
  and answered `:warn`: neither silently off nor blocking. The row is read
  here, on the caller's process and outside any spawned task, so the test
  sandbox's ownership holds. Not cached: a changed setting applies to the next
  password. The cross-org read fails open the same way: one warning naming
  nothing, and `:warn` for its part of the answer.
  """

  require Ash.Query
  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.BreachedPassword
  alias KilnCMS.Accounts.RoleGrant
  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS
  alias KilnCMS.CMS.SitePasswordPolicy
  alias KilnCMS.OrgSettings

  @type policy :: :off | :warn | :block
  @type tier :: :admin | :editor | :viewer | :none

  @tiers [:none, :viewer, :editor, :admin]

  # What the cross-org reads select: the org and its stance, nothing else.
  @row_fields [:org_id, :breached_password_policy, :check_on_sign_in]

  @doc """
  The policy for setting a password on an account of `target_tier` in `org`
  (an org id, an `Organization`, or `nil` for the default org), for an account
  that does not exist yet: `resolve_for(nil, org, target_tier)`.
  """
  @spec resolve(Accounts.Organization.t() | Ash.UUID.t() | nil, tier() | atom()) :: policy()
  def resolve(org, target_tier), do: resolve_for(nil, org, target_tier)

  @doc """
  The policy for setting `target`'s password in `org`, where `target_tier` is
  its tier there (`target_tier/2`): the strictest of `org`'s policy for that
  tier and the policy of every org `target` administers (#2408). `target` is
  `nil` for an account that does not exist yet.

  Never fails: an unreadable row is `:warn` for its part of the answer.
  """
  @spec resolve_for(map() | nil, Accounts.Organization.t() | Ash.UUID.t() | nil, tier() | atom()) ::
          policy()
  def resolve_for(target, org, target_tier) do
    if BreachedPassword.enabled?() do
      own =
        case org_policy(org, target_tier) do
          {:ok, policy} -> policy
          :error -> :warn
        end

      strictest(own, admin_orgs_part(target))
    else
      :off
    end
  end

  @doc """
  `resolve/2`, telling an unreadable row (`:error`) apart from the `:warn`
  `resolve/2` answers for it. For the Security posture page (#2252), which
  must not report a setting it cannot see: `read_for(nil, org, target_tier)`.
  """
  @spec read(Accounts.Organization.t() | Ash.UUID.t() | nil, tier() | atom()) ::
          {:ok, policy()} | :error
  def read(org, target_tier), do: read_for(nil, org, target_tier)

  @doc """
  `resolve_for/3`, answering `:error` when `org`'s own row cannot be read. A
  failure to read the rows of the orgs `target` administers is not an
  `:error` here: it is logged and counts as `:warn`, as in `resolve_for/3`.
  """
  @spec read_for(map() | nil, Accounts.Organization.t() | Ash.UUID.t() | nil, tier() | atom()) ::
          {:ok, policy()} | :error
  def read_for(target, org, target_tier) do
    if BreachedPassword.enabled?() do
      with {:ok, own} <- org_policy(org, target_tier) do
        {:ok, strictest(own, admin_orgs_part(target))}
      end
    else
      {:ok, :off}
    end
  end

  @doc """
  Whether `org`'s own row asks for administrators' passwords to be checked at
  sign-in (#2407): `{:ok, false}` with no row, `:error` when the row cannot be
  read. For the Security posture page; the switch alone, whatever the
  deployment's `BREACHED_PASSWORD_CHECK`.
  """
  @spec read_sign_in_check(Accounts.Organization.t() | Ash.UUID.t() | nil) ::
          {:ok, boolean()} | :error
  def read_sign_in_check(org) do
    actor = OrgSettings.system(:accounts)

    resolved =
      OrgSettings.resolve_uncached(Accounts.org_id(org),
        read: &CMS.list_site_password_policy(tenant: &1, actor: actor, authorize_with: :error),
        # `nil` is reserved for "could not read", so "no row" is its own value.
        build: fn
          nil -> {:row, false}
          row -> {:row, row.check_on_sign_in == true}
        end,
        label: "breached password sign-in check"
      )

    case resolved do
      {:row, check?} -> {:ok, check?}
      nil -> :error
    end
  end

  @doc """
  Whether `user`'s password is looked up as they sign in with it (#2407), and
  which policy decides the outcome: `{:check, :warn | :block}` or `:skip`.

  Only an administrator is ever checked, and only by a site that asks for it:
  the orgs `user` administers (`KilnCMS.Accounts.Scoping.admin_org_ids/1`)
  whose row has `check_on_sign_in` on. The policy is the strictest of those
  rows' alone; an admin org with the switch off plays no part, so one site's
  switch never changes what another site's policy does at sign-in. A platform
  admin answers to every org with the switch on. The org the request came in
  on plays no part either, so every host and door decides alike.

  `:skip` when the deployment's check is off, when `user` administers no org
  with the switch on, when their policy is `:off`, and when anything here
  cannot be read: a sign-in is never refused for want of a setting (one
  warning naming nothing about the account).
  """
  @spec sign_in(map() | nil) :: :skip | {:check, :warn | :block}
  def sign_in(user) do
    case sign_in_decision(user) do
      {:check, policy, _deciding} -> {:check, policy}
      :skip -> :skip
    end
  end

  @doc """
  `sign_in/1` with the orgs whose policy decided it, as a function returning
  their ids: the admin orgs with the switch on whose policy is the one
  returned. A function so that the read it may cost (for a platform admin) is
  only made by a caller that needs it, the audit of a refused sign-in. It
  raises on a failed read.
  """
  @spec sign_in_decision(map() | nil) ::
          :skip | {:check, :warn | :block, (-> [Ash.UUID.t()])}
  def sign_in_decision(user) do
    if BreachedPassword.enabled?(), do: sign_in_rows(user), else: :skip
  rescue
    # Boundary: a failure to work out whether to check must not stop a
    # sign-in. Fail open, and say nothing about who.
    _error -> sign_in_error()
  end

  defp sign_in_rows(user) do
    scope = admin_scope(user)

    case rows_for(scope) do
      {:ok, rows, _uncovered?} ->
        checking = Enum.filter(rows, &(&1.check_on_sign_in == true))

        case strictest_of(checking) do
          policy when policy in [:warn, :block] ->
            {:check, policy, deciding_orgs(scope, checking, policy)}

          _off_or_none ->
            :skip
        end

      :error ->
        sign_in_error()
    end
  end

  # A member's rows are each one org's, so the ids are at hand. A platform
  # admin's are one per distinct value, so the ids are read when asked for.
  defp deciding_orgs(:all, _rows, policy), do: fn -> deciding_reader().(policy) end

  defp deciding_orgs(_member, rows, policy) do
    ids = for row <- rows, row.breached_password_policy == policy, uniq: true, do: row.org_id
    fn -> ids end
  end

  @doc false
  # Test seam (#3438): run `fun` with a platform admin's deciding-site read
  # (the thunk `sign_in_decision/1` returns) answered by `reader`, a function
  # of the policy, in this process. The decision and that read are the same
  # action with the same actor, so nothing else can fail the one and leave the
  # other. Like `OrgSettings.system/1`, the `Process.get` in `deciding_reader/0`
  # runs in production, once per refused platform-admin sign-in; only this
  # override is test-only. Process-local, restored afterwards, and nothing on a
  # request path calls it.
  @spec with_deciding_reader((:warn | :block -> [Ash.UUID.t()]), (-> result)) :: result
        when result: term()
  def with_deciding_reader(reader, fun) when is_function(reader, 1) do
    key = {__MODULE__, :deciding_reader}
    previous = Process.get(key, :unset)
    Process.put(key, reader)

    try do
      fun.()
    after
      if previous == :unset, do: Process.delete(key), else: Process.put(key, previous)
    end
  end

  defp deciding_reader, do: Process.get({__MODULE__, :deciding_reader}, &orgs_checking_with/1)

  defp orgs_checking_with(policy) do
    query =
      SitePasswordPolicy
      |> Ash.Query.filter(check_on_sign_in == true and breached_password_policy == ^policy)
      |> Ash.Query.select([:org_id])

    [actor: OrgSettings.system(:accounts), authorize_with: :error, query: query]
    |> CMS.list_all_site_password_policies!()
    |> Enum.map(& &1.org_id)
  end

  defp sign_in_error do
    Logger.warning("breached-password sign-in policy could not be resolved; not checking")
    :skip
  end

  defp org_policy(org, target_tier) do
    with {:ok, policy} <- org |> Accounts.org_id() |> configured() do
      {:ok, downgrade(policy, target_tier)}
    end
  end

  defp admin_orgs_part(target) do
    case admin_orgs_policy(target) do
      {:ok, nil} -> :off
      {:ok, policy} -> policy
      :error -> :warn
    end
  end

  @doc """
  The stricter of `user`'s own (possibly temporary) role and its tier on `org`.
  `nil` — an account that does not exist yet — is a `:viewer`, which is what
  self-registration creates.
  """
  @spec target_tier(map() | nil, Accounts.Organization.t() | Ash.UUID.t() | nil) :: tier()
  def target_tier(nil, _org), do: :viewer

  def target_tier(%{} = user, org) do
    own = normalize(RoleGrant.effective_role(user))
    on_org = normalize(Scoping.effective_tier(user, Accounts.org_id(org)))
    Enum.max_by([own, on_org], &Enum.find_index(@tiers, fn tier -> tier == &1 end))
  end

  defp normalize(tier) when tier in @tiers, do: tier
  defp normalize(_other), do: :none

  # The stricter of two policies: `:off < :warn < :block`.
  defp strictest(a, b), do: if(rank(a) >= rank(b), do: a, else: b)

  defp rank(:off), do: 0
  defp rank(:warn), do: 1
  defp rank(:block), do: 2

  defp downgrade(:block, :admin), do: :block
  defp downgrade(:block, _tier), do: :warn
  defp downgrade(policy, _tier), do: policy

  defp configured(org_id) do
    actor = KilnCMS.OrgSettings.system(:accounts)

    resolved =
      KilnCMS.OrgSettings.resolve_uncached(org_id,
        read:
          &KilnCMS.CMS.list_site_password_policy(
            tenant: &1,
            actor: actor,
            authorize_with: :error
          ),
        # `nil` is reserved for "could not read", so "no row" is its own value.
        build: fn
          nil -> {:operator, BreachedPassword.default_policy()}
          row -> {:site, row.breached_password_policy}
        end,
        label: "breached password policy"
      )

    case resolved do
      {_source, policy} -> {:ok, policy}
      nil -> :error
    end
  end

  # The strictest policy across the orgs `target` administers, with no
  # downgrade (it is their admin): `{:ok, nil}` when it administers none.
  # Every failure — a refused or failed read, a raise — is `:error`, logged
  # once and naming nothing about the account.
  @spec admin_orgs_policy(map() | nil) :: {:ok, policy() | nil} | :error
  defp admin_orgs_policy(target) do
    case admin_org_rows(target) do
      {:ok, rows, uncovered?} ->
        from_rows = strictest_of(rows)
        default = BreachedPassword.default_policy()

        # The operator default takes part only for an admin org with no row,
        # and is only worth asking about when it would be the stricter.
        if (from_rows == nil or rank(default) > rank(from_rows)) and uncovered?.(),
          do: {:ok, strictest_or_nil(default, from_rows)},
          else: {:ok, from_rows}

      :error ->
        admin_orgs_error()
    end
  rescue
    # Boundary: a failure to read the other orgs must not stop a password
    # being set. Fail open to the default stance, and say nothing about who.
    _error -> admin_orgs_error()
  end

  defp strictest_of(rows) do
    rows
    |> Enum.map(& &1.breached_password_policy)
    |> Enum.reduce(nil, &strictest_or_nil/2)
  end

  defp strictest_or_nil(policy, nil), do: policy
  defp strictest_or_nil(policy, other), do: strictest(policy, other)

  # The saved rows of the orgs `target` administers, as `{:ok, rows,
  # uncovered?}`: for a platform admin one row per distinct pair of values
  # across every org (its `org_id` is any one org holding them). `uncovered?`
  # is a thunk answering whether some admin org has no row (whose policy is
  # then the operator default), so it costs a query only when asked. `:error`
  # when a read is refused or fails.
  defp admin_org_rows(target), do: target |> admin_scope() |> rows_for()

  defp admin_scope(nil), do: []
  defp admin_scope(target), do: Scoping.admin_org_ids(target)

  defp rows_for([]), do: {:ok, [], fn -> false end}
  defp rows_for(:all), do: all_org_rows()
  defp rows_for(org_ids), do: member_org_rows(org_ids)

  defp member_org_rows(org_ids) do
    case CMS.list_site_password_policies_for_orgs(org_ids,
           actor: OrgSettings.system(:accounts),
           authorize_with: :error,
           query: [select: @row_fields]
         ) do
      {:ok, rows} ->
        covered = rows |> Enum.map(& &1.org_id) |> Enum.uniq() |> length()
        {:ok, rows, fn -> covered < length(org_ids) end}

      {:error, _error} ->
        :error
    end
  end

  defp all_org_rows do
    actor = OrgSettings.system(:accounts)

    distinct =
      SitePasswordPolicy
      |> Ash.Query.select(@row_fields)
      |> Ash.Query.distinct([:breached_password_policy, :check_on_sign_in])

    case CMS.list_all_site_password_policies(
           actor: actor,
           authorize_with: :error,
           query: distinct
         ) do
      {:ok, rows} -> {:ok, rows, fn -> some_org_without_row?(actor) end}
      {:error, _error} -> :error
    end
  end

  # Whether some org has no row: fewer rows than orgs (one row per org at
  # most, the `:one_per_org` identity). Raises on a failed read, which
  # `admin_orgs_policy/1` turns into its `:error`.
  defp some_org_without_row?(actor) do
    rows =
      SitePasswordPolicy
      |> Ash.Query.for_read(:all_orgs, %{}, actor: actor)
      |> Ash.count!(actor: actor)

    # authorize?: false — a bare count of the deployment's orgs, never shown;
    # Organization's read is per person and this caller may have no actor.
    orgs = Ash.count!(Accounts.Organization, authorize?: false)
    rows < orgs
  end

  defp admin_orgs_error do
    Logger.warning(
      "breached-password policy of the account's other sites could not be read; treating as warn"
    )

    :error
  end
end
