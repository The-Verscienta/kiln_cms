defmodule KilnCMS.Accounts.LegacyAffiliation do
  @moduledoc """
  The one definition of "carry a legacy account onto the default org" (#1649).

  An account with **no memberships at all** is *unaffiliated*:
  `KilnCMS.Accounts.Scoping` gives it its standing `User.role` on the default
  org. (Until 1.0 it also read the `User.audiences` column everywhere; that
  fallback was removed in #1543, and the column is what this module copies onto
  the membership, so a legacy account's audiences survive.) The moment it gains
  its first `KilnCMS.Accounts.OrgMembership` — on any org — it becomes
  *affiliated*, and an affiliated account holds nothing on a site it is not a
  member of. So a first membership written naively demotes a legacy editor:

    * a `:viewer` membership on the default org replaces its editor tier there;
    * any membership on another org leaves it `:foreign_org` on the default org,
      with no tier and no audiences.

  Every writer that may give an unaffiliated account its first membership calls
  `ensure_default_membership/2` **first**: `KilnCMS.Accounts.SiteAudiences` (the
  console's audience checkboxes, #1646) and `KilnCMS.Billing.Entitlements` (a
  paid membership, #1649). The post-deploy safety net
  (`KilnCMS.Accounts.LegacyAudiencesWorker`) calls it for every unaffiliated
  account still holding `User.audiences`. The membership it writes grants on the
  default org what the account held there before 1.0, so it is safe to write on its
  own, before whatever membership the caller came to create:

    * `role` is the **standing** `User.role`, never
      `RoleGrant.effective_role/1` — a live grant must not become permanent;
    * a live temporary role is copied onto the membership as a grant with the
      **same expiry**, because the member branch of `Scoping.effective_tier/2`
      reads the membership's grant, not the user's;
    * `audiences` is `User.audiences` unless the caller passes `:audiences`.

  Other scope axes (`editable_types`, `readable_types`, `field_grants`) are left
  empty on purpose: `Scoping` falls back from an empty membership axis to the
  user's own, so the account keeps exactly what it had.

  ## Idempotent, so a race cannot duplicate or demote

  Two writers can both see "no memberships" — two billing recomputes for the
  same user, or a recompute and a console edit. The insert is an upsert on the
  `(user_id, organization_id)` identity that updates **nothing** on conflict: the
  loser gets the winner's row back instead of a unique-violation error (which,
  inside a billing transition's transaction, would abort the whole transaction),
  and never overwrites a role or audiences someone set in between. The grant is
  copied only onto a row that has none yet.
  """

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.Accounts.RoleGrant

  @doc """
  Whether `memberships` — every membership `user` holds — leaves the account
  unaffiliated, i.e. whether its next membership must be preceded by
  `ensure_default_membership/2`.
  """
  @spec unaffiliated?([OrgMembership.t()]) :: boolean()
  def unaffiliated?(memberships) when is_list(memberships), do: memberships == []

  @doc """
  Give `user` its default-org membership, carrying its standing role, any live
  temporary role and its audiences. Returns the membership — the existing one if
  a concurrent writer got there first.

  `opts`:

    * `:audiences` — the membership's audiences (default: `user.audiences`);
    * every other option (`:actor`, `:authorize?`, …) is passed to each write, so
      `OrgMembership`'s policies decide who may make them.
  """
  @spec ensure_default_membership(map(), keyword()) ::
          {:ok, OrgMembership.t()} | {:error, term()}
  def ensure_default_membership(%{id: user_id} = user, opts \\ []) do
    {audiences, write_opts} = Keyword.pop(opts, :audiences)

    attrs = %{
      organization_id: Accounts.default_org_id(),
      user_id: user_id,
      role: user.role,
      audiences: list(audiences || Map.get(user, :audiences))
    }

    upsert = [upsert?: true, upsert_identity: :unique_membership, upsert_fields: []]

    with {:ok, membership} <-
           Accounts.create_org_membership(attrs, Keyword.merge(write_opts, upsert)) do
      carry_grant(user, membership, write_opts)
    end
  end

  # Onto a row with no grant of its own only: the winner of a race already
  # copied it, and a grant someone set on the membership is theirs to keep.
  defp carry_grant(user, membership, write_opts) do
    if is_nil(membership.granted_role) and RoleGrant.live?(user) and
         RoleGrant.elevation?(user.granted_role, membership.role) do
      Accounts.grant_membership_temporary_role(
        membership,
        %{
          granted_role: user.granted_role,
          granted_role_expires_at: user.granted_role_expires_at
        },
        write_opts
      )
    else
      {:ok, membership}
    end
  end

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []
end
