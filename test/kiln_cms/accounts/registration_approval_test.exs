defmodule KilnCMS.Accounts.RegistrationApprovalTest do
  @moduledoc """
  Registration approval (#2251), at the domain: the site setting, what a
  self-registration writes, who may list and decide the queue, the decisions
  and their races, and the paths that must not queue.

  What a pending account may then *do* is `RegistrationScopingTest`; the
  console and the HTTP surfaces are `KilnCMSWeb.RegistrationApprovalTest`.

  `async: false`: the race cases hold a transaction open in one process while
  another waits on the row, which needs the sandbox's shared mode.
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.InvitationRefused
  alias KilnCMS.Accounts.Errors.RegistrationRefused
  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.Accounts.RegistrationPolicy
  alias KilnCMS.Accounts.Registrations
  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.CMS
  alias KilnCMS.Security
  alias KilnCMS.SystemActor
  alias KilnCMS.Test.Latch

  @moduletag :capture_log

  @password "registration-password-123"

  defp uniq, do: System.unique_integer([:positive])
  defp address(tag \\ "reg"), do: "#{tag}-#{uniq()}@example.com"

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: address(to_string(role)),
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp member!(user, org_id, role, attrs \\ %{}) do
    Ash.Seed.seed!(
      OrgMembership,
      Map.merge(%{user_id: user.id, organization_id: org_id, role: role}, attrs)
    )
  end

  # An applicant on `org_id`: an account and a `:pending` row, as a queued
  # registration leaves them. `confirmed?: false` for one that has not clicked.
  defp applicant(org_id, opts \\ []) do
    confirmed_at = if Keyword.get(opts, :confirmed?, true), do: DateTime.utc_now()
    user = user(:viewer, %{confirmed_at: confirmed_at})
    {user, member!(user, org_id, :viewer, %{status: :pending})}
  end

  defp require_approval!(org_id, on? \\ true) do
    CMS.save_site_registration!(%{approval_required: on?},
      actor: user(:admin),
      tenant: org_id
    )
  end

  defp register(opts \\ []) do
    email = Keyword.get(opts, :email, address())

    result =
      AshAuthentication.Strategy.action(
        AshAuthentication.Info.strategy!(User, :password),
        :register,
        %{"email" => email, "password" => @password, "password_confirmation" => @password},
        Keyword.delete(opts, :email)
      )

    {email, result}
  end

  defp memberships(user_id),
    do: Accounts.list_memberships_for_user!(user_id, authorize?: false)

  defp reload(membership),
    do:
      Accounts.get_org_membership!(membership.user_id, membership.organization_id,
        authorize?: false
      )

  defp events(org_id, type) do
    Security.list_events!(actor: user(:admin), tenant: org_id, page: [limit: 200])
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == type))
  end

  defp users_with(email),
    do: Accounts.list_users!(authorize?: false) |> Enum.filter(&(to_string(&1.email) == email))

  describe "the site setting" do
    test "a site with no row needs no approval; a saved row says what it says" do
      site = org("setting")
      assert RegistrationPolicy.approval_required(site) == {:ok, false}

      require_approval!(site.id)
      assert RegistrationPolicy.approval_required(site) == {:ok, true}

      require_approval!(site.id, false)
      assert RegistrationPolicy.approval_required(site.id) == {:ok, false}
    end

    test "settings/1 reads every switch, independently, all off (keep) with no row" do
      site = org("settings-both")

      assert RegistrationPolicy.settings(site) ==
               {:ok,
                %{
                  approval_required: false,
                  approval_for_site_sso: false,
                  rejected_accounts: :keep
                }}

      CMS.save_site_registration!(%{approval_for_site_sso: true},
        actor: user(:admin),
        tenant: site.id
      )

      assert RegistrationPolicy.settings(site.id) ==
               {:ok,
                %{approval_required: false, approval_for_site_sso: true, rejected_accounts: :keep}}

      CMS.save_site_registration!(%{rejected_accounts: :erase_unconfirmed},
        actor: user(:admin),
        tenant: site.id
      )

      assert {:ok, %{rejected_accounts: :erase_unconfirmed}} =
               RegistrationPolicy.settings(site.id)

      assert RegistrationPolicy.approval_required(site) == {:ok, false}

      assert KilnCMS.OrgSettings.with_actor(nil, fn -> RegistrationPolicy.settings(site) end) ==
               {:error, :unavailable}
    end

    test "an unreadable row is an error, never a no" do
      site = org("unreadable")
      require_approval!(site.id, false)

      assert KilnCMS.OrgSettings.with_actor(nil, fn ->
               RegistrationPolicy.approval_required(site)
             end) == {:error, :unavailable}

      # A system actor of another subsystem is refused the read too.
      assert KilnCMS.OrgSettings.with_actor(SystemActor.new(:billing), fn ->
               RegistrationPolicy.approval_required(site)
             end) == {:error, :unavailable}
    end

    test "only an admin of the site may save it" do
      site = org("save")
      editor = user(:viewer)
      member!(editor, site.id, :editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_registration(%{approval_required: true},
                 actor: editor,
                 tenant: site.id
               )

      site_admin = user(:viewer)
      member!(site_admin, site.id, :admin)

      assert {:ok, %{approval_required: true}} =
               CMS.save_site_registration(%{approval_required: true},
                 actor: site_admin,
                 tenant: site.id
               )

      # The single sign-on switch is the same row, so the same rule.
      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_registration(%{approval_for_site_sso: true},
                 actor: editor,
                 tenant: site.id
               )
    end
  end

  describe "registering with a password" do
    test "with approval off, nothing is queued and the account is what it always was" do
      {email, result} = register()
      assert {:ok, user} = result

      assert memberships(user.id) == []
      # Membership-less: a viewer on the default org, as before #2251.
      assert Scoping.effective_tier(user, nil) == :viewer
      assert [_] = users_with(email)
    end

    test "on the default host, approval on: a pending viewer row on the default org" do
      org_id = Accounts.default_org_id()
      require_approval!(org_id)

      {_email, result} = register()
      assert {:ok, user} = result

      assert [
               %{
                 organization_id: ^org_id,
                 status: :pending,
                 role: :viewer,
                 audiences: [],
                 created_account: true
               }
             ] = memberships(user.id)

      assert Scoping.effective_tier(user, nil) == :none

      assert [event] =
               Enum.filter(events(org_id, :registration_queued), &(&1.target_id == user.id))

      assert event.metadata == %{"method" => "password"}
      assert event.actor_id == nil
    end

    test "on a tenant host: the row is on the host's site, and nowhere else" do
      site = org("tenant-host")
      require_approval!(site.id)

      {_email, result} = register(tenant: site)
      assert {:ok, user} = result

      site_id = site.id
      assert [%{organization_id: ^site_id, status: :pending}] = memberships(user.id)
      assert Scoping.effective_tier(user, site) == :none
      # Affiliated now, so nothing on the default org either.
      assert Scoping.effective_tier(user, nil) == :none
    end

    test "an open site's host cannot route around the default org's approval: queued there" do
      default_id = Accounts.default_org_id()
      require_approval!(default_id)
      site = org("open-site")

      {_email, result} = register(tenant: site)
      assert {:ok, user} = result

      assert [%{organization_id: ^default_id, status: :pending}] = memberships(user.id)
      # Not the legacy viewer a membership-less account would be.
      assert Scoping.effective_tier(user, nil) == :none
      assert Scoping.audiences(user, default_id) == []
      assert Scoping.effective_tier(user, site) == :none
    end

    test "default off and site off: nothing is queued, the legacy viewer as before" do
      require_approval!(Accounts.default_org_id(), false)
      site = org("both-off")

      {_email, result} = register(tenant: site)
      assert {:ok, user} = result
      assert memberships(user.id) == []
      assert Scoping.effective_tier(user, nil) == :viewer
    end

    test "a site that requires approval queues on itself, whatever the default org says" do
      site = org("site-on")
      require_approval!(site.id)

      for default_on? <- [true, false] do
        require_approval!(Accounts.default_org_id(), default_on?)
        {_email, result} = register(tenant: site)
        assert {:ok, user} = result
        site_id = site.id
        assert [%{organization_id: ^site_id, status: :pending}] = memberships(user.id)
      end
    end

    test "an unreadable setting refuses the registration and creates nothing" do
      site = org("fail-closed")
      require_approval!(site.id)

      {email, result} =
        KilnCMS.OrgSettings.with_actor(nil, fn -> register(tenant: site) end)

      assert {:error, error} = result
      assert RegistrationRefused.reason(error) == :settings_unavailable
      assert users_with(email) == []
    end

    test "an unreadable setting refuses even where approval is off (it cannot be known to be off)" do
      site = org("fail-closed-off")

      {email, result} =
        KilnCMS.OrgSettings.with_actor(nil, fn -> register(tenant: site) end)

      assert {:error, error} = result
      assert RegistrationRefused.reason(error) == :settings_unavailable
      assert users_with(email) == []
    end
  end

  describe "invitations are never queued" do
    test "accepting an invitation to a site that requires approval gives an active membership" do
      admin = user(:admin)
      site = org("invited")
      require_approval!(site.id)

      invitation =
        Accounts.invite_to_org!(
          %{organization_id: site.id, email: address("invitee"), role: :editor},
          actor: admin
        )

      drain_oban()

      # authorize?: false — the accept page's own call, holding the token
      assert {:ok, user} =
               Accounts.register_with_invitation(
                 %{
                   token: invitation.__metadata__.token,
                   password: @password,
                   password_confirmation: @password
                 },
                 authorize?: false
               )

      site_id = site.id
      assert [%{organization_id: ^site_id, status: :active, role: :editor}] = memberships(user.id)
      assert Scoping.effective_tier(user, site) == :editor
    end

    test "a membership an admin creates is active" do
      site = org("created")
      target = user(:viewer)

      membership =
        Accounts.create_org_membership!(
          %{user_id: target.id, organization_id: site.id, role: :viewer},
          actor: user(:admin)
        )

      assert membership.status == :active
      refute membership.created_account
    end

    test "status is not accepted from input on the ordinary write" do
      site = org("no-accept")
      target = user(:viewer)

      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.create_org_membership(
                 %{user_id: target.id, organization_id: site.id, status: :pending},
                 actor: user(:admin)
               )
    end
  end

  describe "the migration default" do
    test "a row written without a status (as the previous release writes) is active" do
      site = org("legacy-row")
      target = user(:viewer)

      Repo.query!(
        """
        INSERT INTO org_memberships (id, organization_id, user_id, role, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, $2, 'viewer', now(), now())
        """,
        [Ecto.UUID.dump!(site.id), Ecto.UUID.dump!(target.id)]
      )

      assert %{status: :active, decided_at: nil} =
               Accounts.get_org_membership!(target.id, site.id, authorize?: false)

      assert Scoping.effective_tier(target, site) == :viewer
    end
  end

  describe "who may queue a registration" do
    test "the registrations system actor, and no person — a platform admin included" do
      site = org("queue")
      target = user(:viewer)
      attrs = %{organization_id: site.id, user_id: target.id}

      for actor <- [nil, user(:admin), user(:editor), target, SystemActor.new(:accounts)] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Accounts.queue_registration(attrs, actor: actor),
               "#{inspect(actor && Map.get(actor, :role, actor))} could queue a registration"
      end

      assert {:ok, %{status: :pending, created_account: false}} =
               Accounts.queue_registration(attrs, actor: SystemActor.new(:registrations))
    end

    test "how the account registered is recorded on the event, and the method is constrained" do
      site = org("queue-method")
      target = user(:viewer)

      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.queue_registration(
                 %{organization_id: site.id, user_id: target.id, method: :magic_link},
                 actor: SystemActor.new(:registrations)
               )

      assert {:ok, %{created_account: true}} =
               Accounts.queue_registration(
                 %{
                   organization_id: site.id,
                   user_id: target.id,
                   method: :site_sso,
                   new_account?: true
                 },
                 actor: SystemActor.new(:registrations)
               )

      assert [%{metadata: %{"method" => "site_sso"}}] =
               Enum.filter(events(site.id, :registration_queued), &(&1.target_id == target.id))
    end
  end

  describe "listing the queue" do
    setup do
      site = org("queue-list")
      other = org("queue-other")
      {applicant, row} = applicant(site.id)
      {unconfirmed, unconfirmed_row} = applicant(site.id, confirmed?: false)
      {_elsewhere, _row} = applicant(other.id)
      member!(user(:viewer), site.id, :viewer)

      %{
        site: site,
        other: other,
        applicant: applicant,
        row: row,
        unconfirmed: unconfirmed,
        unconfirmed_row: unconfirmed_row
      }
    end

    test "a site admin sees this site's applicants, and only their address, name, confirmation and erasure",
         %{site: site, applicant: applicant, row: row, unconfirmed_row: unconfirmed_row} do
      site_admin = user(:viewer)
      member!(site_admin, site.id, :admin)

      assert {:ok, entries} = Registrations.queue(site, actor: site_admin)

      assert Enum.map(entries, & &1.membership.id) |> Enum.sort() ==
               Enum.sort([row.id, unconfirmed_row.id])

      entry = Enum.find(entries, &(&1.membership.id == row.id))
      assert entry.email == to_string(applicant.email)
      assert entry.confirmed?
      refute entry.erased?

      assert Map.keys(entry) |> Enum.sort() == [
               :confirmed?,
               :email,
               :erased?,
               :membership,
               :name,
               :registered_at
             ]

      refute Enum.find(entries, &(&1.membership.id == unconfirmed_row.id)).confirmed?
      assert Registrations.pending_count(site, actor: site_admin) == 2
    end

    test "a platform admin sees it too", %{site: site} do
      assert {:ok, [_, _]} = Registrations.queue(site, actor: user(:admin))
    end

    test "an admin of another site is refused, whichever site they ask from", %{
      site: site,
      other: other
    } do
      other_admin = user(:viewer)
      member!(other_admin, other.id, :admin)

      assert {:error, %Ash.Error.Forbidden{}} = Registrations.queue(site, actor: other_admin)

      # The tenant is the host; the argument still names site A's rows.
      for tenant <- [other.id, site.id, nil] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Accounts.list_registration_queue(site.id, :pending,
                   actor: other_admin,
                   tenant: tenant,
                   authorize_with: :error
                 )
      end

      assert Registrations.pending_count(site, actor: other_admin) == 0
    end

    test "editors, viewers, applicants, anonymous callers and system actors are refused", %{
      site: site,
      applicant: applicant
    } do
      editor = user(:viewer)
      member!(editor, site.id, :editor)
      viewer = user(:viewer)
      member!(viewer, site.id, :viewer)

      for actor <- [editor, viewer, applicant, nil, SystemActor.new(:registrations)] do
        assert {:error, %Ash.Error.Forbidden{}} = Registrations.queue(site, actor: actor)
      end
    end

    test "a pending registration is on no roster", %{site: site, row: row} do
      ids = site.id |> Accounts.list_memberships_for_org!(authorize?: false) |> Enum.map(& &1.id)
      refute row.id in ids
      assert length(ids) == 1
    end
  end

  describe "approving" do
    setup do
      site = org("approve")
      site_admin = user(:viewer)
      member!(site_admin, site.id, :admin)
      %{site: site, site_admin: site_admin}
    end

    test "a site admin approves a confirmed applicant: an active viewer, decided now, audited",
         %{site: site, site_admin: site_admin} do
      {applicant, row} = applicant(site.id)
      assert Scoping.effective_tier(applicant, site) == :none

      assert {:ok, approved} = Accounts.approve_registration(row, %{}, actor: site_admin)
      assert approved.status == :active
      assert approved.role == :viewer
      assert %DateTime{} = approved.decided_at
      assert Scoping.effective_tier(applicant, site) == :viewer

      assert [event] =
               Enum.filter(
                 events(site.id, :registration_approved),
                 &(&1.target_id == applicant.id)
               )

      assert event.actor_id == site_admin.id
      assert event.metadata == %{"role" => "viewer", "via" => "queue"}
      # Not a misleading role_granted on top.
      refute Enum.any?(events(site.id, :role_granted), &(&1.target_id == applicant.id))
    end

    test "a platform admin may approve", %{site: site} do
      {_applicant, row} = applicant(site.id)

      assert {:ok, %{status: :active}} =
               Accounts.approve_registration(row, %{}, actor: user(:admin))
    end

    test "an unconfirmed applicant cannot be approved yet", %{site: site, site_admin: site_admin} do
      {_applicant, row} = applicant(site.id, confirmed?: false)

      assert {:error, error} = Accounts.approve_registration(row, %{}, actor: site_admin)
      assert RegistrationRefused.reason(error) == :unconfirmed
      assert reload(row).status == :pending
    end

    test "approving on site A grants nothing on site B", %{site: site, site_admin: site_admin} do
      other = org("approve-other")
      {applicant, row} = applicant(site.id)

      assert {:ok, _} = Accounts.approve_registration(row, %{}, actor: site_admin)
      assert Scoping.effective_tier(applicant, other) == :none
      assert Scoping.effective_tier(applicant, nil) == :none
    end

    test "an ordinary membership is not a registration to approve", %{
      site: site,
      site_admin: site_admin
    } do
      row = member!(user(:viewer), site.id, :viewer)

      assert {:error, error} = Accounts.approve_registration(row, %{}, actor: site_admin)
      assert RegistrationRefused.reason(error) == :not_pending
    end
  end

  describe "rejecting" do
    test "keeps the account and marks the row rejected, unconfirmed or not, audited" do
      site = org("reject")
      site_admin = user(:viewer)
      member!(site_admin, site.id, :admin)
      {applicant, row} = applicant(site.id, confirmed?: false)

      assert {:ok, rejected} = Accounts.reject_registration(row, %{}, actor: site_admin)
      assert rejected.status == :rejected
      assert %DateTime{} = rejected.decided_at
      assert {:ok, %User{}} = Accounts.get_user(applicant.id, authorize?: false)
      assert Scoping.effective_tier(applicant, site) == :none

      assert [event] =
               Enum.filter(
                 events(site.id, :registration_rejected),
                 &(&1.target_id == applicant.id)
               )

      assert event.metadata == %{"outcome" => "kept"}

      assert {:ok, [entry]} = Registrations.queue(site, actor: site_admin, status: :rejected)
      assert entry.membership.id == row.id
      assert {:ok, []} = Registrations.queue(site, actor: site_admin)
    end

    test "a rejection can be reversed: approving a rejected, confirmed row, audited" do
      site = org("reject-undo")
      site_admin = user(:viewer)
      member!(site_admin, site.id, :admin)
      {applicant, row} = applicant(site.id)

      {:ok, rejected} = Accounts.reject_registration(row, %{}, actor: site_admin)

      assert {:ok, approved} = Accounts.approve_registration(rejected, %{}, actor: site_admin)
      assert approved.status == :active
      assert Scoping.effective_tier(applicant, site) == :viewer

      assert [event] =
               Enum.filter(
                 events(site.id, :registration_approved),
                 &(&1.target_id == applicant.id)
               )

      assert event.metadata == %{"role" => "viewer", "via" => "queue"}
    end

    test "a rejected row of an unconfirmed address still cannot be approved" do
      site = org("reject-undo-unconfirmed")
      {_applicant, row} = applicant(site.id, confirmed?: false)
      {:ok, rejected} = Accounts.reject_registration(row, %{}, actor: user(:admin))

      assert {:error, error} = Accounts.approve_registration(rejected, %{}, actor: user(:admin))
      assert RegistrationRefused.reason(error) == :unconfirmed
      assert reload(row).status == :rejected
    end
  end

  describe "paging the queue" do
    test "pages of page_size, oldest first, continued from the last entry, every row once" do
      site = org("paging")
      site_admin = user(:viewer)
      member!(site_admin, site.id, :admin)
      total = Registrations.page_size() + 7

      ids =
        for _ <- 1..total do
          {_applicant, row} = applicant(site.id)
          row.id
        end

      assert {:ok, %{entries: first, more?: true}} = Registrations.page(site, actor: site_admin)
      assert length(first) == Registrations.page_size()

      assert {:ok, %{entries: second, more?: false}} =
               Registrations.page(site, actor: site_admin, after: List.last(first))

      assert length(second) == 7
      seen = Enum.map(first ++ second, & &1.membership.id)
      assert Enum.sort(seen) == Enum.sort(ids)
      assert seen == Enum.uniq(seen)
    end

    test "the pending count is bounded at count_cap" do
      site = org("count-cap")
      site_admin = user(:viewer)
      member!(site_admin, site.id, :admin)
      for _ <- 1..(Registrations.count_cap() + 3), do: applicant(site.id)

      assert Registrations.pending_count(site, actor: site_admin) == Registrations.count_cap()
    end
  end

  describe "who may decide" do
    setup do
      site = org("decide")
      other = org("decide-other")
      {applicant, row} = applicant(site.id)
      %{site: site, other: other, applicant: applicant, row: row}
    end

    test "refused: an editor, a viewer, the applicant, anonymous, a system actor, another site's admin",
         %{site: site, other: other, applicant: applicant, row: row} do
      editor = user(:viewer)
      member!(editor, site.id, :editor)
      viewer = user(:viewer)
      member!(viewer, site.id, :viewer)
      other_admin = user(:viewer)
      member!(other_admin, other.id, :admin)

      for actor <- [editor, viewer, applicant, nil, SystemActor.new(:registrations), other_admin],
          decide <- [&Accounts.approve_registration/3, &Accounts.reject_registration/3] do
        assert {:error, %Ash.Error.Forbidden{}} = decide.(row, %{}, actor: actor)
      end

      # Whatever host the other admin asks from.
      for tenant <- [site.id, other.id] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Accounts.approve_registration(row, %{}, actor: other_admin, tenant: tenant)
      end

      assert reload(row).status == :pending
    end

    test "refused: a temporary platform admin", %{row: row} do
      temporary =
        user(:viewer, %{
          granted_role: :admin,
          granted_role_expires_at: DateTime.add(DateTime.utc_now(), 3600)
        })

      for decide <- [&Accounts.approve_registration/3, &Accounts.reject_registration/3] do
        assert {:error, %Ash.Error.Invalid{}} = decide.(row, %{}, actor: temporary)
      end

      assert reload(row).status == :pending
    end

    test "allowed: an admin of the row's site, and a platform admin", %{site: site, row: row} do
      site_admin = user(:viewer)
      member!(site_admin, site.id, :admin)

      assert {:ok, %{status: :rejected}} =
               Accounts.reject_registration(row, %{}, actor: site_admin)

      {_applicant, row} = applicant(site.id)

      assert {:ok, %{status: :active}} =
               Accounts.approve_registration(row, %{}, actor: user(:admin))
    end
  end

  describe "races" do
    setup do
      site = org("race")
      site_admin = user(:viewer)
      member!(site_admin, site.id, :admin)
      {_applicant, row} = applicant(site.id)
      %{site: site, site_admin: site_admin, row: row}
    end

    test "approving twice from the same page: the second is refused", %{
      site_admin: site_admin,
      row: row
    } do
      assert {:ok, _} = Accounts.approve_registration(row, %{}, actor: site_admin)

      # `row` is the struct the page still holds, still `:pending`.
      assert {:error, error} = Accounts.approve_registration(row, %{}, actor: site_admin)
      assert RegistrationRefused.reason(error) == :not_pending
    end

    test "a stale struct cannot overturn an approval, nor reject twice", %{
      site: site,
      site_admin: site_admin,
      row: row
    } do
      assert {:ok, _} = Accounts.approve_registration(row, %{}, actor: site_admin)

      # The page still holds `row` as `:pending`; the row is active now.
      assert {:error, error} = Accounts.reject_registration(row, %{}, actor: site_admin)
      assert RegistrationRefused.reason(error) == :not_pending
      assert reload(row).status == :active

      {_applicant, other_row} = applicant(site.id)
      assert {:ok, _} = Accounts.reject_registration(other_row, %{}, actor: site_admin)
      assert {:error, error} = Accounts.reject_registration(other_row, %{}, actor: site_admin)
      assert RegistrationRefused.reason(error) == :not_pending
    end

    test "approve and reject in flight at once: the first to lock wins, the second is refused",
         %{site_admin: site_admin, row: row} do
      test_pid = self()
      start_supervised!({Latch, name: :registration_race, listener: test_pid})

      # Held inside the approval's transaction, after the row is locked and
      # written, until the test lets it commit.
      held =
        row
        |> Ash.Changeset.new()
        |> Ash.Changeset.after_action(fn _changeset, record ->
          Latch.enter(:registration_race)
          {:ok, record}
        end)

      approve = Task.async(fn -> Accounts.approve_registration(held, %{}, actor: site_admin) end)
      assert_receive {:latch_started, :registration_race, 1}, 2_000

      reject = Task.async(fn -> Accounts.reject_registration(row, %{}, actor: site_admin) end)

      assert [_] = Latch.release_all(:registration_race)
      assert {:ok, %{status: :active}} = Task.await(approve)
      assert {:error, error} = Task.await(reject)
      assert RegistrationRefused.reason(error) == :not_pending
      refute_received {:latch_timeout, _, _}

      assert reload(row).status == :active
    end
  end

  describe "an invitation honoured over a registration (#2514)" do
    setup do
      site = org("invite-reg")
      site_admin = user(:viewer)
      member!(site_admin, site.id, :admin)
      %{site: site, site_admin: site_admin, admin: user(:admin)}
    end

    defp invite!(site, email, admin, role \\ :editor) do
      invitation =
        Accounts.invite_to_org!(
          %{organization_id: site.id, email: to_string(email), role: role},
          actor: admin
        )

      drain_oban()
      invitation
    end

    defp accept_existing(invitation),
      # authorize?: false — the accept page's own call, holding the token
      do:
        Accounts.accept_invitation_for_existing_account(invitation.__metadata__.token,
          authorize?: false
        )

    defp approvals(site_id, user),
      do: Enum.filter(events(site_id, :registration_approved), &(&1.target_id == user.id))

    defp pending_notices(admin, site_id),
      do:
        admin
        |> KilnCMS.Notifications.recent(site_id, 50)
        |> Enum.filter(&(&1.event == :registration_pending))

    test "a confirmed account accepting over a waiting registration is approved at the invited tier",
         ctx do
      {applicant, row} = applicant(ctx.site.id)
      invitation = invite!(ctx.site, applicant.email, ctx.admin)

      assert {:ok, %{outcome: :joined}} = accept_existing(invitation)

      assert %{status: :active, role: :editor, decided_at: %DateTime{}} = reload(row)
      assert Scoping.effective_tier(applicant, ctx.site) == :editor
      assert [event] = approvals(ctx.site.id, applicant)
      assert event.metadata == %{"role" => "editor", "via" => "invitation"}
      # Recorded as what it is, not as a role granted on top.
      refute Enum.any?(events(ctx.site.id, :role_granted), &(&1.target_id == applicant.id))
      # The invitation is used up.
      assert KilnCMS.Accounts.Invitations.peek(invitation.__metadata__.token) == nil
    end

    test "an unconfirmed applicant setting a password through the invitation is confirmed and approved, and nobody is told they wait",
         ctx do
      {applicant, row} = applicant(ctx.site.id, confirmed?: false)
      invitation = invite!(ctx.site, applicant.email, ctx.admin, :viewer)

      assert {:ok, accepted} =
               Accounts.accept_invitation_with_password(
                 applicant,
                 %{
                   token: invitation.__metadata__.token,
                   password: @password,
                   password_confirmation: @password
                 },
                 authorize?: false
               )

      assert %DateTime{} = Accounts.get_user!(accepted.id, authorize?: false).confirmed_at
      assert %{status: :active, role: :viewer} = reload(row)
      assert [%{metadata: %{"via" => "invitation"}}] = approvals(ctx.site.id, applicant)
      drain_oban()
      assert pending_notices(ctx.site_admin, ctx.site.id) == []
    end

    test "an invitation sent before the rejection and resent after it approves", ctx do
      {applicant, row} = applicant(ctx.site.id)
      invitation = invite!(ctx.site, applicant.email, ctx.admin)
      {:ok, _rejected} = Accounts.reject_registration(row, %{}, actor: ctx.site_admin)

      resent = Accounts.resend_invitation!(invitation, %{role: :editor}, actor: ctx.admin)
      drain_oban()
      assert DateTime.compare(resent.last_sent_at, reload(row).decided_at) == :gt
      assert DateTime.compare(resent.inserted_at, reload(row).decided_at) == :lt

      assert {:ok, %{outcome: :joined}} = accept_existing(resent)
      assert %{status: :active, role: :editor} = reload(row)
    end

    test "a row approved between the read and the lock is a membership, raised to the invited tier",
         ctx do
      {applicant, row} = applicant(ctx.site.id)
      invitation = invite!(ctx.site, applicant.email, ctx.admin)
      test_pid = self()
      start_supervised!({Latch, name: :invitation_race, listener: test_pid})

      # The queue's approval, held after it locked and wrote the row.
      held =
        row
        |> Ash.Changeset.new()
        |> Ash.Changeset.after_action(fn _changeset, record ->
          Latch.enter(:invitation_race)
          {:ok, record}
        end)

      approve =
        Task.async(fn -> Accounts.approve_registration(held, %{}, actor: ctx.site_admin) end)

      assert_receive {:latch_started, :invitation_race, 1}, 2_000

      # `grant_membership` reads the row as still pending, then waits on the
      # lock the approval holds, and finds it decided: an active `:viewer` row
      # now, which the `:editor` invitation raises (#2452).
      grant =
        Task.async(fn -> KilnCMS.Accounts.Invitations.grant_membership(applicant, invitation) end)

      assert [_] = Latch.release_all(:invitation_race)
      assert {:ok, %{status: :active}} = Task.await(approve)
      assert {:ok, %{outcome: :raised, membership: %{role: :editor}}} = Task.await(grant)
      refute_received {:latch_timeout, _, _}

      assert %{status: :active, role: :editor} = reload(row)
    end

    test "the approval's eviction leaves after the accept commits, and never on a rollback",
         ctx do
      {applicant, row} = applicant(ctx.site.id)
      KilnCMSWeb.Endpoint.subscribe(KilnCMS.Accounts.SessionEviction.topic(applicant.id))

      invitation = invite!(ctx.site, applicant.email, ctx.admin)

      {:error, :rolled_back} =
        KilnCMS.AfterCommit.deferring(fn ->
          Repo.transaction(fn ->
            {:ok, %{outcome: :joined}} = accept_existing(invitation)
            Repo.rollback(:rolled_back)
          end)
        end)

      refute_received %Phoenix.Socket.Broadcast{event: "disconnect"}
      assert reload(row).status == :pending

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, :inside} =
            KilnCMS.AfterCommit.deferring(fn ->
              Repo.transaction(fn ->
                {:ok, %{outcome: :joined}} = accept_existing(invitation)
                refute_received %Phoenix.Socket.Broadcast{event: "disconnect"}
                :inside
              end)
            end)
        end)

      assert_received %Phoenix.Socket.Broadcast{event: "disconnect"}
      refute_received %Phoenix.Socket.Broadcast{event: "disconnect"}
      refute log =~ "after_transaction"
      assert reload(row).status == :active
    end

    test "the password accept evicts after its own commit, never on a rollback, without the nested-hook warning",
         ctx do
      {applicant, row} = applicant(ctx.site.id, confirmed?: false)
      KilnCMSWeb.Endpoint.subscribe(KilnCMS.Accounts.SessionEviction.topic(applicant.id))
      invitation = invite!(ctx.site, applicant.email, ctx.admin, :viewer)

      accept = fn ->
        Accounts.accept_invitation_with_password(
          applicant,
          %{
            token: invitation.__metadata__.token,
            password: @password,
            password_confirmation: @password
          },
          authorize?: false
        )
      end

      {:error, :rolled_back} =
        KilnCMS.AfterCommit.deferring(fn ->
          Repo.transaction(fn ->
            {:ok, _} = accept.()
            refute_received %Phoenix.Socket.Broadcast{event: "disconnect"}
            Repo.rollback(:rolled_back)
          end)
        end)

      refute_received %Phoenix.Socket.Broadcast{event: "disconnect"}
      assert reload(row).status == :pending

      log = ExUnit.CaptureLog.capture_log(fn -> assert {:ok, _} = accept.() end)

      assert reload(row).status == :active
      # The account's own token revocation evicts too; the approval adds one.
      assert_received %Phoenix.Socket.Broadcast{event: "disconnect"}
      refute log =~ "after_transaction"
    end

    test "a rejected registration is approved by an invitation sent after the rejection", ctx do
      {applicant, row} = applicant(ctx.site.id)
      {:ok, _rejected} = Accounts.reject_registration(row, %{}, actor: ctx.site_admin)
      invitation = invite!(ctx.site, applicant.email, ctx.admin)

      assert {:ok, %{outcome: :joined}} = accept_existing(invitation)
      assert %{status: :active, role: :editor} = reload(row)
    end

    test "an invitation sent before the rejection does not overrule it", ctx do
      {applicant, row} = applicant(ctx.site.id)
      invitation = invite!(ctx.site, applicant.email, ctx.admin)
      {:ok, _rejected} = Accounts.reject_registration(row, %{}, actor: ctx.site_admin)

      assert {:error, error} = accept_existing(invitation)
      assert InvitationRefused.in?(error, :invalid)
      assert %{status: :rejected} = reload(row)
      assert Scoping.effective_tier(applicant, ctx.site) == :none
      assert approvals(ctx.site.id, applicant) == []
      # Nothing was consumed: the refusal rolled the accept back.
      assert %{} = KilnCMS.Accounts.Invitations.peek(invitation.__metadata__.token)
    end

    test "the password accept over an older invitation is refused too, and confirms nothing",
         ctx do
      {applicant, row} = applicant(ctx.site.id, confirmed?: false)
      invitation = invite!(ctx.site, applicant.email, ctx.admin)
      {:ok, _rejected} = Accounts.reject_registration(row, %{}, actor: ctx.site_admin)

      assert {:error, error} =
               Accounts.accept_invitation_with_password(
                 applicant,
                 %{
                   token: invitation.__metadata__.token,
                   password: @password,
                   password_confirmation: @password
                 },
                 authorize?: false
               )

      assert InvitationRefused.in?(error, :invalid)
      assert is_nil(Accounts.get_user!(applicant.id, authorize?: false).confirmed_at)
      assert %{status: :rejected} = reload(row)
    end

    test "a role of another org is refused, and the row keeps waiting", ctx do
      foreign = org("invite-reg-foreign")

      role =
        Accounts.create_role!(%{name: "Foreign #{uniq()}", org_id: foreign.id}, actor: ctx.admin)

      {_applicant, row} = applicant(ctx.site.id)

      assert {:error, %Ash.Error.Invalid{} = error} =
               Accounts.approve_registration_by_invitation(
                 row,
                 %{role: :viewer, role_id: role.id, invited_at: DateTime.utc_now()},
                 actor: SystemActor.new(:invitations)
               )

      assert Exception.message(error) =~ "must be a role of this organization"
      assert reload(row).status == :pending
    end

    test "a role of the row's own org is taken", ctx do
      role =
        Accounts.create_role!(%{name: "Own #{uniq()}", org_id: ctx.site.id}, actor: ctx.admin)

      {_applicant, row} = applicant(ctx.site.id)

      assert {:ok, %{status: :active, role_id: role_id}} =
               Accounts.approve_registration_by_invitation(
                 row,
                 %{role: :viewer, role_id: role.id, invited_at: DateTime.utc_now()},
                 actor: SystemActor.new(:invitations)
               )

      assert role_id == role.id
    end

    # Raised to the invited tier (#2452), but not as a registration approved.
    test "an active member accepting is raised, not approved", ctx do
      member = user(:viewer)
      row = member!(member, ctx.site.id, :viewer)
      invitation = invite!(ctx.site, member.email, ctx.admin)

      assert {:ok, %{outcome: :raised, role: :editor}} = accept_existing(invitation)
      assert %{status: :active, role: :editor, decided_at: nil} = reload(row)
      assert approvals(ctx.site.id, member) == []
    end

    test "only the invitations system actor and a standing platform admin may run it", ctx do
      {applicant, row} = applicant(ctx.site.id)
      editor = user(:viewer)
      member!(editor, ctx.site.id, :editor)
      viewer = user(:viewer)
      member!(viewer, ctx.site.id, :viewer)
      args = %{role: :admin, invited_at: DateTime.utc_now()}

      for actor <- [
            ctx.site_admin,
            editor,
            viewer,
            applicant,
            nil,
            SystemActor.new(:registrations),
            SystemActor.new(:accounts)
          ] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Accounts.approve_registration_by_invitation(row, args, actor: actor),
               "#{inspect(actor && Map.get(actor, :role, actor))} could approve by invitation"
      end

      temporary =
        user(:viewer, %{
          granted_role: :admin,
          granted_role_expires_at: DateTime.add(DateTime.utc_now(), 3600)
        })

      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.approve_registration_by_invitation(row, args, actor: temporary)

      assert reload(row).status == :pending

      assert {:ok, %{status: :active, role: :admin}} =
               Accounts.approve_registration_by_invitation(row, args, actor: ctx.admin)
    end
  end

  describe "adding or inviting an address with a registration here" do
    test "a confirmed applicant waiting here is approved at the chosen tier, via an add" do
      site = org("invite-pending")
      {applicant, row} = applicant(site.id)

      assert {:ok, %{outcome: :approved, membership: membership}} =
               Accounts.add_or_invite_member(
                 %{organization_id: site.id, email: to_string(applicant.email), role: :editor},
                 actor: user(:admin)
               )

      assert membership.id == row.id
      assert %{status: :active, role: :editor} = reload(row)

      assert [%{metadata: %{"role" => "editor", "via" => "added"}}] =
               Enum.filter(
                 events(site.id, :registration_approved),
                 &(&1.target_id == applicant.id)
               )
    end

    test "a confirmed applicant rejected here is approved too, and the outcome says it overrode the rejection" do
      site = org("invite-rejected")
      {applicant, row} = applicant(site.id)
      Accounts.reject_registration!(row, %{}, actor: user(:admin))

      assert {:ok, %{outcome: :approved_over_rejection}} =
               Accounts.add_or_invite_member(
                 %{organization_id: site.id, email: to_string(applicant.email)},
                 actor: user(:admin)
               )

      assert %{status: :active, role: :viewer} = reload(row)
    end

    test "a direct add overrides a rejection whatever its recorded time (no clock comparison)" do
      site = org("invite-rejected-skew")
      {applicant, row} = applicant(site.id)
      Accounts.reject_registration!(row, %{}, actor: user(:admin))

      # A rejection written by a node whose clock runs ahead.
      KilnCMS.Repo.query!(
        "UPDATE org_memberships SET decided_at = now() + interval '1 hour' WHERE id = $1",
        [Ecto.UUID.dump!(row.id)]
      )

      assert {:ok, %{outcome: :approved_over_rejection}} =
               Accounts.add_or_invite_member(
                 %{organization_id: site.id, email: to_string(applicant.email)},
                 actor: user(:admin)
               )

      assert %{status: :active} = reload(row)
    end

    test "an unconfirmed applicant, waiting or rejected, is invited and the row left alone" do
      site = org("invite-unconfirmed")
      {waiting, _row} = applicant(site.id, confirmed?: false)
      {rejected, rejected_row} = applicant(site.id, confirmed?: false)
      Accounts.reject_registration!(rejected_row, %{}, actor: user(:admin))

      for {applicant, status} <- [{waiting, :pending}, {rejected, :rejected}] do
        assert {:ok, %{outcome: :invited}} =
                 Accounts.add_or_invite_member(
                   %{organization_id: site.id, email: to_string(applicant.email)},
                   actor: user(:admin)
                 )

        assert [%{status: ^status}] = memberships(applicant.id)
      end
    end

    test "an erased, rejected applicant's address is simply invited; the old row is untouched" do
      site = org("invite-erased")
      {applicant, row} = applicant(site.id)
      Accounts.reject_registration!(row, %{}, actor: user(:admin))
      {:ok, _erased} = Accounts.anonymize_user(applicant, actor: user(:admin))

      assert {:ok, %{outcome: :invited}} =
               Accounts.add_or_invite_member(
                 %{organization_id: site.id, email: to_string(applicant.email)},
                 actor: user(:admin)
               )

      assert %{status: :rejected} = reload(row)
    end

    test "an active member is still refused" do
      site = org("invite-active")
      member = user(:viewer)
      member!(member, site.id, :viewer)

      assert {:error, error} =
               Accounts.add_or_invite_member(
                 %{organization_id: site.id, email: to_string(member.email)},
                 actor: user(:admin)
               )

      assert InvitationRefused.in?(error, :already_member)
    end
  end

  describe "starting a paid membership" do
    setup do
      site = org("billing")

      tier =
        Billing.create_tier!(
          %{
            name: "Members #{uniq()}",
            slug: "members-#{uniq()}",
            audience: :member,
            provider_price_id: "price_#{uniq()}"
          },
          actor: user(:admin),
          tenant: site.id
        )

      %{site: site, tier: tier}
    end

    test "is refused on the site where the registration awaits approval or was rejected", %{
      site: site,
      tier: tier
    } do
      {pending, _row} = applicant(site.id)
      {rejected, rejected_row} = applicant(site.id)
      Accounts.reject_registration!(rejected_row, %{}, actor: user(:admin))

      for account <- [pending, rejected] do
        assert {:error, error} =
                 Billing.start_membership(%{user_id: account.id, tier_id: tier.id},
                   actor: account,
                   tenant: site.id
                 )

        assert RegistrationRefused.reason(error) == :not_approved
      end
    end

    test "is allowed for an approved twin", %{site: site, tier: tier} do
      {approved, row} = applicant(site.id)
      Accounts.approve_registration!(row, %{}, actor: user(:admin))

      assert {:ok, _membership} =
               Billing.start_membership(%{user_id: approved.id, tier_id: tier.id},
                 actor: approved,
                 tenant: site.id
               )
    end

    test "on a site that requires approval, an account with no row there is refused", %{
      site: site,
      tier: tier
    } do
      require_approval!(site.id)
      stranger = user(:viewer)

      assert {:error, error} =
               Billing.start_membership(%{user_id: stranger.id, tier_id: tier.id},
                 actor: stranger,
                 tenant: site.id
               )

      assert RegistrationRefused.reason(error) == :not_approved
      assert memberships(stranger.id) == []
    end

    test "on a site that requires approval, an active member may pay", %{site: site, tier: tier} do
      require_approval!(site.id)
      member = user(:viewer)
      member!(member, site.id, :viewer)

      assert {:ok, _} =
               Billing.start_membership(%{user_id: member.id, tier_id: tier.id},
                 actor: member,
                 tenant: site.id
               )
    end

    test "on a site that does not require approval, nothing changes", %{site: site, tier: tier} do
      stranger = user(:viewer)

      assert {:ok, _} =
               Billing.start_membership(%{user_id: stranger.id, tier_id: tier.id},
                 actor: stranger,
                 tenant: site.id
               )
    end

    test "an unreadable setting refuses checkout for an account with no row", %{
      site: site,
      tier: tier
    } do
      stranger = user(:viewer)

      assert {:error, error} =
               KilnCMS.OrgSettings.with_actor(nil, fn ->
                 Billing.start_membership(%{user_id: stranger.id, tier_id: tier.id},
                   actor: stranger,
                   tenant: site.id
                 )
               end)

      assert RegistrationRefused.reason(error) == :settings_unavailable
    end

    test "an entitlement reached otherwise creates no membership on a site that requires approval",
         %{site: site, tier: tier} do
      require_approval!(site.id)
      # A member elsewhere, so the recompute has nothing legacy to carry.
      reader = user(:viewer)
      member!(reader, org("elsewhere").id, :viewer)

      Ash.Seed.seed!(Billing.Membership, %{
        org_id: site.id,
        user_id: reader.id,
        tier_id: tier.id,
        status: :comped
      })

      assert {:ok, _} = KilnCMS.Billing.Entitlements.recompute(reader.id)
      refute Enum.any?(memberships(reader.id), &(&1.organization_id == site.id))
      assert Scoping.effective_tier(reader, site) == :none

      # Once an admin adds the account, the next recompute syncs the audience.
      row = member!(reader, site.id, :viewer)
      assert {:ok, _} = KilnCMS.Billing.Entitlements.recompute(reader.id)
      assert :member in reload(row).audiences
    end

    test "on a site that does not require approval, the recompute still creates the viewer row",
         %{site: site, tier: tier} do
      reader = user(:viewer)
      member!(reader, org("elsewhere-open").id, :viewer)

      Ash.Seed.seed!(Billing.Membership, %{
        org_id: site.id,
        user_id: reader.id,
        tier_id: tier.id,
        status: :comped
      })

      assert {:ok, _} = KilnCMS.Billing.Entitlements.recompute(reader.id)
      site_id = site.id

      assert Enum.any?(
               memberships(reader.id),
               &match?(%{organization_id: ^site_id, status: :active}, &1)
             )
    end

    test "a legacy membership-less account, already a viewer on the default site, may still pay there" do
      default_id = Accounts.default_org_id()
      require_approval!(default_id)
      legacy = user(:viewer)
      assert Scoping.effective_tier(legacy, nil) == :viewer

      tier = default_tier!()

      assert {:ok, _} =
               Billing.start_membership(%{user_id: legacy.id, tier_id: tier.id},
                 actor: legacy,
                 tenant: default_id
               )
    end

    test "a legacy account's comp on the default site still creates the viewer row with the audience" do
      default_id = Accounts.default_org_id()
      require_approval!(default_id)
      legacy = user(:viewer)
      tier = default_tier!()

      Ash.Seed.seed!(Billing.Membership, %{
        org_id: default_id,
        user_id: legacy.id,
        tier_id: tier.id,
        status: :comped
      })

      assert {:ok, _} = KilnCMS.Billing.Entitlements.recompute(legacy.id)

      assert [%{organization_id: ^default_id, status: :active, role: :viewer} = row] =
               memberships(legacy.id)

      assert :member in row.audiences
      assert Scoping.audiences(legacy, default_id) |> Enum.member?(:member)
    end
  end

  defp default_tier! do
    Billing.create_tier!(
      %{
        name: "Default members #{uniq()}",
        slug: "default-members-#{uniq()}",
        audience: :member,
        provider_price_id: "price_#{uniq()}"
      },
      actor: user(:admin),
      tenant: Accounts.default_org_id()
    )
  end
end
