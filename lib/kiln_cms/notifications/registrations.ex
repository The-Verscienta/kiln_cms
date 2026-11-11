defmodule KilnCMS.Notifications.Registrations do
  @moduledoc """
  Telling a site's admins that someone is waiting for their approval (#2251).

  `announce/1` runs once an applicant has confirmed their address
  (`KilnCMS.Accounts.Changes.AnnouncePendingRegistration`): that is when a
  registration can be approved, so that is when an admin has something to do.
  `announce_org/1` is the same notice for one site, public for a path that
  queues an already-confirmed account (a site's own single sign-on), which
  calls it after its own commit.

  ## What an admin gets

  An in-app `:registration_pending` notification (the bell, `/editor/inbox`),
  linking to `/editor/registrations`, and an email to the same effect
  (`KilnCMS.Accounts.User.Senders.SendRegistrationPending`). Both are about
  the **site's queue**, not the applicant: the title is the site's name, and
  neither carries the applicant's address or name. The queue shows those to
  the people who may see them; a notice copied into an inbox or a mail
  provider is not one of those places.

  One unread notice per admin and site: the event collapses
  (`KilnCMS.Notifications.record_in_app_result/1`), so a wave of sign-ups is
  one row while the first is unread, and the email goes only with a new row —
  one mail per admin per batch, not one per applicant. Opening the queue
  marks it read (`KilnCMSWeb.RegistrationsLive`), and the next applicant
  after that is news again.

  `User.notify_on_registration` mutes the email only. The bell row is always
  written: the queue is work only an admin can do, and a muted admin should
  still see that it is waiting when they next open the console. The flag is
  one per account, so the settings page offers it to anyone who administers
  any site (`administers_any_site?/1`), and the email links to it.

  ## Who hears

  `recipient?/2`: an account whose tier on the site is admin **without** a
  temporary platform grant — a standing platform admin, or a member whose
  active membership there is admin — and that has not been erased. The roster
  is `KilnCMS.Accounts.Scoping.users_with_tier/2`, narrowed by this. A
  temporary platform admin is left out: it may not decide registrations
  (`StandingAdminOnly`), and a notice it cannot act on is noise.

  Best effort throughout, like every notifier: the confirmation has
  committed, so each site, and each admin within it, is tried on its own and
  a failure is logged and dropped.
  """
  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.RoleGrant
  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.Accounts.User.Senders.SendRegistrationPending
  alias KilnCMS.Notifications

  @event :registration_pending

  @doc "The notification event this module writes."
  @spec event() :: :registration_pending
  def event, do: @event

  @doc """
  Announce `user`'s pending registrations: every site where they wait gets
  `announce_org/1`. Returns `:ok`; never raises.
  """
  @spec announce(Accounts.User.t()) :: :ok
  def announce(%{id: user_id} = user) do
    # As the applicant: their own memberships, which the self-only read admits.
    case Accounts.list_memberships_for_user(user_id, actor: user, authorize_with: :error) do
      {:ok, memberships} ->
        memberships
        |> Enum.filter(&(&1.status == :pending))
        |> Enum.map(& &1.organization_id)
        |> Enum.uniq()
        |> Enum.each(&announce_org/1)

      {:error, error} ->
        Logger.error(
          "registration notice: could not read the applicant's memberships: " <>
            Exception.message(error)
        )
    end

    :ok
  rescue
    error ->
      Logger.error("registration notice not sent: #{Exception.message(error)}")
      :ok
  end

  @doc """
  Tell `org_id`'s admins that its registration queue has someone confirmed in
  it: an in-app notice each, and an email to each admin who gets a new notice
  and has not muted `notify_on_registration`. Returns `:ok`; never raises.
  """
  @spec announce_org(Ash.UUID.t()) :: :ok
  def announce_org(org_id) when is_binary(org_id) do
    case Accounts.get_organization(org_id, actor: Accounts.system(), authorize_with: :error) do
      {:ok, org} ->
        site = KilnCMS.Branding.for_org(org).site_name
        org_id |> recipients() |> Enum.each(&notify(&1, org, site))

      {:error, error} ->
        Logger.error(
          "registration notice for org #{org_id}: could not read the site: " <>
            Exception.message(error)
        )
    end

    :ok
  rescue
    error ->
      Logger.error("registration notice for org #{org_id} not sent: #{Exception.message(error)}")
      :ok
  end

  @doc """
  The accounts `announce_org/1` notifies on `org` — see the moduledoc.
  """
  @spec recipients(Accounts.Organization.t() | Ash.UUID.t() | nil) :: [Accounts.User.t()]
  def recipients(org) do
    org
    |> Scoping.users_with_tier([:admin])
    |> Enum.filter(&recipient?(&1, org))
  end

  @doc """
  Whether `user` hears about registrations on `org`: admin there by a standing
  tier — a platform admin, or an active admin membership — and not erased.
  """
  @spec recipient?(map() | nil, Accounts.Organization.t() | Ash.UUID.t() | nil) :: boolean()
  def recipient?(%{anonymized_at: nil} = user, org),
    do: Scoping.effective_tier(without_platform_grant(user), org) == :admin

  def recipient?(_user, _org), do: false

  @doc """
  Whether `user` hears about registrations on **any** site: a standing
  platform admin, or an active admin membership anywhere, and not erased.
  `notify_on_registration` is one flag across every site, so the settings
  page offers it to such an account whichever site it is opened on.
  """
  @spec administers_any_site?(map() | nil) :: boolean()
  def administers_any_site?(%{id: user_id, anonymized_at: nil} = user) do
    # `role` is the standing platform tier: a temporary grant never writes it.
    # The memberships are read as the user, which the self-only read admits.
    user.role == :admin or
      case Accounts.list_memberships_for_user(user_id, actor: user, authorize_with: :error) do
        {:ok, memberships} -> Enum.any?(memberships, &admin_membership?/1)
        {:error, _refused} -> false
      end
  end

  def administers_any_site?(_user), do: false

  # The same rule `Scoping` applies to a member: an active row, its tier with
  # the membership's own live grant.
  defp admin_membership?(%{status: :active} = membership),
    do: RoleGrant.effective_role(membership) == :admin

  defp admin_membership?(_membership), do: false

  # The user's own grant removed, so `effective_tier/2` decides on the standing
  # platform role, then on the membership (whose own grant still counts: a
  # site's temporary admin may decide that site's registrations).
  defp without_platform_grant(user),
    do: Map.merge(user, %{granted_role: nil, granted_role_expires_at: nil})

  defp notify(admin, org, site) do
    outcome =
      Notifications.record_in_app_result(%{
        user_id: admin.id,
        org_id: org.id,
        event: @event,
        content_type: "registration_queue",
        content_id: org.id,
        block_id: nil,
        title: site,
        excerpt: nil,
        actor_id: nil,
        actor_name: nil
      })

    if outcome == :recorded and admin.notify_on_registration and admin.email do
      SendRegistrationPending.deliver(admin, org)
    end

    :ok
  rescue
    error ->
      Logger.error(
        "registration notice for admin #{admin.id} not sent: #{Exception.message(error)}"
      )

      :ok
  end
end
