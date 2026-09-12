defmodule KilnCMS.Accounts.RoleGrant do
  @moduledoc """
  Time-boxed capability tiers — "make this person an admin until Friday".

  A grant is two columns, carried identically by `KilnCMS.Accounts.User` (the
  platform tier) and `KilnCMS.Accounts.OrgMembership` (the per-site tier):

    * `granted_role` — the tier that applies *while the grant is live*;
    * `granted_role_expires_at` — when it stops applying.

  ## The permanent tier is never overwritten

  The obvious modelling — write the elevated tier into `role` and remember what
  to put back — needs the revert to actually happen, which makes a background
  sweep load-bearing for authorization: miss it, and a 48-hour admin is an
  admin forever. It also loses the baseline if the "put back" value is ever
  written wrong.

  So `role` keeps the person's standing tier for the whole life of the grant and
  `granted_role` shadows it. Expiry is then not an event at all — it is a
  comparison — and the worst a failed sweep can do is leave two dead columns on
  a row that already authorizes correctly. `effective_role/1` is the single
  answer, and `expression/1` is the same rule in SQL.

  ## Where the rule is applied

  `role` on an **actor struct** is what the policies read
  (`actor_attribute_equals(:role, :admin)` on a dozen resources,
  `KilnCMS.Accounts.Scoping.effective_tier/2`,
  `KilnCMSWeb.LiveUserAuth.platform_admin?/1`). Rather than teach each of those
  about the grant — a list to forget to add to, failing open —
  `KilnCMS.Accounts.Preparations.FoldRoleGrant` folds `effective_role/1` into
  the `role` field of every record both resources return. Every actor in the
  system is loaded through a read, so by the time a grant is a millisecond past
  its expiry the struct handed to Ash already says the standing tier.

  The pre-fold value stays reachable as `:standing_role` metadata, which is what
  the admin console shows beside the countdown — see `standing_role/1`.

  ## Elevation only

  A grant must name a *higher* tier than the row's own (`viewer < editor <
  admin`). A "temporary demotion" is a demotion: it should be written to `role`,
  where it holds until someone changes it back, rather than expiring quietly
  into restored access nobody re-approved.
  """

  require Ash.Expr

  @tiers [:viewer, :editor, :admin]

  # Ranked low → high, so "is this an elevation" is one comparison. The order is
  # the RBAC tier order the whole codebase assumes (see the `role` constraints
  # on `User` / `OrgMembership`).
  @rank @tiers |> Enum.with_index() |> Map.new()

  @doc "The capability tiers, ranked low to high."
  @spec tiers() :: [atom()]
  def tiers, do: @tiers

  @doc """
  The tier that applies to `record` right now: `granted_role` while the grant is
  live, the row's own `role` otherwise.

  Takes a `User`, an `OrgMembership`, or any map carrying the three fields, so
  the preparation and the console share one answer.
  """
  @spec effective_role(map()) :: atom() | nil
  def effective_role(record) do
    if live?(record), do: Map.get(record, :granted_role), else: Map.get(record, :role)
  end

  @doc """
  Whether `record` carries a grant that has not expired.

  Both fields must be concrete values: a record read with a narrowed `select`
  carries `%Ash.NotLoaded{}` there and is answered `false` — the standing tier,
  never the elevated one, is the safe thing to assume from missing data.
  """
  @spec live?(map()) :: boolean()
  def live?(record) do
    with role when role in @tiers <- Map.get(record, :granted_role),
         %DateTime{} = expires_at <- Map.get(record, :granted_role_expires_at) do
      DateTime.after?(expires_at, DateTime.utc_now())
    else
      _ -> false
    end
  end

  @doc """
  The standing tier behind a folded record — the value `role` held before
  `KilnCMS.Accounts.Preparations.FoldRoleGrant` replaced it, or `role` itself on
  a record that carried no live grant.

  Given a changeset, answers the tier the write is *about to* leave behind: the
  submitted `role` when the action carries one, the record's standing tier
  otherwise. That distinction is what lets one submit set `role` and the grant
  together and be judged against the right baseline.
  """
  @spec standing_role(Ash.Changeset.t() | map()) :: atom() | nil
  def standing_role(%Ash.Changeset{} = changeset) do
    case Ash.Changeset.fetch_change(changeset, :role) do
      {:ok, role} -> role
      :error -> standing_role(changeset.data)
    end
  end

  def standing_role(%{__metadata__: %{standing_role: role}}) when role in @tiers, do: role
  def standing_role(record), do: Map.get(record, :role)

  @doc """
  Whether `record` came back from a read that folded a live grant into `role`.

  A folded record is the wrong base for a write and wrong in a silent direction
  — see `KilnCMS.Accounts.Validations.UnfoldedRecord`, which refuses one.
  """
  @spec folded?(map()) :: boolean()
  def folded?(%{__metadata__: %{standing_role: role}}) when role in @tiers, do: true
  def folded?(_record), do: false

  @doc """
  Read options that suppress the fold — how a caller that is about to *write* a
  role, or wants to show both tiers, asks for the row as stored.

  A function rather than a documented literal so there is one spelling of the
  context key: a typo'd one would fold silently, which is the failure this exists
  to avoid. `KilnCMS.Accounts.Preparations.FoldRoleGrant` reads it.

      Accounts.get_user(id, [actor: admin] ++ RoleGrant.unfolded())
  """
  @spec unfolded() :: keyword()
  def unfolded, do: [context: %{fold_role_grant?: false}]

  @doc false
  # The inverse, for the preparation: whether this query wants the fold. Defaults
  # to folding, so a read that says nothing gets the enforcing behaviour.
  #
  # Ash's own `internal?` reads never fold. Those are the ones Ash runs *in
  # support of a write* — the atomic-upgrade re-read, relationship management —
  # and for them the fold is not merely unnecessary but wrong, for the reason
  # `unfolded/0` exists: a row about to be written must be seen as stored. It also
  # keeps the hook off those queries entirely, which matters because a read
  # carrying an `after_action` hook cannot be run as a single atomic statement, so
  # folding there would quietly downgrade every `require_atomic?` update on these
  # two resources to the stream strategy.
  @spec fold?(Ash.Query.t()) :: boolean()
  def fold?(%{context: %{fold_role_grant?: false}}), do: false
  def fold?(%{context: %{private: %{internal?: true}}}), do: false
  def fold?(_query), do: true

  @doc """
  Whether `granted` outranks `standing` — the elevation rule a grant must
  satisfy. `nil` on either side is not an elevation.
  """
  @spec elevation?(atom() | nil, atom() | nil) :: boolean()
  def elevation?(granted, standing) when granted in @tiers and standing in @tiers,
    do: @rank[granted] > @rank[standing]

  def elevation?(_granted, _standing), do: false

  @doc """
  `effective_role/1` as an Ash expression over the grant columns, for the one
  place the question has to be asked of rows that were never loaded:
  `KilnCMS.Accounts.Scoping.users_with_tier/2`'s roster query, and the AshOban
  triggers' `where`.

  Written as a filter — "is the effective tier one of `tiers`" — rather than as
  a projection, because that is what both callers need and because `if/3` over
  two enum columns reads far worse in SQL than the two-branch disjunction does.
  Splices into a larger filter with `^`, including inside an `exists/2` over
  `org_memberships` (whose columns are named identically, deliberately).
  """
  @spec expression([atom()]) :: Ash.Expr.t()
  def expression(tiers) when is_list(tiers) do
    # The two branches of `effective_role/1`, in the same order: no live grant →
    # the standing `role` decides; a live grant → `granted_role` does. An
    # expiry-less `granted_role` (which the write-time validation refuses) counts
    # as no grant, so a row that somehow holds one still authorizes as its
    # standing tier.
    Ash.Expr.expr(
      ((is_nil(granted_role) or is_nil(granted_role_expires_at) or
          granted_role_expires_at <= now()) and role in ^tiers) or
        (not is_nil(granted_role) and granted_role_expires_at > now() and
           granted_role in ^tiers)
    )
  end

  @doc """
  The attributes that make up a grant, in the order the console's form submits
  them. Named here so the resources, the validation and the console cannot drift
  on the spelling.
  """
  @spec fields() :: [atom()]
  def fields, do: [:granted_role, :granted_role_expires_at]
end
