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

  **Only an `:active` membership grants anything** (#2251). A registration
  awaiting approval (`:pending`) or turned away (`:rejected`) is a membership
  row, so it still makes the account *affiliated* — `:none` on every other
  site, the default org included — but on its own site it resolves to no tier,
  no audiences, a `:denied` scope and an empty grant, exactly what a foreign
  org gets.
  """

  require Ash.Query

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.RoleGrant

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

  `subject` takes the same shapes as `effective_tier/2` — the changeset under
  authorization (how `Changes.EnforceFieldGrants` calls it), a raw org id, an
  `%Organization{}`, or nil for the default org — so a caller outside a write
  (e.g. `KilnCMS.CMS.Duplication`) can resolve the same grant.
  """
  @spec field_grant(
          map(),
          Ash.Query.t() | Ash.Changeset.t() | struct() | String.t() | nil,
          String.t() | nil
        ) :: [String.t()] | nil
  def field_grant(_actor, _subject, nil), do: nil

  def field_grant(actor, subject, type_name),
    do: resolve_grant(actor, subject, type_name, :field_grants)

  # Membership → role → user, per type key, for either grant map.
  defp resolve_grant(actor, subject, type_name, attribute) do
    case affiliation(actor, subject_org_id(subject)) do
      {:member, %{status: :active} = membership} ->
        grant_key(membership, type_name, attribute) ||
          grant_key(role_of(membership), type_name, attribute) ||
          grant_key(actor, type_name, attribute)

      :unaffiliated ->
        grant_key(actor, type_name, attribute)

      # A foreign org, or a registration not (yet) approved here.
      _none ->
        []
    end
  end

  @doc """
  The actor's effective per-custom-field READ restriction for `type_name`
  (#2281): the same shape and the same membership → role → user resolution as
  `field_grant/3`, over `field_read_grants`. `nil` means unrestricted, a list
  names the private custom fields that stay visible (`[]` hides all of them),
  and a foreign-org actor gets `[]`. See `KilnCMS.CMS.FieldAccess`.
  """
  @spec field_read_grant(
          map(),
          Ash.Query.t() | Ash.Changeset.t() | struct() | String.t() | nil,
          String.t() | nil
        ) :: [String.t()] | nil
  def field_read_grant(_actor, _subject, nil), do: nil

  def field_read_grant(actor, subject, type_name),
    do: resolve_grant(actor, subject, type_name, :field_read_grants)

  @doc """
  The consumer **audiences** the actor holds on the org the subject runs under
  (#337 Phase 2).

  The read axis, resolved per-org rather than globally:

    * a **member** gets their `KilnCMS.Accounts.OrgMembership.audiences` for that
      org — so paying on one site grants access on that site only;
    * a **foreign-org** actor (holds memberships, none here) gets `[]` —
      **fail-closed**, matching every other axis in this module. The org resolves
      from a client-controlled host, so falling back to the global column there
      would let a member of one site read another's gated content by switching
      hosts;
    * an **unaffiliated** actor (no memberships at all) gets `[]` too. Until 1.0
      it read the global `User.audiences` column instead; 0.12 deprecated that
      fallback and 1.0 removed it (#1543). `KilnCMS.Accounts.LegacyAudiencesWorker`
      moves any account still relying on it onto a default-org membership after
      each deploy, so an upgrade strands nobody.

  Audiences are granted only through a membership: billing
  (`KilnCMS.Billing.Entitlements`) and the console's audience checkboxes
  (`KilnCMS.Accounts.SiteAudiences`) both write the per-org value.

  Anonymous callers short-circuit to `[]` without a lookup — the delivery hot path
  never pays for this.
  """
  @spec audiences(map() | nil, Ash.Query.t() | Ash.Changeset.t() | struct() | String.t() | nil) ::
          [atom()]
  def audiences(nil, _subject), do: []

  def audiences(actor, subject) do
    case affiliation(actor, audience_org_id(subject)) do
      {:member, %{status: :active} = membership} -> list_of(membership, :audiences)
      # A registration awaiting approval reads nothing gated, whatever its row
      # holds (#2251).
      {:member, _not_active} -> []
      :unaffiliated -> []
      :foreign_org -> []
    end
  end

  # `audiences/2` is called from a policy FilterCheck, whose `subject` is the
  # query — but the web layer may hand a raw org id or an `%Organization{}`, the
  # same shapes `effective_tier/2` accepts.
  defp audience_org_id(%{__struct__: KilnCMS.Accounts.Organization, id: id}), do: id
  defp audience_org_id(org_id) when is_binary(org_id), do: org_id
  defp audience_org_id(subject), do: org_id(subject)

  defp list_of(source, key) do
    case Map.get(source, key) do
      list when is_list(list) -> list
      _other -> []
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
    * a user with **no memberships at all** keeps `User.role`, but only on the
      **default org** (pre-#336 single-org data): on any *other* org a
      membership-less account is `:none`, so a legacy global editor can't reach
      a second site by switching hosts.

  `subject` may be the query/changeset under authorization, a raw org id
  (what the web layer passes from `current_org`), an `%Organization{}`, or nil
  (default org).

  Every branch resolves **temporary tiers** (`KilnCMS.Accounts.RoleGrant`) through
  `RoleGrant.effective_role/1`, here, at the moment of the decision — on the user
  for the platform and legacy branches, on the membership for the member branch.
  A loaded `role` is always the standing tier, and a LiveView holds the actor it
  mounted with, so the grant's expiry has to be compared with the clock now
  rather than trusted from any earlier read.
  """
  @spec effective_tier(
          map() | nil,
          Ash.Query.t() | Ash.Changeset.t() | struct() | String.t() | nil
        ) :: :admin | :editor | :viewer | :none
  def effective_tier(actor, subject), do: elem(tier_source(actor, subject), 0)

  @typedoc "Which branch of `effective_tier/2` decided a tier."
  @type tier_source :: :platform | :member | :legacy | :none

  @typedoc "A tier and the row whose grant columns govern it — see `tier_source/2`."
  @type sourced_tier :: {:admin | :editor | :viewer | :none, tier_source(), map() | nil}

  @typedoc "One change ahead: at `at`, the tier becomes `tier`."
  @type tier_change :: {DateTime.t(), :admin | :editor | :viewer | :none}

  @doc """
  `effective_tier/2` together with **where it came from** — for a page that has
  to explain a tier, not only act on it (#2142).

  Returns `{tier, source, record}`:

    * `{:admin, :platform, user}` — a platform admin, standing or by a live
      grant on the user;
    * `{tier, :member, membership}` — the membership's tier on this org;
    * `{:none, :member, membership}` — a membership on this org that is not
      `:active` (a registration awaiting approval, or rejected, #2251): the row
      is the source, and it grants nothing;
    * `{tier, :legacy, user}` — a membership-less account on the default org,
      from `User.role`;
    * `{:none, :none, nil}` — no tier here (foreign org, a membership-less
      account off the default org, no actor).

  `record` is the row whose grant columns govern the tier. `effective_tier/2`
  IS `elem(tier_source(actor, subject), 0)`, so a page rendering from this
  cannot disagree with the decision it describes.
  """
  @spec tier_source(
          map() | nil,
          Ash.Query.t() | Ash.Changeset.t() | struct() | String.t() | nil
        ) :: sourced_tier()
  def tier_source(%{} = actor, subject) do
    decide(actor, fn ->
      org = subject_org_id(subject)
      {org, affiliation(actor, org)}
    end)
  end

  def tier_source(_actor, _subject), do: {:none, :none, nil}

  @doc """
  `tier_source/2` for a page that has just read the user's membership on
  `org_id` itself (`nil`: none there) — the team page, an account's sites.

  The same decision, fed the given row instead of the memoized lookup the
  policy checks share, so a page that re-reads after a write shows the tier the
  write left rather than one remembered from a few seconds before. Display only:
  no policy check calls it.
  """
  @spec tier_source_for_membership(map(), struct() | String.t() | nil, map() | nil) ::
          sourced_tier()
  def tier_source_for_membership(%{} = user, org, membership),
    do: decide(user, fn -> {subject_org_id(org), loaded_affiliation(user, membership)} end)

  @doc """
  The changes ahead in `effective_tier/2` as the live grants behind it expire —
  the "until Friday, then viewer" of a temporary tier (#2142). `[]` when nothing
  is due to change.

  Each grant that is live now (the user's, and the membership's on this org)
  expires at its own time; at each expiry the tier is decided again with every
  grant expired by then removed, and a change is listed only when the tier
  actually differs from the one before it. So a temporary platform admin whose
  membership here is standing admin has no change ahead, and one whose live
  membership grant outlasts the platform grant steps down through it.
  Display only — no decision consults it.
  """
  @spec tier_changes(
          map() | nil,
          Ash.Query.t() | Ash.Changeset.t() | struct() | String.t() | nil
        ) :: [tier_change()]
  def tier_changes(%{} = actor, subject) do
    org = subject_org_id(subject)
    changes(actor, org, affiliation(actor, org))
  end

  def tier_changes(_actor, _subject), do: []

  @doc "`tier_changes/2` from an already-read membership, as `tier_source_for_membership/3`."
  @spec tier_changes_for_membership(map(), struct() | String.t() | nil, map() | nil) ::
          [tier_change()]
  def tier_changes_for_membership(%{} = user, org, membership),
    do: changes(user, subject_org_id(org), loaded_affiliation(user, membership))

  # The one decision every entry point shares. `resolve` returns `{org_id,
  # affiliation}` and is a thunk so the platform branch — most policy checks'
  # hot path — pays neither the org resolution nor the membership lookup.
  defp decide(actor, resolve) do
    if RoleGrant.effective_role(actor) == :admin,
      do: {:admin, :platform, actor},
      else: member_tier(actor, resolve.())
  end

  defp member_tier(actor, {org, affiliation}) do
    case affiliation do
      {:member, %{status: :active} = membership} ->
        {RoleGrant.effective_role(membership), :member, membership}

      # A registration awaiting approval, or rejected (#2251): the row is the
      # source, and it grants nothing.
      {:member, membership} ->
        {:none, :member, membership}

      :unaffiliated ->
        legacy_tier(actor, org)

      :foreign_org ->
        {:none, :none, nil}
    end
  end

  defp loaded_affiliation(_user, %{} = membership), do: {:member, membership}

  # No membership on this org: whether the user holds one elsewhere decides
  # foreign-org vs legacy — asked now, not from the memo.
  defp loaded_affiliation(%{id: user_id}, nil) when is_binary(user_id),
    do: if(any_membership?(user_id), do: :foreign_org, else: :unaffiliated)

  defp loaded_affiliation(_user, nil), do: :unaffiliated

  defp changes(actor, org, affiliation) do
    membership =
      case affiliation do
        {:member, membership} -> membership
        _other -> nil
      end

    {current, _source, _record} = decide(actor, fn -> {org, affiliation} end)

    [actor, membership]
    |> Enum.filter(&(is_map(&1) and RoleGrant.live?(&1)))
    |> Enum.map(& &1.granted_role_expires_at)
    |> Enum.sort(DateTime)
    |> Enum.dedup_by(&DateTime.to_unix(&1, :microsecond))
    |> Enum.map_reduce(current, fn at, previous ->
      actor_then = expire_by(actor, at)

      affiliation_then =
        if membership, do: {:member, expire_by(membership, at)}, else: affiliation

      {tier, _source, _record} = decide(actor_then, fn -> {org, affiliation_then} end)
      {if(tier != previous, do: {at, tier}), tier}
    end)
    |> elem(0)
    |> Enum.reject(&is_nil/1)
  end

  # `record` as it will be at `at`: a grant expiring by then is gone.
  defp expire_by(record, at) do
    case Map.get(record, :granted_role_expires_at) do
      %DateTime{} = expires_at ->
        if DateTime.compare(expires_at, at) == :gt,
          do: record,
          else: Map.merge(record, %{granted_role: nil, granted_role_expires_at: nil})

      _none ->
        record
    end
  end

  @doc """
  The users whose `effective_tier/2` on `org` is one of `tiers` — its inverse,
  for "who on this site can …" rosters: the review-request recipients
  (`KilnCMS.Notifications`) and the task assignee picker, which must offer
  exactly the people `KilnCMS.CMS.Validations.AssigneeIsEditor` then accepts.

  The same three branches, as one query (so one row per user however many
  match):

    * **platform admins** (`User.role == :admin`), when `:admin` is asked for
      — a membership never demotes them, so the member branch leaves them out;
    * **members** whose membership `role` on `org` is one of `tiers`;
    * on the **default org** only, accounts with **no memberships at all**
      whose global `role` is one of `tiers` (pre-#336 single-org data).

  A system read: `User`'s and `OrgMembership`'s read policies are self-only,
  and a roster is by definition about other people. `org` takes the shapes
  `KilnCMS.Accounts.org_id/1` does — nil is the default org.
  """
  @spec users_with_tier(struct() | String.t() | nil, [:admin | :editor | :viewer]) :: [struct()]
  def users_with_tier(org, tiers) when is_list(tiers) do
    # authorize?: false — a roster over every account (who to notify, who may
    # review). A system grant on `Accounts.User` would be a standing read of
    # every account on the deployment — wider than this query (#1402).
    org |> users_with_tier_query(tiers) |> Ash.read!(authorize?: false)
  end

  @doc """
  `users_with_tier/2` as a query, not yet run, for a caller that narrows it
  further (the Security posture page's second-factor check, #2252). Reading it
  is the caller's system read to justify, as `users_with_tier/2` does.
  """
  @spec users_with_tier_query(struct() | String.t() | nil, [:admin | :editor | :viewer]) ::
          Ash.Query.t()
  def users_with_tier_query(org, tiers) when is_list(tiers) do
    org_id = Accounts.org_id(org)
    platform? = :admin in tiers
    legacy? = org_id == Accounts.default_org_id()

    # Every `role` test goes through `RoleGrant.expression/1`, which is
    # `effective_role/1` in SQL — a temporary admin belongs on the admin roster
    # while their grant is live and not a minute longer. The rows come back as
    # stored, so a caller that needs the tier a row matched on asks
    # `RoleGrant.effective_role/1`, not `user.role`.
    #
    # The `exists/2` clause resolves the same expression against the membership's
    # own columns, which are named identically for exactly this reason.
    admin_tier = RoleGrant.expression([:admin])
    wanted = RoleGrant.expression(tiers)

    Ash.Query.filter(
      Accounts.User,
      (^platform? and ^admin_tier) or
        (not (^admin_tier) and
           exists(
             org_memberships,
             organization_id == ^org_id and status == :active and ^wanted
           )) or
        (^legacy? and ^wanted and not exists(org_memberships, true))
    )
  end

  @doc """
  Every **platform admin**: an account whose `User.role` is `:admin`, standing
  or by a live temporary grant (`RoleGrant.expression/1`), that has not been
  erased. Who is told about a deployment-wide security event (#2245) and a
  reused API key: they are the people who can act on one.

  A system read, as `users_with_tier/2` is: a roster is about other people.
  """
  @spec platform_admins() :: [struct()]
  def platform_admins do
    admin = RoleGrant.expression([:admin])
    query = Ash.Query.filter(Accounts.User, ^admin and is_nil(anonymized_at))
    # authorize?: false — a roster of who to alert, never returned to a caller;
    # User's read policy is self-only, as for users_with_tier/2.
    Accounts.list_users!(authorize?: false, query: query)
  end

  @doc """
  The **member admins** of `org`: accounts holding an `:active` membership
  there whose effective tier on it is `:admin` (standing or by a live grant on
  the membership), and which are neither platform admins nor erased. The
  site's own administrators, and who a site-level security alert (#2245) goes
  to.

  Literal on purpose: a platform admin is admin on every site but is not
  listed here (they get the platform's alerts instead), and a site whose only
  admin is a platform admin has no member admins — `[]`, with no fallback.
  A legacy membership-less account is not listed either: it holds no
  membership to be a member admin by.

  `org` takes the shapes `KilnCMS.Accounts.org_id/1` does. A system read.
  """
  @spec site_member_admins(struct() | String.t() | nil) :: [struct()]
  def site_member_admins(org) do
    org_id = Accounts.org_id(org)
    admin = RoleGrant.expression([:admin])

    query =
      Ash.Query.filter(
        Accounts.User,
        is_nil(anonymized_at) and not (^admin) and
          exists(org_memberships, organization_id == ^org_id and status == :active and ^admin)
      )

    # authorize?: false — a roster of who to alert, never returned to a caller;
    # User's and OrgMembership's read policies are self-only.
    Accounts.list_users!(authorize?: false, query: query)
  end

  # A membership-less account's global role applies only on the default org.
  defp legacy_tier(actor, org) do
    if org == Accounts.default_org_id(),
      do: {RoleGrant.effective_role(actor) || :none, :legacy, actor},
      else: {:none, :none, nil}
  end

  @doc """
  The org id `subject` runs under — the same resolution `effective_tier/2`
  uses: a raw id, an `%Organization{}`, or a query/changeset's tenant, falling
  back to the default org. Public so a policy check that pairs the tier with a
  per-org setting (`KilnCMS.CMS.Checks.EditorMayPublish`) asks about the SAME
  org the tier was resolved on.
  """
  @spec subject_org_id(Ash.Query.t() | Ash.Changeset.t() | struct() | String.t() | nil) ::
          String.t()
  def subject_org_id(org_id) when is_binary(org_id), do: org_id
  def subject_org_id(%KilnCMS.Accounts.Organization{id: id}), do: id
  def subject_org_id(subject), do: org_id(subject)

  defp scope(actor, subject, axis) do
    case affiliation(actor, org_id(subject)) do
      {:member, %{status: :active} = membership} ->
        list_axis(membership, axis) || list_axis(role_of(membership), axis) ||
          list_axis(actor, axis) || []

      :unaffiliated ->
        list_axis(actor, axis) || []

      # A foreign org, or a registration not (yet) approved here (#2251).
      _none ->
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

  defp grant_key(nil, _type_name, _attribute), do: nil

  defp grant_key(source, type_name, attribute) do
    with grants when is_map(grants) <- Map.get(source, attribute),
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
  #   {:member, membership} — a membership row exists for this org, in any
  #                           status (the callers above grant only `:active`);
  #   :foreign_org          — the user holds memberships, none for this org;
  #   :unaffiliated         — the user holds no memberships at all (legacy).
  defp affiliation(%{id: user_id}, org_id) when is_binary(user_id) and is_binary(org_id) do
    memo({__MODULE__, user_id, org_id}, fn -> resolve_affiliation(user_id, org_id) end)
  end

  defp affiliation(_actor, _org_id), do: :unaffiliated

  defp resolve_affiliation(user_id, org_id) do
    # authorize?: false — this IS the authorization: the policy checks call it
    # to resolve the actor's tier, so it cannot itself be authorized without
    # recursing. It must also never be refused: a filtered membership read
    # would answer "no membership" and resolve to the legacy global role
    # instead of the per-site one.
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
    # authorize?: false — part of the tier resolution the policy checks call
    # (see `resolve_affiliation/2`), so it cannot be authorized without
    # recursing, and a refused read would demote a foreign-org member to
    # `:unaffiliated`.
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
