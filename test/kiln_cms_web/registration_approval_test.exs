defmodule KilnCMSWeb.RegistrationApprovalTest do
  @moduledoc """
  Registration approval (#2251) through the web: the queue page, the console
  gate and the headless sign-in against an approved twin, the `/account`
  notice, the Team page's pointer, and the register form on a tenant host.

  The domain rules — who may decide, the races, the setting failing closed —
  are `KilnCMS.Accounts.RegistrationApprovalTest`.
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @moduletag :capture_log

  @password "registration-web-123"

  defp uniq, do: System.unique_integer([:positive])

  defp seed_user(role \\ :viewer, attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "regweb-#{uniq()}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp signed_in(user) do
    {:ok, user} =
      AshAuthentication.Strategy.action(
        AshAuthentication.Info.strategy!(User, :password),
        :sign_in,
        %{"email" => to_string(user.email), "password" => @password},
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(signed_in(user))
  end

  defp row(user, org_id, role, status) do
    Ash.Seed.seed!(OrgMembership, %{
      user_id: user.id,
      organization_id: org_id,
      role: role,
      status: status
    })
  end

  defp site_admin(org) do
    admin = seed_user()
    row(admin, org.id, :admin, :active)
    admin
  end

  defp status_of(user, org),
    do: Accounts.get_org_membership!(user.id, org.id, authorize?: false).status

  describe "the queue page" do
    setup do
      site = org("regqueue")
      applicant = seed_user()
      row(applicant, site.id, :viewer, :pending)
      unconfirmed = seed_user(:viewer, %{confirmed_at: nil})
      row(unconfirmed, site.id, :viewer, :pending)
      %{site: site, applicant: applicant, unconfirmed: unconfirmed}
    end

    test "a site admin approves a confirmed applicant", %{conn: conn} = ctx do
      {:ok, lv, html} =
        conn
        |> org_conn(ctx.site)
        |> log_in(site_admin(ctx.site))
        |> live(~p"/editor/registrations")

      assert html =~ to_string(ctx.applicant.email)
      membership = Accounts.get_org_membership!(ctx.applicant.id, ctx.site.id, authorize?: false)

      html = lv |> element("#approve-#{membership.id}") |> render_click()

      assert html =~ "Approved #{ctx.applicant.email}"
      assert status_of(ctx.applicant, ctx.site) == :active
      refute has_element?(lv, "#registration-#{membership.id}")
    end

    test "an unconfirmed applicant offers Reject only, and rejecting keeps the account",
         %{conn: conn} = ctx do
      {:ok, lv, _html} =
        conn
        |> org_conn(ctx.site)
        |> log_in(site_admin(ctx.site))
        |> live(~p"/editor/registrations")

      membership =
        Accounts.get_org_membership!(ctx.unconfirmed.id, ctx.site.id, authorize?: false)

      assert has_element?(lv, "#registrations-unconfirmed #reject-#{membership.id}")
      refute has_element?(lv, "#approve-#{membership.id}")

      # A pushed approve for it (no button) is refused by the action.
      render_click(lv, "approve", %{"id" => membership.id})
      assert status_of(ctx.unconfirmed, ctx.site) == :pending

      lv |> element("#reject-#{membership.id}") |> render_click()
      assert status_of(ctx.unconfirmed, ctx.site) == :rejected
      assert {:ok, %User{}} = Accounts.get_user(ctx.unconfirmed.id, authorize?: false)

      {:ok, rejected, _html} =
        live(
          log_in(build_conn() |> org_conn(ctx.site), site_admin(ctx.site)),
          ~p"/editor/registrations?status=rejected"
        )

      assert has_element?(rejected, "#registrations-rejected #registration-#{membership.id}")
    end

    test "the Rejected tab can reverse a rejection of a confirmed address", %{conn: conn} = ctx do
      membership = Accounts.get_org_membership!(ctx.applicant.id, ctx.site.id, authorize?: false)
      Accounts.reject_registration!(membership, %{}, authorize?: false)

      {:ok, lv, _html} =
        conn
        |> org_conn(ctx.site)
        |> log_in(site_admin(ctx.site))
        |> live(~p"/editor/registrations?status=rejected")

      refute has_element?(lv, "#reject-#{membership.id}")
      lv |> element("#approve-#{membership.id}") |> render_click()
      assert status_of(ctx.applicant, ctx.site) == :active
    end

    test "a long queue is paged with Load more, and a decision keeps the loaded rows",
         %{conn: conn} = ctx do
      page_size = KilnCMS.Accounts.Registrations.page_size()
      for _ <- 1..page_size, do: row(seed_user(), ctx.site.id, :viewer, :pending)

      {:ok, lv, _html} =
        conn
        |> org_conn(ctx.site)
        |> log_in(site_admin(ctx.site))
        |> live(~p"/editor/registrations")

      confirmed = fn ->
        lv
        |> render()
        |> Floki.parse_document!()
        |> Floki.find("#registrations-confirmed li[id^=registration-]")
        |> length()
      end

      # The heading counts what is waiting (setup's one plus the page), not
      # what is loaded.
      assert render(lv) =~ "Waiting for approval (#{page_size + 1})"
      assert confirmed.() == page_size

      lv |> element("#registrations-load-more-confirmed") |> render_click()
      assert confirmed.() == page_size + 1
      refute has_element?(lv, "#registrations-load-more-confirmed")

      # Deciding one takes only that row out: the second page stays loaded.
      membership = Accounts.get_org_membership!(ctx.applicant.id, ctx.site.id, authorize?: false)
      lv |> element("#approve-#{membership.id}") |> render_click()
      assert confirmed.() == page_size
      assert render(lv) =~ "Waiting for approval (#{page_size})"
    end

    test "a wave of unconfirmed sign-ups does not hide a confirmed applicant", %{conn: conn} do
      site = org("regqueue-bots")

      for _ <- 1..60,
          do: row(seed_user(:viewer, %{confirmed_at: nil}), site.id, :viewer, :pending)

      real = seed_user()
      row(real, site.id, :viewer, :pending)
      membership = Accounts.get_org_membership!(real.id, site.id, authorize?: false)

      {:ok, lv, _html} =
        conn |> org_conn(site) |> log_in(site_admin(site)) |> live(~p"/editor/registrations")

      assert has_element?(lv, "#registrations-confirmed #approve-#{membership.id}")
      refute has_element?(lv, "#registrations-empty")
      assert has_element?(lv, "#registrations-load-more-unconfirmed")
      assert render(lv) =~ "Email not confirmed yet (60)"
    end

    test "an id from another site's queue decides nothing", %{conn: conn} = ctx do
      other = org("regqueue-other")
      foreign = seed_user()
      row(foreign, other.id, :viewer, :pending)
      foreign_row = Accounts.get_org_membership!(foreign.id, other.id, authorize?: false)

      {:ok, lv, _html} =
        conn
        |> org_conn(ctx.site)
        |> log_in(site_admin(ctx.site))
        |> live(~p"/editor/registrations")

      render_click(lv, "approve", %{"id" => foreign_row.id})
      render_click(lv, "reject", %{"id" => foreign_row.id})
      assert status_of(foreign, other) == :pending
    end

    test "turns away an editor and a viewer", %{conn: conn} = ctx do
      for role <- [:editor, :viewer] do
        member = seed_user()
        row(member, ctx.site.id, role, :active)

        assert {:error, {:redirect, %{to: "/access-denied?needs=admin"}}} =
                 conn |> org_conn(ctx.site) |> log_in(member) |> live(~p"/editor/registrations")
      end
    end

    test "the settings form turns approval on for this site only", %{conn: conn} = ctx do
      other = org("regqueue-settings-other")

      {:ok, lv, _html} =
        conn
        |> org_conn(ctx.site)
        |> log_in(site_admin(ctx.site))
        |> live(~p"/editor/registrations")

      html =
        lv
        |> form("#registration-settings-form", registration: %{"approval_required" => "true"})
        |> render_submit()

      assert html =~ "Registration settings saved."

      assert {:ok, [%{approval_required: true}]} =
               CMS.list_site_registration(tenant: ctx.site.id, authorize?: false)

      assert {:ok, []} = CMS.list_site_registration(tenant: other.id, authorize?: false)
    end

    test "the settings form saves the single sign-on switch on its own", %{conn: conn} = ctx do
      {:ok, lv, html} =
        conn
        |> org_conn(ctx.site)
        |> log_in(site_admin(ctx.site))
        |> live(~p"/editor/registrations")

      assert html =~ "Applies only if this site has its own single sign-on"

      html =
        lv
        |> form("#registration-settings-form",
          registration: %{"approval_required" => "false", "approval_for_site_sso" => "true"}
        )
        |> render_submit()

      assert html =~ "Registration settings saved."

      assert {:ok, [%{approval_required: false, approval_for_site_sso: true}]} =
               CMS.list_site_registration(tenant: ctx.site.id, authorize?: false)

      assert lv
             |> element("#registration-settings-form input[type=checkbox][checked]")
             |> render() =~
               "approval_for_site_sso"
    end

    test "adding a waiting applicant's address on the Team page approves them",
         %{conn: conn} = ctx do
      {:ok, lv, _html} =
        conn |> org_conn(ctx.site) |> log_in(seed_user(:admin)) |> live(~p"/editor/team")

      html =
        lv
        |> form("#add-member-form", %{
          "member" => %{"email" => to_string(ctx.applicant.email), "role" => "editor"}
        })
        |> render_submit()

      assert html =~ "Their registration on this site is approved, and they are now a member."
      assert status_of(ctx.applicant, ctx.site) == :active
      assert html =~ "1 registration is waiting for approval"
    end

    test "adding a rejected applicant's address says the rejection was overridden",
         %{conn: conn} = ctx do
      rejected = seed_user()

      Ash.Seed.seed!(OrgMembership, %{
        user_id: rejected.id,
        organization_id: ctx.site.id,
        role: :viewer,
        status: :rejected,
        decided_at: DateTime.add(DateTime.utc_now(), -60)
      })

      {:ok, lv, _html} =
        conn |> org_conn(ctx.site) |> log_in(seed_user(:admin)) |> live(~p"/editor/team")

      html =
        lv
        |> form("#add-member-form", %{"member" => %{"email" => to_string(rejected.email)}})
        |> render_submit()

      assert html =~ "had been rejected; it&#39;s now approved"
      assert status_of(rejected, ctx.site) == :active
    end

    test "the Team page points at the queue", %{conn: conn} = ctx do
      {:ok, _lv, html} =
        conn |> org_conn(ctx.site) |> log_in(seed_user(:admin)) |> live(~p"/editor/team")

      assert html =~ "2 registrations are waiting for approval"
      refute html =~ to_string(ctx.applicant.email)
    end
  end

  describe "erasing unconfirmed rejections (#2514)" do
    setup do
      site = org("regerase")
      unconfirmed = seed_user(:viewer, %{confirmed_at: nil})

      row =
        Ash.Seed.seed!(OrgMembership, %{
          user_id: unconfirmed.id,
          organization_id: site.id,
          role: :viewer,
          status: :pending,
          created_account: true
        })

      confirmed = seed_user()
      row(confirmed, site.id, :viewer, :pending)

      %{site: site, unconfirmed: unconfirmed, row: row, confirmed: confirmed}
    end

    defp erase_unconfirmed!(site) do
      CMS.save_site_registration!(
        %{approval_required: true, rejected_accounts: :erase_unconfirmed},
        actor: seed_user(:admin),
        tenant: site.id
      )
    end

    test "the settings form saves the choice, and says what erasing means", %{conn: conn} = ctx do
      {:ok, lv, html} =
        conn
        |> org_conn(ctx.site)
        |> log_in(site_admin(ctx.site))
        |> live(~p"/editor/registrations")

      assert html =~ "Erasing can&#39;t be undone"
      assert html =~ "who confirmed their address is always kept"
      assert html =~ "An erased address can register again"

      html =
        lv
        |> form("#registration-settings-form",
          registration: %{
            "approval_required" => "true",
            "rejected_accounts" => "erase_unconfirmed"
          }
        )
        |> render_submit()

      assert html =~ "Registration settings saved."

      assert {:ok, [%{rejected_accounts: :erase_unconfirmed, approval_required: true}]} =
               CMS.list_site_registration(tenant: ctx.site.id, authorize?: false)

      # Anything else a client sends keeps.
      lv
      |> element("#registration-settings-form")
      |> render_submit(%{"registration" => %{"rejected_accounts" => "erase_everything"}})

      assert {:ok, [%{rejected_accounts: :keep}]} =
               CMS.list_site_registration(tenant: ctx.site.id, authorize?: false)
    end

    test "the unconfirmed row's confirmation warns of the erasure, and rejecting erases",
         %{conn: conn} = ctx do
      erase_unconfirmed!(ctx.site)

      {:ok, lv, _html} =
        conn
        |> org_conn(ctx.site)
        |> log_in(site_admin(ctx.site))
        |> live(~p"/editor/registrations")

      button = lv |> element("#reject-#{ctx.row.id}") |> render()
      assert button =~ ~s(phx-value-erase="true")
      assert button =~ "erase the account?"
      assert button =~ "Erasing can&#39;t be undone, and the address can register again."

      # A confirmed applicant is never erased, so its dialog does not say so.
      confirmed_row =
        Accounts.get_org_membership!(ctx.confirmed.id, ctx.site.id, authorize?: false)

      confirmed_button = lv |> element("#reject-#{confirmed_row.id}") |> render()
      assert confirmed_button =~ ~s(phx-value-erase="false")
      refute confirmed_button =~ "erase the account"

      html = lv |> element("#reject-#{ctx.row.id}") |> render_click()

      assert html =~ "Rejected #{ctx.unconfirmed.email} and erased the account."
      assert %DateTime{} = Accounts.get_user!(ctx.unconfirmed.id, authorize?: false).anonymized_at
      assert status_of(ctx.unconfirmed, ctx.site) == :rejected
    end

    test "with the site keeping rejected accounts, the dialog and the click erase nothing",
         %{conn: conn} = ctx do
      {:ok, lv, _html} =
        conn
        |> org_conn(ctx.site)
        |> log_in(site_admin(ctx.site))
        |> live(~p"/editor/registrations")

      button = lv |> element("#reject-#{ctx.row.id}") |> render()
      assert button =~ ~s(phx-value-erase="false")
      refute button =~ "erase the account"

      # A pushed `erase` is only a request: the site's setting keeps.
      html = render_click(lv, "reject", %{"id" => ctx.row.id, "erase" => "true"})
      assert html =~ "The account was kept"
      assert Accounts.get_user!(ctx.unconfirmed.id, authorize?: false).anonymized_at == nil
    end

    test "a temporary site admin sees the ordinary confirmation, and the account is kept",
         %{conn: conn} = ctx do
      erase_unconfirmed!(ctx.site)
      temporary = seed_user()

      Ash.Seed.seed!(OrgMembership, %{
        user_id: temporary.id,
        organization_id: ctx.site.id,
        role: :editor,
        granted_role: :admin,
        granted_role_expires_at: DateTime.add(DateTime.utc_now(), 3600)
      })

      {:ok, lv, _html} =
        conn
        |> org_conn(ctx.site)
        |> log_in(temporary)
        |> live(~p"/editor/registrations")

      button = lv |> element("#reject-#{ctx.row.id}") |> render()
      assert button =~ ~s(phx-value-erase="false")

      html = render_click(lv, "reject", %{"id" => ctx.row.id, "erase" => "true"})
      assert html =~ "The account was kept"
      assert status_of(ctx.unconfirmed, ctx.site) == :rejected
      assert Accounts.get_user!(ctx.unconfirmed.id, authorize?: false).anonymized_at == nil
    end
  end

  describe "a pending account against its approved twin" do
    setup do
      org_id = Accounts.default_org_id()
      pending = seed_user()
      row(pending, org_id, :admin, :pending)
      approved = seed_user()
      row(approved, org_id, :admin, :active)
      %{pending: pending, approved: approved}
    end

    test "the console refuses the pending account", %{pending: pending, approved: approved} do
      assert {:error, {:redirect, %{to: to}}} =
               build_conn() |> log_in(pending) |> live(~p"/editor")

      refute to == "/editor"

      assert {:ok, _lv, _html} = build_conn() |> log_in(approved) |> live(~p"/editor")
    end

    test "an admin export refuses the pending account", %{pending: pending, approved: approved} do
      refused = build_conn() |> log_in(pending) |> get(~p"/editor/security-log/export.csv")
      assert refused.status in [302, 403]

      allowed = build_conn() |> log_in(approved) |> get(~p"/editor/security-log/export.csv")
      assert allowed.status == 200
    end

    test "the headless sign-in reports no role", %{pending: pending, approved: approved} do
      for {user, role} <- [{pending, "none"}, {approved, "admin"}] do
        conn =
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> post("/api/auth/sign_in", %{email: to_string(user.email), password: @password})

        assert %{"user" => %{"role" => ^role}} = json_response(conn, 201)
      end
    end
  end

  describe "/account" do
    test "says the registration is waiting, or was not approved, and nothing otherwise" do
      org_id = Accounts.default_org_id()

      for {status, text} <- [
            {:pending, "Waiting for approval on"},
            {:rejected, "Your registration on"}
          ] do
        user = seed_user()
        row(user, org_id, :viewer, status)

        {:ok, lv, html} = build_conn() |> log_in(user) |> live(~p"/account")
        assert has_element?(lv, "#registration-status", text)
        assert html =~ text
      end

      member = seed_user()
      row(member, org_id, :viewer, :active)
      {:ok, lv, _html} = build_conn() |> log_in(member) |> live(~p"/account")
      refute has_element?(lv, "#registration-status")
    end

    # #2516: approving an unconfirmed applicant is refused, and a magic-link
    # sign-in does not confirm, so the page has to say how to get unstuck.
    test "tells an unconfirmed applicant to confirm first, via a password reset" do
      user = seed_user(:viewer, %{confirmed_at: nil})
      row(user, Accounts.default_org_id(), :viewer, :pending)

      conn = log_in(build_conn(), user)
      {:ok, lv, _html} = live(conn, ~p"/account")

      assert has_element?(lv, "#registration-status #confirm-first", "Confirm your email address")
      assert has_element?(lv, ~s|#confirm-first a[href="/reset"]|, "Reset your password")
      assert has_element?(lv, "#confirm-first", "confirmation email")

      # The link lands on the reset request form for a signed-in applicant too.
      assert conn |> get(~p"/reset") |> html_response(200)
    end

    test "says nothing about confirming to a confirmed applicant" do
      user = seed_user()
      row(user, Accounts.default_org_id(), :viewer, :pending)

      {:ok, lv, _html} = build_conn() |> log_in(user) |> live(~p"/account")

      assert has_element?(lv, "#registration-status", "Waiting for approval on")
      refute has_element?(lv, "#confirm-first")
    end

    test "says nothing about confirming when no registration is waiting" do
      org_id = Accounts.default_org_id()

      # Unconfirmed with no row at all, and unconfirmed with a rejected one:
      # only a pending registration waits on the confirmation.
      bare = seed_user(:viewer, %{confirmed_at: nil})
      {:ok, lv, _html} = build_conn() |> log_in(bare) |> live(~p"/account")
      refute has_element?(lv, "#confirm-first")

      rejected = seed_user(:viewer, %{confirmed_at: nil})
      row(rejected, org_id, :viewer, :rejected)
      {:ok, lv, _html} = build_conn() |> log_in(rejected) |> live(~p"/account")
      assert has_element?(lv, "#registration-status", "Your registration on")
      refute has_element?(lv, "#confirm-first")
    end
  end

  describe "/account on another site's host" do
    test "names the site the registration is waiting on, wherever it is opened" do
      waiting_on = org("account-waiting")

      CMS.save_site_branding!(%{site_name: "Waiting Site #{uniq()}"},
        authorize?: false,
        tenant: waiting_on.id
      )

      opened_on = org("account-opened")
      user = seed_user()
      row(user, waiting_on.id, :viewer, :pending)
      site_name = KilnCMS.Branding.for_org(waiting_on).site_name

      {:ok, lv, _html} =
        build_conn() |> org_conn(opened_on) |> log_in(user) |> live(~p"/account")

      assert has_element?(lv, "#registration-status", "Waiting for approval on #{site_name}")
    end
  end

  describe "the register form on a tenant host" do
    test "queues the registration on the host's site" do
      site = org("regform")
      CMS.save_site_registration!(%{approval_required: true}, authorize?: false, tenant: site.id)
      email = "regform-#{uniq()}@example.com"

      # An address of its own, so the per-address registration budget other
      # async tests spend from the shared test address cannot refuse this one.
      {conn, _key} = KilnCMS.RateLimitHelpers.client_conn(build_conn())
      {:ok, view, _html} = conn |> org_conn(site) |> live(~p"/register")

      html =
        view
        |> form("form[action='/auth/user/password/register']",
          user: %{email: email, password: @password, password_confirmation: @password}
        )
        |> render_submit()

      assert [user] =
               Accounts.list_users!(authorize?: false)
               |> Enum.filter(&(to_string(&1.email) == email)),
             "no account was created; the form rendered: #{inspect(html)}"

      site_id = site.id

      assert [%{organization_id: ^site_id, status: :pending}] =
               Accounts.list_memberships_for_user!(user.id, authorize?: false)
    end
  end
end
