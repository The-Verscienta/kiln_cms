defmodule KilnCMS.Accounts.TwoFactorRequirement do
  @moduledoc """
  Whether a site requires an account to hold a second factor, and from when
  (#2247).

  ## The policy

  A site's `KilnCMS.CMS.SiteSecondFactorPolicy` row: off (the default, and a
  site with no row), or required for administrators, for editors and
  administrators, or for everyone, with a grace period of 0 to 90 days.

  `policy/1` caches it for a minute; a save busts it on every node and tells
  the site's open pages on `topic/1`. A row that cannot be read is logged and
  read as off, uncached: the requirement fails open rather than holding every
  account during a database blip, as `KilnCMS.Accounts.IdleTimeout` does.
  `read_policy/1` tells the two apart for the Security posture page.

  ## An account's status on a site

  `status/3`, cheapest question first:

    1. the policy is off — `:not_required`;
    2. the account is erased, or demo mode locks its credentials
       (`KilnCMS.Demo.locks_credentials?/1`) — `:not_required`;
    3. its tier here (`KilnCMS.Accounts.Scoping.tier_source/2`) is not
       covered — `:not_required`;
    4. it has an authenticator app, or a passkey — `:enrolled`;
    5. otherwise `{:grace, deadline}` before the deadline and
       `{:enforced, deadline}` from it.

  ## The deadline

  The grace starts at the latest of: when the account was created
  (`User.inserted_at`), when its tier became covered on this site (the
  policy's per-tier stamp), and — when the tier comes from a membership —
  when that membership was created. The deadline is that plus the grace.

  A promotion changes the membership's tier, not its `inserted_at`, so it
  does not restart the grace: a long-standing viewer promoted to admin on a
  site that requires admins is held at once (decision 6 on #2247). A
  temporary grant is read from the same membership or user row.

  ## What it does not do

  Nothing here holds anyone: this module answers questions. The doors that act
  on the answers come with the enforcement.
  """
  require Ash.Query

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.RoleGrant
  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS.SiteSecondFactorPolicy

  defmodule Policy do
    @moduledoc """
    A site's resolved two-step sign-in requirement (#2247): who it covers, the
    grace in days, and when each tier became covered (`nil` for a tier it does
    not cover). Never `nil` itself — "off" is an answer, not a failure.
    """
    defstruct required_for: :off,
              grace_days: 14,
              since: %{admin: nil, editor: nil, viewer: nil}

    @type tier :: :admin | :editor | :viewer

    @type t :: %__MODULE__{
            required_for: :off | :admins | :editors | :everyone,
            grace_days: non_neg_integer(),
            since: %{tier() => DateTime.t() | nil}
          }
  end

  @typedoc "An account's standing under a site's policy."
  @type status :: :not_required | :enrolled | {:grace, DateTime.t()} | {:enforced, DateTime.t()}

  @typedoc "Which second factor a sign-in must pass before it completes."
  @type step_up :: :totp | :passkey_only | :none

  @typedoc "Per tier: how many covered accounts, and where they stand."
  @type tier_roster :: %{
          total: non_neg_integer(),
          enrolled: non_neg_integer(),
          in_grace: non_neg_integer(),
          overdue: non_neg_integer(),
          earliest_deadline: DateTime.t() | nil
        }

  @ttl :timer.seconds(60)

  @doc "The PubSub topic a site's open pages hear policy changes on."
  @spec topic(Ash.UUID.t()) :: String.t()
  def topic(org_id) when is_binary(org_id), do: "second_factor_policy:#{org_id}"

  @doc "The policy that means \"off\"."
  @spec off() :: Policy.t()
  def off, do: %Policy{}

  @doc """
  The resolved policy of `org_id`, cached for a minute. An unreadable row is
  logged and answered `off/0`, uncached.
  """
  @spec policy(Ash.UUID.t() | nil) :: Policy.t()
  def policy(org_id) when is_binary(org_id) do
    actor = KilnCMS.OrgSettings.system(:accounts)

    KilnCMS.OrgSettings.resolve(org_id,
      cache_key: KilnCMS.Cache.second_factor_policy_key(org_id),
      ttl: @ttl,
      read:
        &KilnCMS.CMS.list_site_second_factor_policy(
          tenant: &1,
          actor: actor,
          authorize_with: :error
        ),
      build: &from_row/1,
      fallback: &off/0,
      label: "second factor policy"
    )
  end

  def policy(_no_org), do: off()

  @doc """
  The policy of `org_id` read now, uncached, telling an unreadable row
  (`:error`) apart from "off". For the Security posture page, which must not
  report a requirement it cannot see as one that is unset.
  """
  @spec read_policy(Ash.UUID.t()) :: {:ok, Policy.t()} | :error
  def read_policy(org_id) when is_binary(org_id) do
    actor = KilnCMS.OrgSettings.system(:accounts)

    case KilnCMS.OrgSettings.resolve_uncached(org_id,
           read:
             &KilnCMS.CMS.list_site_second_factor_policy(
               tenant: &1,
               actor: actor,
               authorize_with: :error
             ),
           build: &from_row/1,
           label: "second factor policy"
         ) do
      %Policy{} = policy -> {:ok, policy}
      nil -> :error
    end
  end

  @doc """
  A `SiteSecondFactorPolicy` row (or `nil`, no row) as a `Policy`.

  A covered tier with no stamp (a row written outside the actions) starts from
  `policy_changed_at`, so it is never read as covered since the beginning of
  time — which would hold every existing account at once.
  """
  @spec from_row(struct() | nil) :: Policy.t()
  def from_row(nil), do: off()

  def from_row(row) do
    covered = SiteSecondFactorPolicy.covered_tiers(row.required_for)

    since =
      Map.new(SiteSecondFactorPolicy.tiers(), fn tier ->
        stamp =
          if tier in covered,
            do: stamp(row, tier) || row.policy_changed_at || row.updated_at

        {tier, stamp}
      end)

    %Policy{required_for: row.required_for, grace_days: row.grace_days, since: since}
  end

  defp stamp(row, :admin), do: row.admin_required_since
  defp stamp(row, :editor), do: row.editor_required_since
  defp stamp(row, :viewer), do: row.viewer_required_since

  @doc "Whether `policy` requires a second factor of an account of `tier`."
  @spec covers?(Policy.t(), atom()) :: boolean()
  def covers?(%Policy{required_for: required_for}, tier),
    do: tier in SiteSecondFactorPolicy.covered_tiers(required_for)

  @doc """
  When an account must hold a second factor by, given its tier source on the
  site (`Scoping.tier_source/2`'s `{tier, source, record}`), or `nil` when the
  policy does not cover that tier.
  """
  @spec deadline(Accounts.User.t(), Scoping.sourced_tier(), Policy.t()) :: DateTime.t() | nil
  def deadline(user, {tier, source, record}, %Policy{} = policy) do
    if covers?(policy, tier) do
      membership_start = if source == :member, do: Map.get(record, :inserted_at)

      [Map.get(user, :inserted_at), policy.since[tier], membership_start]
      |> Enum.filter(&match?(%DateTime{}, &1))
      |> latest()
      |> DateTime.add(policy.grace_days * 86_400, :second)
    end
  end

  defp latest([]), do: DateTime.utc_now()
  defp latest(times), do: Enum.max(times, DateTime)

  @doc """
  `user`'s standing on `org_id`. See the moduledoc for the order.

  Options: `:policy` (skip the cached read), `:now`, `:tier_source` (skip the
  tier lookup).
  """
  @spec status(Accounts.User.t(), Ash.UUID.t() | nil, keyword()) :: status()
  def status(user, org_id, opts \\ []) do
    policy = Keyword.get_lazy(opts, :policy, fn -> policy(org_id) end)

    cond do
      policy.required_for == :off -> :not_required
      exempt?(user) -> :not_required
      true -> covered_status(user, tier_source(user, org_id, opts), policy, opts)
    end
  end

  defp covered_status(user, {tier, _source, _record} = sourced, policy, opts) do
    cond do
      not covers?(policy, tier) -> :not_required
      Accounts.totp_enabled?(user) -> :enrolled
      passkey?(user) -> :enrolled
      true -> timed(deadline(user, sourced, policy), now(opts))
    end
  end

  defp timed(deadline, now) do
    if DateTime.compare(now, deadline) == :lt,
      do: {:grace, deadline},
      else: {:enforced, deadline}
  end

  @doc """
  Which second factor a first-factor sign-in of `user` on `org_id` must pass:

    * `:totp` — the account has an authenticator app (whatever the policy:
      the code prompt predates it);
    * `:passkey_only` — no app, a passkey, a covered tier and the deadline
      passed: once enforced, the password alone is not enough, even though
      the account counts as enrolled;
    * `:none` — otherwise.
  """
  @spec step_up(Accounts.User.t(), Ash.UUID.t() | nil, keyword()) :: step_up()
  def step_up(user, org_id, opts \\ []) do
    if Accounts.totp_enabled?(user) do
      :totp
    else
      policy = Keyword.get_lazy(opts, :policy, fn -> policy(org_id) end)
      passkey_step_up(user, org_id, policy, opts)
    end
  end

  defp passkey_step_up(%{} = _user, _org_id, %Policy{required_for: :off}, _opts), do: :none

  defp passkey_step_up(user, org_id, policy, opts) do
    sourced = tier_source(user, org_id, opts)
    deadline = deadline(user, sourced, policy)

    cond do
      exempt?(user) -> :none
      is_nil(deadline) -> :none
      DateTime.compare(now(opts), deadline) == :lt -> :none
      passkey?(user) -> :passkey_only
      true -> :none
    end
  end

  @doc """
  Whether any site requires `user` to hold a second factor: a site where they
  hold a membership whose tier its policy covers; the default site for an
  account with no memberships; any site that covers administrators, for a
  platform administrator (they are an administrator everywhere).

  For refusing the removal of an account's last factor. A platform
  administrator's answer reads every site's (cached) policy.
  """
  @spec required_somewhere?(Accounts.User.t()) :: boolean()
  def required_somewhere?(user) do
    if exempt?(user) do
      false
    else
      user
      |> candidate_orgs()
      |> Enum.any?(fn org_id ->
        {tier, _source, _record} = Scoping.tier_source(user, org_id)
        covers?(policy(org_id), tier)
      end)
    end
  end

  defp candidate_orgs(user) do
    if RoleGrant.effective_role(user) == :admin do
      Accounts.list_org_ids()
    else
      case Accounts.list_memberships_for_user!(user.id, actor: user) do
        [] -> [Accounts.default_org_id()]
        memberships -> memberships |> Enum.map(& &1.organization_id) |> Enum.uniq()
      end
    end
  end

  @doc """
  What making `user` a `new_tier` on `org_id` would mean for them, for a
  warning to the admin doing it (decision 6 on #2247): `nil` (the tier is not
  covered, or they hold a factor or are exempt), `{:grace, deadline}`, or
  `{:enforced_now, deadline}` — the promotion does not restart the grace, so
  a long-standing account is held at once.
  """
  @spec promotion_warning(Accounts.User.t(), Ash.UUID.t(), :admin | :editor | :viewer, keyword()) ::
          nil | {:grace, DateTime.t()} | {:enforced_now, DateTime.t()}
  def promotion_warning(user, org_id, new_tier, opts \\ []) do
    policy = Keyword.get_lazy(opts, :policy, fn -> policy(org_id) end)

    cond do
      not covers?(policy, new_tier) -> nil
      exempt?(user) -> nil
      Accounts.has_second_factor?(user) -> nil
      true -> promoted(user, org_id, new_tier, policy, opts)
    end
  end

  defp promoted(user, org_id, new_tier, policy, opts) do
    {_tier, source, record} = tier_source(user, org_id, opts)

    # A new member's membership is created by the promotion itself: now.
    record =
      if source == :member, do: record, else: %{inserted_at: now(opts)}

    deadline = deadline(user, {new_tier, :member, record}, policy)

    case timed(deadline, now(opts)) do
      {:grace, deadline} -> {:grace, deadline}
      {:enforced, deadline} -> {:enforced_now, deadline}
    end
  end

  @doc """
  The site's covered accounts, per covered tier: how many, how many hold a
  factor, how many are in their grace and how many are past it, and the
  earliest deadline still ahead. For the policy page and the posture check.

  Built on `Scoping.users_with_tier_query/2`, so the tiers are disjoint and a
  platform administrator is counted with the administrators, as `status/3`
  holds them. Erased accounts are left out, and so, in demo mode, are the
  accounts whose credentials it locks. Raises on a failed read rather than
  answering zeros.
  """
  @spec roster(Ash.UUID.t(), Policy.t(), keyword()) :: %{Policy.tier() => tier_roster()}
  def roster(org_id, %Policy{} = policy, opts \\ []) do
    now = now(opts)

    for tier <- SiteSecondFactorPolicy.tiers(), covers?(policy, tier), into: %{} do
      {tier, tier_roster(org_id, tier, policy, now)}
    end
  end

  defp tier_roster(org_id, tier, policy, now) do
    base = roster_query(org_id, tier)

    # authorize?: false — a roster of the site's people, as the review-request
    # and posture rosters read it (`Scoping.users_with_tier/2`): `User`'s read
    # policy is self-only, and a system grant on it would be a standing read of
    # every account (#1402). Unauthorized, the read cannot be filtered to
    # nothing, so a lost grant can never undercount; only counts and deadlines
    # leave this function.
    total = Ash.count!(base, authorize?: false)

    unenrolled =
      base
      |> Ash.Query.filter(
        is_nil(totp_confirmed_at) and
          not exists(KilnCMS.Accounts.Passkey, user_id == parent(id))
      )
      |> Ash.Query.select([:id, :inserted_at, :role, :granted_role, :granted_role_expires_at])
      |> Ash.Query.load(
        org_memberships:
          KilnCMS.Accounts.OrgMembership
          |> Ash.Query.filter(organization_id == ^org_id)
          |> Ash.Query.select([:id, :inserted_at, :organization_id])
      )
      # authorize?: false — the same roster read as the count above, narrowed
      # to the accounts without a factor.
      |> then(&Accounts.list_users!(query: &1, authorize?: false))

    deadlines =
      Enum.map(unenrolled, fn user ->
        deadline(user, roster_source(user, tier), policy)
      end)

    {grace, overdue} = Enum.split_with(deadlines, &(DateTime.compare(now, &1) == :lt))

    %{
      total: total,
      enrolled: total - length(unenrolled),
      in_grace: length(grace),
      overdue: length(overdue),
      earliest_deadline: if(grace == [], do: nil, else: Enum.min(grace, DateTime))
    }
  end

  defp roster_query(org_id, tier) do
    query =
      org_id
      |> Scoping.users_with_tier_query([tier])
      |> Ash.Query.filter(is_nil(anonymized_at))

    if KilnCMS.Demo.enabled?() do
      admin = RoleGrant.expression([:admin])
      Ash.Query.filter(query, ^admin)
    else
      query
    end
  end

  # The membership the roster matched on, when there is one; a platform
  # administrator's or a legacy account's tier is its own row's.
  defp roster_source(user, tier) do
    cond do
      RoleGrant.effective_role(user) == :admin -> {tier, :platform, user}
      match?([_ | _], user.org_memberships) -> {tier, :member, hd(user.org_memberships)}
      true -> {tier, :legacy, user}
    end
  end

  # Erased, or an account demo mode will not let change its credentials (it
  # could never enrol).
  defp exempt?(user) do
    not is_nil(Map.get(user, :anonymized_at)) or KilnCMS.Demo.locks_credentials?(user)
  end

  defp tier_source(user, org_id, opts) do
    Keyword.get_lazy(opts, :tier_source, fn -> Scoping.tier_source(user, org_id) end)
  end

  defp passkey?(user), do: Accounts.second_factors(user).passkeys > 0

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
end
