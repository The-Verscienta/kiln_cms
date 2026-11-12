defmodule KilnCMS.Accounts.RegistrationNotificationsTest do
  @moduledoc """
  Registration approval, part two (#2251): telling a site's admins that
  someone is waiting, and telling the applicant what was decided.

  The trigger (`Changes.AnnouncePendingRegistration`) fires when an update
  confirms an applicant's address; the notice and its mail are
  `KilnCMS.Notifications.Registrations`; the decision mail is
  `Changes.MailRegistrationDecision`. The console side — the settings switch
  and the queue reading its notice — is
  `KilnCMSWeb.RegistrationNotificationsTest`.
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  import ExUnit.CaptureLog
  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.RegistrationRefused
  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.Accounts.User
  alias KilnCMS.AfterCommit
  alias KilnCMS.CMS
  alias KilnCMS.Mail.DeliveryWorker
  alias KilnCMS.Notifications
  alias KilnCMS.Notifications.Registrations
  alias KilnCMS.Repo
  alias KilnCMSWeb.Plugs.ConsoleHost

  @moduletag :capture_log

  @password "registration-notice-123"

  defp uniq, do: System.unique_integer([:positive])

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "regnote-#{role}-#{uniq()}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role,
          name: "Applicant Person #{uniq()}"
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

  # A site admin who is not a platform admin: their tier is the membership's.
  defp site_admin(org_id, attrs \\ %{}) do
    admin = user(:viewer, attrs)
    member!(admin, org_id, :admin)
    admin
  end

  # An applicant waiting on `org_id`, unconfirmed unless `confirmed?: true`.
  defp applicant(org_id, opts \\ []) do
    confirmed_at = if Keyword.get(opts, :confirmed?, false), do: DateTime.utc_now()
    user = user(:viewer, %{confirmed_at: confirmed_at})
    {user, member!(user, org_id, :viewer, %{status: :pending})}
  end

  defp confirm(user) do
    strategy = AshAuthentication.Info.strategy!(User, :confirm_new_user)

    {:ok, token} =
      AshAuthentication.AddOn.Confirmation.confirmation_token(
        strategy,
        Ash.Changeset.new(user),
        user
      )

    AshAuthentication.Strategy.action(
      strategy,
      :confirm,
      %{"confirm" => token, "password" => @password},
      []
    )
  end

  defp reset_password(user) do
    strategy = AshAuthentication.Info.strategy!(User, :password)
    {:ok, token} = AshAuthentication.Strategy.Password.reset_token_for(strategy, user)
    password = "a-brand-new-password-#{uniq()}"

    AshAuthentication.Strategy.action(
      strategy,
      :reset,
      %{"reset_token" => token, "password" => password, "password_confirmation" => password},
      []
    )
  end

  defp inbox(user, org_id), do: Notifications.recent(user, org_id, 50)

  defp notices(user, org_id),
    do: Enum.filter(inbox(user, org_id), &(&1.event == :registration_pending))

  defp reload(user), do: Accounts.get_user!(user.id, authorize?: false)

  # Every mail the drained jobs delivered to this process, oldest first.
  defp delivered do
    KilnCMS.DataCase.drain_oban()
    collect([])
  end

  defp collect(acc) do
    receive do
      {:email, email} -> collect([email | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp to_address(%{to: [{_name, address}]}), do: address

  defp mails_to(mails, user),
    do: Enum.filter(mails, &(to_address(&1) == to_string(user.email)))

  defp site_name(org), do: KilnCMS.Branding.for_org(org).site_name

  describe "when the notice is sent" do
    setup do
      site = org("regnote")
      %{site: site, admin: site_admin(site.id)}
    end

    test "registering tells nobody: the address is not confirmed yet", %{site: site} = ctx do
      CMS.save_site_registration!(%{approval_required: true},
        actor: user(:admin),
        tenant: site.id
      )

      {:ok, _user} =
        AshAuthentication.Strategy.action(
          AshAuthentication.Info.strategy!(User, :password),
          :register,
          %{
            "email" => "regnote-new-#{uniq()}@example.com",
            "password" => @password,
            "password_confirmation" => @password
          },
          tenant: site
        )

      assert notices(ctx.admin, site.id) == []
    end

    test "confirming the address writes one notice and one mail per admin", ctx do
      {applicant, _row} = applicant(ctx.site.id)
      other_admin = site_admin(ctx.site.id)

      assert {:ok, confirmed} = confirm(applicant)
      assert confirmed.confirmed_at

      mails = delivered()

      for admin <- [ctx.admin, other_admin] do
        assert [_notice] = notices(admin, ctx.site.id)
        assert [mail] = mails_to(mails, admin)
        assert mail.subject == "Registrations are waiting for approval on #{site_name(ctx.site)}"
      end

      # Nothing to the applicant: they are not an admin anywhere.
      assert mails_to(mails, applicant) |> Enum.reject(&(&1.subject =~ "confirm")) == []
    end

    test "a password reset that confirms an unconfirmed applicant announces them", ctx do
      {applicant, _row} = applicant(ctx.site.id)

      assert {:ok, reset} = reset_password(applicant)
      assert reload(reset).confirmed_at

      assert [_notice] = notices(ctx.admin, ctx.site.id)
    end

    test "a reset by an applicant already confirmed announces nothing", ctx do
      {applicant, _row} = applicant(ctx.site.id, confirmed?: true)

      assert {:ok, _reset} = reset_password(applicant)

      assert notices(ctx.admin, ctx.site.id) == []
      assert mails_to(delivered(), ctx.admin) == []
    end

    test "an update that does not confirm announces nothing", ctx do
      {applicant, _row} = applicant(ctx.site.id)

      assert {:ok, updated} =
               Accounts.update_notification_prefs(applicant, %{notify_on_comment: false},
                 actor: applicant
               )

      assert is_nil(reload(updated).confirmed_at)
      assert notices(ctx.admin, ctx.site.id) == []
    end

    # A magic-link sign-in to an unconfirmed account takes it over for the
    # address's owner and confirms it (#2594, `:take_over_by_magic_link`), an
    # update like the other three, so the admins hear about it as they do
    # for a confirmation.
    test "a magic-link sign-in confirms the address and announces it", ctx do
      {applicant, _row} = applicant(ctx.site.id)
      strategy = AshAuthentication.Info.strategy!(User, :magic_link)
      {:ok, token} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, applicant)

      assert {:ok, %User{}} =
               AshAuthentication.Strategy.action(strategy, :sign_in, %{"token" => token}, [])

      assert %DateTime{} = reload(applicant).confirmed_at
      assert [_notice] = notices(ctx.admin, ctx.site.id)
    end

    test "an invalid confirmation token announces nothing", ctx do
      {applicant, _row} = applicant(ctx.site.id)
      strategy = AshAuthentication.Info.strategy!(User, :confirm_new_user)

      assert {:error, _} =
               AshAuthentication.Strategy.action(
                 strategy,
                 :confirm,
                 %{"confirm" => "eyJhbGciOiJIUzI1NiJ9.e30.#{String.duplicate("a", 43)}"},
                 []
               )

      assert is_nil(reload(applicant).confirmed_at)
      assert notices(ctx.admin, ctx.site.id) == []
    end

    test "accepting an invitation confirms an applicant and announces where they wait", ctx do
      {applicant, _row} = applicant(ctx.site.id)

      invitation =
        Accounts.invite_to_org!(
          %{
            organization_id: Accounts.default_org_id(),
            email: to_string(applicant.email),
            role: :editor
          },
          actor: user(:admin)
        )

      password = "an-invited-password-#{uniq()}"

      assert {:ok, accepted} =
               Accounts.accept_invitation_with_password(
                 applicant,
                 %{
                   token: invitation.__metadata__.token,
                   password: password,
                   password_confirmation: password
                 },
                 authorize?: false
               )

      assert reload(accepted).confirmed_at
      assert [_notice] = notices(ctx.admin, ctx.site.id)
    end

    test "a notice that cannot be sent does not fail the confirmation", ctx do
      {applicant, _row} = applicant(ctx.site.id)

      # The site is read as `Accounts.system/0`; with no grant that read is
      # refused, after the confirmation has committed.
      {result, log} =
        with_log(fn -> Accounts.with_actor(nil, fn -> confirm(applicant) end) end)

      assert {:ok, _confirmed} = result
      assert reload(applicant).confirmed_at
      assert notices(ctx.admin, ctx.site.id) == []
      assert log =~ "registration notice for org #{ctx.site.id}"
    end
  end

  describe "after the commit, and only then" do
    setup do
      site = org("regcommit")
      %{site: site, admin: site_admin(site.id)}
    end

    defp admin_mail_jobs(admin),
      do:
        Enum.filter(
          all_enqueued(worker: DeliveryWorker),
          &(&1.args["to"] == ["", to_string(admin.email)])
        )

    test "a confirmation inside a transaction announces once it commits", ctx do
      {applicant, _row} = applicant(ctx.site.id)

      {:ok, :inside} =
        AfterCommit.deferring(fn ->
          Repo.transaction(fn ->
            {:ok, _} = confirm(applicant)

            # Run at once, the notice and its mail job would be visible here,
            # on the transaction's own connection.
            assert notices(ctx.admin, ctx.site.id) == []
            assert admin_mail_jobs(ctx.admin) == []
            :inside
          end)
        end)

      assert [_notice] = notices(ctx.admin, ctx.site.id)
      assert [_job] = admin_mail_jobs(ctx.admin)
    end

    test "a confirmation rolled back announces nothing", ctx do
      {applicant, _row} = applicant(ctx.site.id)

      {:error, :rolled_back} =
        AfterCommit.deferring(fn ->
          Repo.transaction(fn ->
            {:ok, _} = confirm(applicant)
            Repo.rollback(:rolled_back)
          end)
        end)

      assert is_nil(reload(applicant).confirmed_at)
      assert notices(ctx.admin, ctx.site.id) == []
      assert mails_to(delivered(), ctx.admin) == []
    end

    test "a decision mails once it commits, and not when it rolls back", ctx do
      {applicant, row} = applicant(ctx.site.id, confirmed?: true)

      {:error, :rolled_back} =
        AfterCommit.deferring(fn ->
          Repo.transaction(fn ->
            {:ok, _} = Accounts.approve_registration(row, %{}, actor: ctx.admin)
            Repo.rollback(:rolled_back)
          end)
        end)

      assert mails_to(delivered(), applicant) == []

      {:ok, :inside} =
        AfterCommit.deferring(fn ->
          Repo.transaction(fn ->
            {:ok, _} = Accounts.approve_registration(row, %{}, actor: ctx.admin)
            assert admin_mail_jobs(applicant) == []
            :inside
          end)
        end)

      assert [mail] = mails_to(delivered(), applicant)
      assert mail.subject =~ "was approved"
    end
  end

  describe "one notice per admin and site" do
    setup do
      site = org("regbatch")
      %{site: site, admin: site_admin(site.id)}
    end

    test "a second applicant while the first notice is unread adds no row and no mail", ctx do
      {first, _} = applicant(ctx.site.id)
      {second, _} = applicant(ctx.site.id)

      {:ok, _} = confirm(first)
      {:ok, _} = confirm(second)

      assert [_one] = notices(ctx.admin, ctx.site.id)
      assert [_one_mail] = mails_to(delivered(), ctx.admin)
    end

    test "once the notice is read, the next applicant is news again", ctx do
      {first, _} = applicant(ctx.site.id)
      {:ok, _} = confirm(first)
      assert [_] = mails_to(delivered(), ctx.admin)

      assert {:ok, 1} =
               Notifications.mark_read_about(
                 ctx.admin,
                 ctx.site.id,
                 :registration_pending,
                 ctx.site.id
               )

      {second, _} = applicant(ctx.site.id)
      {:ok, _} = confirm(second)

      assert [%{read_at: nil}, %{read_at: %DateTime{}}] = notices(ctx.admin, ctx.site.id)
      assert [_] = mails_to(delivered(), ctx.admin)
    end

    test "an applicant waiting on two sites is announced on each", ctx do
      other = org("regbatch-other")
      other_admin = site_admin(other.id)
      {applicant, _} = applicant(ctx.site.id)
      member!(applicant, other.id, :viewer, %{status: :pending})

      {:ok, _} = confirm(applicant)

      assert [_] = notices(ctx.admin, ctx.site.id)
      assert [_] = notices(other_admin, other.id)
      # Each notice in its own site's inbox only.
      assert notices(ctx.admin, other.id) == []
    end

    test "muting registration mail keeps the bell row and drops the email", ctx do
      muted = site_admin(ctx.site.id, %{notify_on_registration: false})
      {applicant, _} = applicant(ctx.site.id)

      {:ok, _} = confirm(applicant)
      mails = delivered()

      assert [_notice] = notices(muted, ctx.site.id)
      assert mails_to(mails, muted) == []
      assert [_] = mails_to(mails, ctx.admin)
    end
  end

  describe "who hears" do
    test "a site's standing admins, and nobody else" do
      site = org("regwho")
      elsewhere = org("regwho-elsewhere")
      future = DateTime.add(DateTime.utc_now(), 2, :day)

      site_admin = site_admin(site.id)
      platform_admin = user(:admin)
      editor = user(:viewer) |> tap(&member!(&1, site.id, :editor))
      viewer = user(:viewer) |> tap(&member!(&1, site.id, :viewer))
      other_site_admin = site_admin(elsewhere.id)
      pending_admin = user(:viewer) |> tap(&member!(&1, site.id, :admin, %{status: :pending}))
      rejected_admin = user(:viewer) |> tap(&member!(&1, site.id, :admin, %{status: :rejected}))

      temporary_platform_admin =
        user(:viewer, %{granted_role: :admin, granted_role_expires_at: future})

      # A temporary platform grant does not take away a standing site tier.
      temporary_but_site_admin =
        user(:viewer, %{granted_role: :admin, granted_role_expires_at: future})
        |> tap(&member!(&1, site.id, :admin))

      erased_site_admin =
        site_admin(site.id, %{anonymized_at: DateTime.utc_now()})

      erased_platform_admin = user(:admin, %{anonymized_at: DateTime.utc_now()})

      ids = site.id |> Registrations.recipients() |> MapSet.new(& &1.id)

      for heard <- [site_admin, platform_admin, temporary_but_site_admin] do
        assert heard.id in ids
      end

      for unheard <- [
            editor,
            viewer,
            other_site_admin,
            pending_admin,
            rejected_admin,
            temporary_platform_admin,
            erased_site_admin,
            erased_platform_admin
          ] do
        refute unheard.id in ids
      end
    end

    test "on the default site, a membership-less admin hears" do
      legacy_admin = user(:admin)
      default_id = Accounts.default_org_id()

      assert legacy_admin.id in Enum.map(Registrations.recipients(default_id), & &1.id)
    end

    test "every recipient gets the row; the mail follows each one's own switch" do
      site = org("regwho-mail")
      admin = site_admin(site.id)
      platform_admin = user(:admin)
      {applicant, _} = applicant(site.id)

      {:ok, _} = confirm(applicant)
      mails = delivered()

      for heard <- [admin, platform_admin] do
        assert [_] = notices(heard, site.id)
        assert [_] = mails_to(mails, heard)
      end
    end
  end

  describe "what the notice says" do
    setup do
      site = org("regsays")
      %{site: site, admin: site_admin(site.id)}
    end

    test "the site and the queue, never the applicant", ctx do
      {applicant, _} = applicant(ctx.site.id)
      {:ok, _} = confirm(applicant)

      assert [notice] = notices(ctx.admin, ctx.site.id)
      assert notice.title == site_name(ctx.site)
      assert notice.content_type == "registration_queue"
      assert notice.content_id == ctx.site.id
      assert is_nil(notice.block_id)
      assert is_nil(notice.excerpt)
      assert is_nil(notice.actor_name)
      assert KilnCMS.Notifications.Link.editor_path(notice) == "/editor/registrations"

      assert [job] =
               Enum.filter(
                 all_enqueued(worker: DeliveryWorker),
                 &(&1.args["to"] == ["", to_string(ctx.admin.email)])
               )

      assert job.args["org_id"] == ctx.site.id

      assert [mail] = mails_to(delivered(), ctx.admin)
      assert mail.html_body =~ ConsoleHost.org_url("/editor/registrations", ctx.site)

      # The mute switch, on the same site's host.
      assert mail.html_body =~
               ConsoleHost.org_url("/editor/settings#settings-email-notifications", ctx.site)

      for secret <- [to_string(applicant.email), applicant.name] do
        refute mail.html_body =~ secret
        refute mail.subject =~ secret
        refute notice.title =~ secret
      end
    end

    test "a site name is escaped in the mail" do
      site = org("regsays-escape")
      admin = site_admin(site.id)

      CMS.save_site_branding!(%{site_name: "<b>Bold & Co</b>"},
        actor: user(:admin),
        tenant: site.id
      )

      {applicant, _} = applicant(site.id)
      {:ok, _} = confirm(applicant)

      assert [mail] = mails_to(delivered(), admin)
      refute mail.html_body =~ "<b>Bold"
      assert mail.html_body =~ "&lt;b&gt;Bold &amp; Co&lt;/b&gt;"
    end
  end

  describe "the decision mail" do
    setup do
      site = org("regdecide")
      %{site: site, admin: site_admin(site.id)}
    end

    test "approving mails the applicant a sign-in link on the site", ctx do
      {applicant, row} = applicant(ctx.site.id, confirmed?: true)

      assert {:ok, _} = Accounts.approve_registration(row, %{}, actor: ctx.admin)

      assert [mail] = mails_to(delivered(), applicant)
      assert mail.subject == "Your registration on #{site_name(ctx.site)} was approved"
      assert mail.html_body =~ ConsoleHost.tier_url("/sign-in", ctx.site, :viewer)
    end

    test "rejecting mails one plain sentence: no reason, no name, no link", ctx do
      {applicant, row} = applicant(ctx.site.id, confirmed?: true)

      assert {:ok, _} = Accounts.reject_registration(row, %{}, actor: ctx.admin)

      assert [mail] = mails_to(delivered(), applicant)
      assert mail.subject == "About your registration on #{site_name(ctx.site)}"
      assert mail.html_body =~ "Your registration on #{site_name(ctx.site)} wasn't approved."
      refute mail.html_body =~ "href"
      refute mail.html_body =~ to_string(ctx.admin.email)
    end

    test "rejecting an unconfirmed applicant mails nobody", ctx do
      {applicant, row} = applicant(ctx.site.id)

      assert {:ok, _} = Accounts.reject_registration(row, %{}, actor: ctx.admin)

      assert mails_to(delivered(), applicant) == []
    end

    test "reversing a rejection mails the approval", ctx do
      {applicant, row} = applicant(ctx.site.id, confirmed?: true)
      {:ok, rejected} = Accounts.reject_registration(row, %{}, actor: ctx.admin)
      {:ok, _} = Accounts.approve_registration(rejected, %{}, actor: ctx.admin)

      assert [rejection, approval] = mails_to(delivered(), applicant)
      assert rejection.subject =~ "About your registration"
      assert approval.subject =~ "was approved"
    end

    test "a refused decision mails nobody", ctx do
      {applicant, row} = applicant(ctx.site.id, confirmed?: true)
      editor = user(:viewer) |> tap(&member!(&1, ctx.site.id, :editor))

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.approve_registration(row, %{}, actor: editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.reject_registration(row, %{}, actor: editor)

      assert mails_to(delivered(), applicant) == []
    end

    test "a registration queued on the default site names the default site" do
      default = Accounts.default_org()
      admin = user(:admin)
      {applicant, row} = applicant(default.id, confirmed?: true)

      {:ok, _} = Accounts.approve_registration(row, %{}, actor: admin)

      assert [mail] = mails_to(delivered(), applicant)
      assert mail.subject == "Your registration on #{site_name(default)} was approved"
    end

    test "an erased applicant cannot be approved, and a rejection mails nobody", ctx do
      {applicant, row} = applicant(ctx.site.id, confirmed?: true)
      {:ok, erased} = Accounts.anonymize_user(applicant, actor: user(:admin))
      delivered()

      assert {:error, error} = Accounts.approve_registration(row, %{}, actor: ctx.admin)
      assert RegistrationRefused.reason(error) == :erased

      assert {:ok, _} = Accounts.reject_registration(row, %{}, actor: ctx.admin)
      assert mails_to(delivered(), erased) == []
    end
  end

  describe "administers_any_site?/1" do
    test "a standing admin of some site, or a standing platform admin" do
      site = org("regany")
      future = DateTime.add(DateTime.utc_now(), 1, :day)

      assert Registrations.administers_any_site?(site_admin(site.id))
      assert Registrations.administers_any_site?(user(:admin))

      refute Registrations.administers_any_site?(
               user(:viewer)
               |> tap(&member!(&1, site.id, :editor))
             )

      refute Registrations.administers_any_site?(
               user(:viewer)
               |> tap(&member!(&1, site.id, :admin, %{status: :pending}))
             )

      refute Registrations.administers_any_site?(
               user(:viewer, %{granted_role: :admin, granted_role_expires_at: future})
             )

      refute Registrations.administers_any_site?(
               site_admin(site.id, %{anonymized_at: DateTime.utc_now()})
             )
    end
  end

  describe "refused actors" do
    test "nobody else may change someone's registration switch" do
      site = org("regrefuse")
      admin = site_admin(site.id)
      other = user(:editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.update_notification_prefs(admin, %{notify_on_registration: false},
                 actor: other
               )

      assert {:ok, muted} =
               Accounts.update_notification_prefs(admin, %{notify_on_registration: false},
                 actor: admin
               )

      refute muted.notify_on_registration
    end

    test "marking a notice read reaches only the caller's own rows" do
      site = org("regrefuse-mark")
      admin = site_admin(site.id)
      other_admin = site_admin(site.id)
      {applicant, _} = applicant(site.id)
      {:ok, _} = confirm(applicant)

      assert {:ok, 1} =
               Notifications.mark_read_about(admin, site.id, :registration_pending, site.id)

      assert [%{read_at: %DateTime{}}] = notices(admin, site.id)
      assert [%{read_at: nil}] = notices(other_admin, site.id)
    end

    test "nobody can write a registration notice with an actor" do
      site = org("regrefuse-write")
      admin = site_admin(site.id)

      assert {:error, %Ash.Error.Forbidden{}} =
               Notifications.record_notification(
                 %{
                   user_id: admin.id,
                   event: :registration_pending,
                   content_type: "registration_queue",
                   content_id: site.id,
                   title: "Forged"
                 },
                 actor: admin,
                 tenant: site.id
               )
    end
  end
end
