defmodule KilnCMS.Accounts.SiteAudiences do
  @moduledoc """
  An account's consumer audiences on **one site**, as an admin edits them from
  `/editor/accounts` (#1646).

  What a reader may read is decided per organization by
  `KilnCMS.Accounts.Scoping.audiences/2`: a member of the site reads through that
  `KilnCMS.Accounts.OrgMembership`'s `audiences`, an account that is a member
  only of other sites reads nothing gated here, and an account with no
  memberships at all falls back to the global `User.audiences` column — the
  fallback 0.12 deprecates and 1.0 removes (#1538, #1543). The console used to
  write only that global column, which meant its checkboxes did nothing for any
  account that had a membership. This module writes the column the policy reads.

  ## An account with no membership on the site

  The first edit creates one, rather than writing the deprecated column. The
  membership's standing role is the tier the account already holds on that site,
  so gaining a membership changes what it may *read*, never what it may *author*:

    * an account with **no memberships anywhere**, on the **default org**, keeps
      its standing `User.role` (what `Scoping.effective_tier/2` gives it there);
    * anywhere else the account holds no tier (`:none`), and the membership is
      `:viewer`, the least a membership can carry.

  A live temporary role on a membership-less account is copied onto the new
  default-org membership with its expiry, because the member branch of
  `Scoping.effective_tier/2` reads the membership's grant, not the user's.

  **A membership-less account edited from another site** needs one more step. Its
  first membership anywhere turns it from *unaffiliated* into *affiliated*, and an
  affiliated account holds nothing on a site it is not a member of — so a legacy
  editor given a membership on site B would stop being an editor on the default
  site. Before creating the membership here, this carries the account onto the
  default org exactly as `mix kiln.deprecations --migrate-audiences` does: a
  default-org membership with its standing role and its current `User.audiences`.
  That write is created first and on its own, and it grants on the default org
  exactly what the fallback grants there today, so if the second write fails
  nothing is lost.

  What does change, on purpose: once an account holds any membership, the global
  column stops applying on the sites it is not a member of. That is the
  fail-closed rule every scope axis follows.

  Every write goes through the membership's own actions as the caller's actor, so
  `OrgMembership`'s policies decide who may make it (platform admins today).
  """

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.RoleGrant
  alias KilnCMS.CMS.Audiences

  @typedoc """
  Where the account's audiences on a site come from — the three branches of
  `KilnCMS.Accounts.Scoping.audiences/2`.
  """
  @type source :: :membership | :legacy | :none

  @doc """
  The audiences `user` reads on `org_id`, and which branch they come from, given
  the user's memberships (every site).

  Answers what `KilnCMS.Accounts.Scoping.audiences/2` answers, from rows the
  caller already holds and without its per-process memo, so a page re-rendering
  straight after a save shows the save.
  """
  @spec for_site(map(), [map()], String.t()) :: {source(), [atom()]}
  def for_site(user, memberships, org_id) when is_list(memberships) do
    case Enum.find(memberships, &(&1.organization_id == org_id)) do
      %{} = membership -> {:membership, list(membership.audiences)}
      nil when memberships == [] -> {:legacy, list(Map.get(user, :audiences))}
      nil -> {:none, []}
    end
  end

  @doc """
  Set `user`'s audiences on `org_id` to exactly `audiences`, on the membership.

  Creates the membership when there is none (see the moduledoc). `opts` must
  carry the `:actor` the writes authorize as. Returns `{:ok, :updated}` or
  `{:ok, :created}`.
  """
  @spec set(map(), String.t(), [atom()], keyword()) ::
          {:ok, :updated | :created} | {:error, term()}
  def set(%{id: user_id} = user, org_id, audiences, opts) when is_binary(org_id) do
    actor = Keyword.fetch!(opts, :actor)
    audiences = normalize(audiences)

    with {:ok, memberships} <- Accounts.list_memberships_for_user(user_id, actor: actor) do
      case Enum.find(memberships, &(&1.organization_id == org_id)) do
        %{} = membership -> update(membership, audiences, actor)
        nil -> create(user, org_id, audiences, memberships == [], actor)
      end
    end
  end

  defp update(membership, audiences, actor) do
    with {:ok, _membership} <-
           Accounts.update_org_membership(membership, %{audiences: audiences}, actor: actor),
         do: {:ok, :updated}
  end

  # A membership-less account on the default org: its standing role and any live
  # grant move onto the membership, so its tier there is what it was.
  defp create(user, org_id, audiences, true = _legacy?, actor) do
    default_org_id = Accounts.default_org_id()

    if org_id == default_org_id do
      with {:ok, _membership} <- create_carrying_tier(user, org_id, audiences, actor),
           do: {:ok, :created}
    else
      # Carry the account onto the default org first — see "A membership-less
      # account edited from another site" in the moduledoc.
      with {:ok, _carried} <-
             create_carrying_tier(user, default_org_id, list(user.audiences), actor),
           {:ok, _membership} <- create_viewer(user, org_id, audiences, actor),
           do: {:ok, :created}
    end
  end

  # Already a member elsewhere: it holds no tier here, so the least one.
  defp create(user, org_id, audiences, false = _legacy?, actor) do
    with {:ok, _membership} <- create_viewer(user, org_id, audiences, actor),
         do: {:ok, :created}
  end

  defp create_viewer(user, org_id, audiences, actor) do
    Accounts.create_org_membership(
      %{organization_id: org_id, user_id: user.id, role: :viewer, audiences: audiences},
      actor: actor
    )
  end

  # The STANDING role, never `RoleGrant.effective_role/1`: a live grant becomes a
  # grant on the membership with the same expiry, not a permanent tier.
  defp create_carrying_tier(user, org_id, audiences, actor) do
    with {:ok, membership} <-
           Accounts.create_org_membership(
             %{organization_id: org_id, user_id: user.id, role: user.role, audiences: audiences},
             actor: actor
           ) do
      carry_grant(user, membership, actor)
    end
  end

  defp carry_grant(user, membership, actor) do
    if RoleGrant.live?(user) and RoleGrant.elevation?(user.granted_role, membership.role) do
      Accounts.grant_membership_temporary_role(
        membership,
        %{
          granted_role: user.granted_role,
          granted_role_expires_at: user.granted_role_expires_at
        },
        actor: actor
      )
    else
      {:ok, membership}
    end
  end

  # Only configured audiences, each once, in a stable order — the attribute's
  # constraint would refuse anything else, and a stable order keeps "nothing
  # changed" an equal write.
  defp normalize(audiences) do
    known = Audiences.all()

    audiences
    |> list()
    |> Enum.filter(&(&1 in known))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []
end
