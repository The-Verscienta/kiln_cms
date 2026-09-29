defmodule KilnCMS.Billing.Entitlements do
  @moduledoc """
  The single writer of billing-derived audiences.

  ## Declarative recompute, never add/remove

  A user's audience set is recomputed **from scratch** on every membership
  transition:

      granted   = audiences of every entitling membership (:active | :past_due | :comped)
      managed   = audiences claimed by ANY tier, in ANY org, active or not
      preserved = current -- managed          # admin-owned, untouched
      new       = preserved ++ granted

  Why not an add/remove primitive: `KilnCMS.Accounts.User.audiences` is a
  whole-array write, so two concurrent transitions doing read-modify-write would
  lose one another's change. A recompute is *idempotent* and last-writer-correct,
  which is exactly what at-least-once webhook delivery and out-of-order events
  demand — and it is the layer that actually makes "webhook replay cannot
  double-grant" true, rather than relying on dedupe alone.

  ## Division of authority

  For any audience some tier claims, **billing is the sole authority**. Audiences
  no tier claims are admin-owned (`KilnCMS.Accounts.User.manage_access`) and
  preserved verbatim.

  A consequence worth knowing: once an audience has *ever* been claimed by a tier,
  granting it by hand is transient — the next recompute will drop it. Comping is
  the supported lever (`KilnCMS.Billing.Membership`'s `:comped` status), and
  `manage_access` itself is untouched.

  ## Two columns, deliberately

  Each of the user's `KilnCMS.Accounts.OrgMembership` rows receives its own
  org's **exact** set — the value `KilnCMS.Accounts.Scoping.audiences/2` reads.
  `User.audiences` receives the cross-org **union**, which no access decision
  reads since 1.0 removed the membership-less fallback (#1543); it is kept as a
  record (the GDPR export reports it) and 2.0 may drop it — see
  `docs/memberships.md`.

  ## A legacy account's first membership

  A paid membership is a `:viewer` membership, but paying must never cost an
  account the tier it already holds (#1649). An account with **no memberships at
  all** reads its standing `User.role` on the default org; its first membership
  would make it *affiliated* and take that away wherever it is not a member. So
  before creating the first one, the recompute
  gives it a default-org membership carrying its standing role, any live
  temporary role and its audiences —
  `KilnCMS.Accounts.LegacyAffiliation.ensure_default_membership/2`, the same step
  the console takes. Every membership write here is an upsert on
  `(user_id, organization_id)`, so two recomputes racing for one user cannot
  duplicate a row or abort each other's transaction.

  ## Who it runs as

  The two billing reads — every tier's audience and the user's entitling
  memberships — run as `KilnCMS.Billing.system/0` (#1659) with
  `authorize_with: :error`. A refused read of either would otherwise come back
  as `[]`, and `[]` here means "entitled to nothing": the recompute would strip
  a paying member's audiences and commit that as the new truth. A refusal
  instead aborts the recompute, the membership transition rolls back with it,
  and Oban retries — the member keeps what they had.

  The writes to `KilnCMS.Accounts.User` and `KilnCMS.Accounts.OrgMembership`,
  and the reads that feed them, keep `authorize?: false`, each with its reason
  at the call site: `User.sync_billing_audiences` refuses any caller that
  carries an actor, and a system grant on `OrgMembership` would be a standing
  write over every account's role and audiences on every org — wider than the
  one user this recompute touches (the #1402 argument).
  """
  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.LegacyAffiliation
  alias KilnCMS.Billing
  alias KilnCMS.Billing.Membership
  alias KilnCMS.CMS.Audiences

  @doc """
  Recompute and persist `user_id`'s audiences from their memberships.

  Returns `{:ok, %{before: [atom], after: [atom], added: [atom], removed: [atom]}}`
  so callers can record the delta in the audit trail.
  """
  @spec recompute(Ash.UUID.t()) :: {:ok, map()} | {:error, term()}
  def recompute(user_id) do
    # Every read here propagates its error rather than defaulting to an empty
    # result. That matters: treating a failed read as "no memberships" would
    # silently REVOKE a paying member's access on a transient database error. An
    # aborted recompute rolls the transaction back and Oban retries; a
    # successful-looking one that revoked everything would not.
    with {:ok, user} <- fetch_user(user_id),
         # One tier read, reused for both "what does billing own" and "what did
         # this user buy", so the two cannot disagree mid-recompute.
         {:ok, audiences_by_tier} <- tier_audiences(),
         {:ok, by_org} <- entitled_by_org(user_id, audiences_by_tier) do
      before = normalize(user.audiences)
      managed = audiences_by_tier |> Map.values() |> normalize()
      granted = by_org |> Map.values() |> Enum.concat() |> normalize()

      # Anything no tier claims stays exactly as an admin left it.
      preserved = Enum.reject(before, &(&1 in managed))
      desired = normalize(preserved ++ granted)

      with :ok <- persist(user, before, desired, managed, by_org) do
        {:ok,
         %{
           before: before,
           after: desired,
           added: desired -- before,
           removed: before -- desired
         }}
      end
    end
  end

  @doc false
  # Every write of one recompute, all or nothing. Public only so a test can
  # hand it an entitlement map the database will refuse (a missing org) and
  # prove nothing half-applies; `recompute/1` is the only caller.
  #
  # A failed write used to be dropped — `create_missing/4` answered `:ok` to
  # its own error — so a paying reader could be left without the per-org
  # audience that `Scoping.audiences/2` actually reads, with `User.audiences`
  # already rewritten beside it. Now any failed write rolls back the others
  # and the recompute returns the error, so the membership transition around
  # it rolls back too and Oban retries (#1659). Inside that transition's
  # transaction this joins it; called on its own it is its own transaction.
  @spec persist(Ash.Resource.record(), [atom()], [atom()], [atom()], %{
          optional(Ash.UUID.t()) => [atom()]
        }) :: :ok | {:error, term()}
  def persist(user, before, desired, managed, by_org) do
    KilnCMS.Repo.transaction(fn ->
      with {:ok, _user} <- write_user(user, before, desired),
           :ok <- write_org_memberships(user, managed, by_org) do
        :ok
      else
        {:error, reason} -> KilnCMS.Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :ok} ->
        :ok

      {:error, reason} ->
        # Logged here, once, rather than at each write: a write that fails
        # inside the database rolls back by throwing straight to this
        # transaction, past any `{:error, _}` arm below it.
        Logger.error(
          "billing: entitlement recompute for user #{user.id} rolled back for a retry; " <>
            "could not write the org membership on org #{inspect(failed_org(reason))}: " <>
            inspect(reason)
        )

        {:error, reason}
    end
  end

  # The org whose membership write failed, when the error carries it.
  defp failed_org(%Ash.Changeset{resource: Accounts.OrgMembership} = changeset),
    do:
      Ash.Changeset.get_attribute(changeset, :organization_id) ||
        changeset.data.organization_id

  defp failed_org(%{changeset: %Ash.Changeset{} = changeset}), do: failed_org(changeset)
  defp failed_org(_reason), do: nil

  @doc """
  The audiences billing owns: every audience claimed by any tier on the instance.

  Includes tiers that are inactive — see `KilnCMS.Billing.MembershipTier`'s
  `:all_for_entitlements` read for why retiring a tier must not un-manage its
  audience.
  """
  @spec managed_audiences() :: [atom()]
  def managed_audiences do
    case tier_audiences() do
      {:ok, by_tier} -> by_tier |> Map.values() |> normalize()
      {:error, _reason} -> []
    end
  end

  # `tier_id => audience` for every tier on the instance.
  #
  # Read once and joined in memory rather than loading `:tier` off each
  # membership. That is not a micro-optimisation: `:entitling_for_user` is a
  # `multitenancy :bypass` read (the question is inherently cross-org), and a
  # `belongs_to` load off a bypassed read cannot resolve the tenant-scoped tier
  # under strict tenancy — it comes back unloaded, which would silently make every
  # membership look non-entitling and grant nothing at all.
  defp tier_audiences do
    # Tiers are public (`authorize_if always()`), so no grant is involved today;
    # it runs as the system actor so a later policy applies, and fails closed
    # like the membership read below.
    Billing.MembershipTier
    |> Ash.Query.for_read(:all_for_entitlements, %{}, actor: Billing.system())
    |> Ash.read(authorize_with: :error)
    |> case do
      {:ok, tiers} -> {:ok, Map.new(tiers, &{&1.id, &1.audience})}
      {:error, reason} -> {:error, reason}
    end
  end

  # Which audiences the user is entitled to, keyed by the org that granted them.
  # A tier whose audience has been dropped from `config :kiln_cms, :audiences` is
  # skipped with a warning rather than crashing the recompute: persisting it would
  # break every subsequent read of this user.
  #
  # FAIL CLOSED (#1659): `Membership`'s read policy admits the billing system
  # actor, and a caller it does not admit is FILTERED to `[]` — which this
  # function would report as "entitled to nothing", revoking every paid
  # audience. `authorize_with: :error` turns that into an error instead.
  defp entitled_by_org(user_id, audiences_by_tier) do
    Membership
    |> Ash.Query.for_read(:entitling_for_user, %{user_id: user_id}, actor: Billing.system())
    |> Ash.read(authorize_with: :error)
    |> case do
      {:ok, memberships} ->
        {:ok,
         memberships
         |> Enum.flat_map(&resolve(&1, audiences_by_tier))
         |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
         |> Map.new(fn {org_id, audiences} -> {org_id, normalize(audiences)} end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve(membership, audiences_by_tier) do
    case Map.get(audiences_by_tier, membership.tier_id) do
      nil ->
        # The FK is `on_delete: :restrict`, so this should be unreachable.
        Logger.warning(
          "billing: membership #{membership.id} references a missing tier; ignoring."
        )

        []

      audience ->
        if Audiences.valid?(audience) do
          [{membership.org_id, audience}]
        else
          Logger.warning(
            "billing: membership #{membership.id} grants unconfigured audience " <>
              "#{inspect(audience)}; ignoring. Restore it in config :kiln_cms, :audiences " <>
              "or retire the tier."
          )

          []
        end
    end
  end

  defp write_user(user, before, desired) do
    if before == normalize(desired) do
      {:ok, user}
    else
      # authorize?: false — `User.sync_billing_audiences` is `forbid_if always()`
      # and its change module refuses any actor-carrying call (a system actor
      # included), so no authorized path can grant an audience; this recompute
      # is the one writer.
      Accounts.sync_billing_audiences(user, %{audiences: desired}, authorize?: false)
    end
  end

  # Mirror each org's exact entitlement onto its `OrgMembership`, so the read axis
  # can move per-org later. Rows are created when missing: a reader who pays on a
  # site they have no membership row for still needs one to carry the audience.
  defp write_org_memberships(user, managed, by_org) do
    # authorize?: false — `OrgMembership` reads are self-only, and a system
    # grant would be a standing read of every account's memberships (#1402).
    # A bypass cannot be refused, so this cannot come back `[]` for want of a
    # grant — `[]` here really means "no memberships" (the legacy branch below).
    with {:ok, memberships} <- Accounts.list_memberships_for_user(user.id, authorize?: false),
         {:ok, memberships} <- affiliate_legacy(user, memberships, by_org),
         :ok <- each_ok(memberships, &sync_existing(&1, managed, by_org)) do
      create_missing(user.id, memberships, managed, by_org)
    end
  end

  # Stops at the first failed write and returns it. The transaction in
  # `persist/5` undoes the ones before it.
  defp each_ok(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # A paying reader must never lose authoring access by paying (#1649). An
  # account with no memberships at all holds its standing role on the default
  # org; its first membership would make it affiliated — a `:viewer` on the
  # default org, or `:foreign_org` there with no tier. So before creating one,
  # carry it onto the default org first, with its `User.audiences` (what it held
  # before 1.0 removed the fallback, #1543); `sync_existing/3` then settles the
  # billing-managed part of that set like any other membership's, so what
  # survives there is its admin-owned audiences plus what it bought on the
  # default org.
  defp affiliate_legacy(user, memberships, by_org) do
    if LegacyAffiliation.unaffiliated?(memberships) and map_size(by_org) > 0 do
      # authorize?: false — the same system write as every other one in this
      # module (see the moduledoc), and it grants on the default org what the
      # account held there before it had a membership.
      with {:ok, membership} <-
             LegacyAffiliation.ensure_default_membership(user, authorize?: false),
           do: {:ok, [membership]}
    else
      {:ok, memberships}
    end
  end

  defp sync_existing(membership, managed, by_org) do
    entitled = Map.get(by_org, membership.organization_id, [])
    current = normalize(membership.audiences)
    desired = normalize(Enum.reject(current, &(&1 in managed)) ++ entitled)

    if current != desired do
      # authorize?: false — an `OrgMembership` write is an org admin's; a system
      # grant would be a standing write over every account's role and audiences
      # on every org (#1402). Only the audiences column is written, and only the
      # billing-managed part of it changes.
      case Accounts.update_org_membership(membership, %{audiences: desired}, authorize?: false) do
        {:ok, _membership} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  # An upsert that changes nothing on conflict: a concurrent recompute for the
  # same user may have created the row since `memberships` was read, and the
  # unique violation a plain insert would hit aborts the whole transition's
  # transaction. The row comes back either way (`{:ok, _}`, not an error) and is
  # synced like an existing one. Any OTHER failure is an error: the reader paid
  # on this org and would be left without its audience.
  defp create_missing(user_id, memberships, managed, by_org) do
    existing = MapSet.new(memberships, & &1.organization_id)

    by_org
    |> Enum.reject(fn {org_id, _audiences} -> MapSet.member?(existing, org_id) end)
    |> each_ok(fn {org_id, audiences} ->
      # authorize?: false — same reason as `sync_existing/3`: always a
      # `:viewer` row for `user_id`, and an upsert that changes nothing on
      # conflict, so it can never overwrite a role.
      case Accounts.create_org_membership(
             %{
               organization_id: org_id,
               user_id: user_id,
               # A paying reader is a reader, not an author.
               role: :viewer,
               audiences: audiences
             },
             authorize?: false,
             upsert?: true,
             upsert_identity: :unique_membership,
             upsert_fields: []
           ) do
        {:ok, membership} -> sync_existing(membership, managed, by_org)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp fetch_user(user_id) do
    # authorize?: false — `User` reads are self-only, and a system grant would be
    # a standing read of every account on the deployment (#1402). A bypass
    # cannot be refused, so `nil` really is "no such user" (and aborts).
    case Accounts.get_user(user_id, authorize?: false, not_found_error?: false) do
      {:ok, nil} -> {:error, :user_not_found}
      {:ok, user} -> {:ok, user}
      {:error, reason} -> {:error, reason}
    end
  end

  # Sorted + deduped, so equality comparisons are meaningful and stored order is
  # stable across recomputes.
  defp normalize(audiences) when is_list(audiences),
    do: audiences |> Enum.uniq() |> Enum.sort()

  defp normalize(_audiences), do: []
end
