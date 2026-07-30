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

  `User.audiences` receives the cross-org **union**, because the content read
  policy reads `^actor(:audiences)` off that global column today. Each of the
  user's `KilnCMS.Accounts.OrgMembership` rows receives its own org's **exact**
  set, so a follow-up change can move the policy onto the per-org value without a
  data migration. Until that lands, a membership in one org does widen the global
  union — see `docs/memberships.md`.

  Every call runs `authorize?: false`: this is a system operation with no actor,
  and the actions it drives forbid actor-carrying callers outright.
  """
  require Logger

  alias KilnCMS.Accounts
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

      with {:ok, _user} <- write_user(user, before, desired),
           :ok <- write_org_memberships(user_id, managed, by_org) do
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
    Billing.MembershipTier
    |> Ash.Query.for_read(:all_for_entitlements, %{}, authorize?: false)
    |> Ash.read()
    |> case do
      {:ok, tiers} -> {:ok, Map.new(tiers, &{&1.id, &1.audience})}
      {:error, reason} -> {:error, reason}
    end
  end

  # Which audiences the user is entitled to, keyed by the org that granted them.
  # A tier whose audience has been dropped from `config :kiln_cms, :audiences` is
  # skipped with a warning rather than crashing the recompute: persisting it would
  # break every subsequent read of this user.
  defp entitled_by_org(user_id, audiences_by_tier) do
    Membership
    |> Ash.Query.for_read(:entitling_for_user, %{user_id: user_id}, authorize?: false)
    |> Ash.read()
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
      Accounts.sync_billing_audiences(user, %{audiences: desired}, authorize?: false)
    end
  end

  # Mirror each org's exact entitlement onto its `OrgMembership`, so the read axis
  # can move per-org later. Rows are created when missing: a reader who pays on a
  # site they have no membership row for still needs one to carry the audience.
  defp write_org_memberships(user_id, managed, by_org) do
    case Accounts.list_memberships_for_user(user_id, authorize?: false) do
      {:ok, memberships} ->
        Enum.each(memberships, &sync_existing(&1, managed, by_org))
        create_missing(user_id, memberships, by_org)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sync_existing(membership, managed, by_org) do
    entitled = Map.get(by_org, membership.organization_id, [])
    current = normalize(membership.audiences)
    desired = normalize(Enum.reject(current, &(&1 in managed)) ++ entitled)

    if current != desired do
      Accounts.update_org_membership(membership, %{audiences: desired}, authorize?: false)
    end
  end

  defp create_missing(user_id, memberships, by_org) do
    existing = MapSet.new(memberships, & &1.organization_id)

    by_org
    |> Enum.reject(fn {org_id, _audiences} -> MapSet.member?(existing, org_id) end)
    |> Enum.each(fn {org_id, audiences} ->
      Accounts.create_org_membership(
        %{
          organization_id: org_id,
          user_id: user_id,
          # A paying reader is a reader, not an author.
          role: :viewer,
          audiences: audiences
        },
        authorize?: false
      )
    end)
  end

  defp fetch_user(user_id) do
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
