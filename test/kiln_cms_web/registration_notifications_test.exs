defmodule KilnCMSWeb.RegistrationNotificationsTest do
  @moduledoc """
  Registration notices (#2251, part two) in the console: the settings switch,
  the queue reading its own notice, the bell's row, and what the queue tells
  an admin about the decision mail.

  The notices themselves — when, to whom, what they say — are
  `KilnCMS.Accounts.RegistrationNotificationsTest`.
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.Accounts.User
  alias KilnCMS.Notifications

  @moduletag :capture_log

  @password "registration-notice-web-123"

  defp uniq, do: System.unique_integer([:positive])

  defp seed_user(role \\ :viewer, attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "regnoteweb-#{uniq()}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp log_in(conn, user) do
    {:ok, user} =
      AshAuthentication.Strategy.action(
        AshAuthentication.Info.strategy!(User, :password),
        :sign_in,
        %{"email" => to_string(user.email), "password" => @password},
        []
      )

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp row(user, org_id, role, status \\ :active) do
    Ash.Seed.seed!(OrgMembership, %{
      user_id: user.id,
      organization_id: org_id,
      role: role,
      status: status
    })
  end

  defp site_admin(org) do
    admin = seed_user()
    row(admin, org.id, :admin)
    admin
  end

  # The notice as `Notifications.Registrations.announce_org/1` writes it.
  defp notice!(org) do
    :ok = Notifications.Registrations.announce_org(org.id)
  end

  defp notices(user, org) do
    user
    |> Notifications.recent(org.id, 50)
    |> Enum.filter(&(&1.event == :registration_pending))
  end

  describe "the settings switch" do
    test "a site admin sees it and can turn the mail off", %{conn: conn} do
      site = org("regnote-settings")
      admin = site_admin(site)

      {:ok, lv, html} = conn |> org_conn(site) |> log_in(admin) |> live(~p"/editor/settings")

      assert html =~ "email me when someone is waiting for approval"

      lv
      |> form("#notification-prefs-form", user: %{"notify_on_registration" => "false"})
      |> render_submit()

      refute KilnCMS.Accounts.get_user!(admin.id, authorize?: false).notify_on_registration
    end

    test "an admin of another site sees it here too: the flag is global", %{conn: conn} do
      site = org("regnote-settings-elsewhere")
      elsewhere = org("regnote-settings-admin-there")
      user = seed_user()
      row(user, site.id, :editor)
      row(user, elsewhere.id, :admin)

      {:ok, _lv, html} = conn |> org_conn(site) |> log_in(user) |> live(~p"/editor/settings")

      assert html =~ "email me when someone is waiting for approval"
    end

    test "an editor and a temporary platform admin do not see it", %{conn: _conn} do
      site = org("regnote-settings-hidden")
      editor = seed_user()
      row(editor, site.id, :editor)

      temporary =
        seed_user(:editor, %{
          granted_role: :admin,
          granted_role_expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
        })

      row(temporary, site.id, :editor)

      for user <- [editor, temporary] do
        {:ok, _lv, html} =
          build_conn() |> org_conn(site) |> log_in(user) |> live(~p"/editor/settings")

        refute html =~ "email me when someone is waiting for approval"
      end
    end
  end

  describe "opening the queue" do
    test "reads the visitor's own notice and nobody else's", %{conn: conn} do
      site = org("regnote-queue")
      admin = site_admin(site)
      other_admin = site_admin(site)
      notice!(site)

      {:ok, _lv, _html} =
        conn |> org_conn(site) |> log_in(admin) |> live(~p"/editor/registrations")

      assert [%{read_at: %DateTime{}}] = notices(admin, site)
      assert [%{read_at: nil}] = notices(other_admin, site)
    end

    test "reads the notice before it lists the queue", %{conn: conn} do
      site = org("regnote-order")
      admin = site_admin(site)
      notice!(site)

      test_pid = self()
      handler = "regnote-order-#{uniq()}"

      # From this test's LiveView only: the handler is global, and the LV
      # process carries the test in `$callers`.
      :telemetry.attach_many(
        handler,
        [[:ash, :notifications, :bulk_update, :start], [:ash, :accounts, :read, :start]],
        fn _event, _measurements, metadata, _config ->
          if test_pid in Process.get(:"$callers", []) and
               metadata.action in [:mark_read, :registration_queue] do
            send(test_pid, {:ash_action, metadata.action})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, _lv, _html} =
        conn |> org_conn(site) |> log_in(admin) |> live(~p"/editor/registrations")

      assert_received {:ash_action, first}
      assert first == :mark_read
      assert_received {:ash_action, :registration_queue}
    end

    test "the bell's row reads as the queue and links to it", %{conn: conn} do
      site = org("regnote-bell")
      admin = site_admin(site)
      notice!(site)

      {:ok, _lv, html} = conn |> org_conn(site) |> log_in(admin) |> live(~p"/editor/inbox")

      assert html =~ "Registrations waiting for approval"
      assert html =~ ~s(href="/editor/registrations")
    end
  end

  describe "the decision, as the queue tells it" do
    setup do
      site = org("regnote-decide")
      confirmed = seed_user()
      row(confirmed, site.id, :viewer, :pending)
      unconfirmed = seed_user(:viewer, %{confirmed_at: nil})
      row(unconfirmed, site.id, :viewer, :pending)
      %{site: site, confirmed: confirmed, unconfirmed: unconfirmed, admin: site_admin(site)}
    end

    defp membership(user, site),
      do: KilnCMS.Accounts.get_org_membership!(user.id, site.id, authorize?: false)

    test "approving says the applicant will be emailed", %{conn: conn} = ctx do
      {:ok, lv, _html} =
        conn |> org_conn(ctx.site) |> log_in(ctx.admin) |> live(~p"/editor/registrations")

      html = lv |> element("#approve-#{membership(ctx.confirmed, ctx.site).id}") |> render_click()

      assert html =~ "We&#39;ll email them."
    end

    test "an erased applicant is marked, cannot be approved and is promised no mail",
         %{conn: conn} = ctx do
      {:ok, _} = KilnCMS.Accounts.anonymize_user(ctx.confirmed, actor: seed_user(:admin))
      id = membership(ctx.confirmed, ctx.site).id

      {:ok, lv, _html} =
        conn |> org_conn(ctx.site) |> log_in(ctx.admin) |> live(~p"/editor/registrations")

      assert has_element?(lv, "#registration-erased-#{id}", "Account erased")
      refute has_element?(lv, "#approve-#{id}")
      refute render(element(lv, "#reject-#{id}")) =~ "emailed"
    end

    test "rejecting asks first, and says a confirmed applicant will be emailed",
         %{conn: conn} = ctx do
      {:ok, lv, _html} =
        conn |> org_conn(ctx.site) |> log_in(ctx.admin) |> live(~p"/editor/registrations")

      confirmed_reject = element(lv, "#reject-#{membership(ctx.confirmed, ctx.site).id}")
      unconfirmed_reject = element(lv, "#reject-#{membership(ctx.unconfirmed, ctx.site).id}")

      assert render(confirmed_reject) =~ "They&#39;ll be emailed that it wasn&#39;t approved."
      refute render(unconfirmed_reject) =~ "emailed"
    end
  end
end
