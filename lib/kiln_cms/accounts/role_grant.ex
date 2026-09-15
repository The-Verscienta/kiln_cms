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

  ## Where the rule is applied: at the decision

  `role` on a loaded record is always the **standing** tier — the column as
  stored. Nothing rewrites it on read. Every place that decides what someone may
  do asks `effective_role/1` instead, at the moment of deciding:
  `KilnCMS.Accounts.Checks.PlatformAdmin` (the platform resources' admin check),
  `KilnCMS.Accounts.Scoping.effective_tier/2` (every org-scoped tier check, the
  console nav) and `KilnCMSWeb.LiveUserAuth.platform_admin_user?/1`.

  An earlier version folded the grant into `role` on every read instead. It
  needed a second layer anyway — a LiveView holds the actor it mounted with, so a
  folded `role` outlived the grant that put it there — and the fold itself brought
  two write hazards (Ash drops a submitted `role` equal to the folded one; a read
  with an `after_action` hook cannot run atomically) that took a context flag, a
  validation and a special case for Ash's internal reads to contain.

  Deciding at the decision also fails in the safe direction. A site that reads
  `role` directly where it should ask `effective_role/1` merely ignores a live
  grant — the grantee sees less than they were given, and says so. The fold's
  failure was the opposite: a site that trusted a folded `role` kept honouring a
  grant after it expired.

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

  Takes a `User`, an `OrgMembership`, or any map carrying the three fields — a
  bare `%{role: :admin}` system actor included, which has no grant and so answers
  its `role`.
  """
  @spec effective_role(map() | nil) :: atom() | nil
  def effective_role(nil), do: nil

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
  The standing tier a write will leave behind: the submitted `role` when the
  action carries one, the record's own `role` otherwise.

  That distinction is what lets one submit set `role` and the grant together and
  be judged against the right baseline.
  """
  @spec standing_role(Ash.Changeset.t()) :: atom() | nil
  def standing_role(%Ash.Changeset{} = changeset) do
    case Ash.Changeset.fetch_change(changeset, :role) do
      {:ok, role} -> role
      :error -> Map.get(changeset.data, :role)
    end
  end

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
  `KilnCMS.Accounts.Scoping.users_with_tier/2`'s roster query.

  Written as a filter — "is the effective tier one of `tiers`" — rather than as
  a projection, because that is what the caller needs and because `if/3` over
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
end
