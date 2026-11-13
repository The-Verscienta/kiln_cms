defmodule KilnCMSWeb.TwoFactorPolicyLiveTest do
  @moduledoc """
  `/editor/two-factor` (#2247): the admin gate (editors, viewers, an admin of
  another site and an anonymous visitor are refused), the save guard as the
  page meets it (an unenrolled admin is refused; an admin whose session has
  no fresh second factor gives a code), the roster counts and
  the preview, the last change, and the eviction a save with no grace sets
  off.

  That the preview charges no code is in `KilnCMSWeb.SecondFactorGuardBudgetTest`,
  which puts the real budget back. Each test signs in on a site of its own: the policy is cached per site on
  the whole node.
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.SecondFactorFixtures
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.SessionEviction
  alias KilnCMS.Accounts.Totp
  alias KilnCMS.CMS
  alias KilnCMS.TwoFactorFixtures

  @moduletag :capture_log

  @path "/editor/two-factor"

  # `conn` signed in as `user` on `site`, the session marked as having
  # verified a second factor `ago` seconds ago (nil: not at all).
  defp session(conn, user, site, ago) do
    token = jwt(user)
    {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(token)

    marker =
      %{"jti" => jti, "method" => "password"}
      |> then(fn marker ->
        if ago,
          do: Map.put(marker, "second_factor_at", System.system_time(:second) - ago),
          else: marker
      end)

    conn
    |> org_conn(site)
    |> Phoenix.ConnTest.init_test_session(%{"user_token" => token, "sign_in" => marker})
  end

  defp app_admin(site) do
    {user, secret} = TwoFactorFixtures.enabled_user(role: :viewer, inserted_at: long_ago())
    {member!(user, site, :admin), secret}
  end

  defp stored(site) do
    case CMS.list_site_second_factor_policy(
           actor: KilnCMS.SystemActor.new(:operator),
           tenant: site.id,
           authorize_with: :error
         ) do
      {:ok, [row]} -> row
      {:ok, []} -> nil
    end
  end

  defp submit(view, params) do
    view |> form("#two-factor-policy-form", policy: params) |> render_submit()
  end

  describe "who reaches it" do
    test "an editor and a viewer are refused", %{conn: conn} do
      site = org("tfpl-tiers")

      for user <- [editor(site), viewer(site)] do
        assert {:error, {_kind, %{to: to}}} = conn |> session(user, site, 0) |> live(@path)
        refute to == @path
      end
    end

    test "an admin of another site is refused", %{conn: conn} do
      site = org("tfpl-mine")
      other = org("tfpl-other")
      {admin, _secret} = app_admin(site)

      assert {:error, {_kind, %{to: to}}} = conn |> session(admin, other, 0) |> live(@path)
      refute to == @path
    end

    test "an anonymous visitor goes to sign in", %{conn: conn} do
      site = org("tfpl-anon")

      assert {:error, {:redirect, %{to: "/sign-in" <> _}}} =
               conn |> org_conn(site) |> live(@path)
    end

    test "an admin the requirement holds sets up their own factor first", %{conn: conn} do
      site = org("tfpl-held")
      policy_row!(site, :admins)
      admin = seed_user() |> member!(site, :admin)

      # On the site's host: the main host's setup page.
      assert {:error, {:redirect, %{to: to}}} = conn |> session(admin, site, nil) |> live(@path)
      assert to == KilnCMSWeb.SecondFactorGate.main_setup_url()
    end
  end

  describe "saving" do
    test "with a fresh second factor, saves without a code and says who changed what", %{
      conn: conn
    } do
      site = org("tfpl-fresh")
      {admin, _secret} = app_admin(site)

      {:ok, view, html} = conn |> session(admin, site, 60) |> live(@path)
      refute html =~ ~s(id="two-factor-policy-code")

      html = submit(view, %{required_for: "editors", grace_days: "14"})

      assert html =~ "Two-step sign-in settings saved."
      assert %{required_for: :editors, grace_days: 14} = stored(site)
      assert has_element?(view, "#two-factor-policy-last-change", to_string(admin.email))
      assert has_element?(view, "#two-factor-policy-last-change", "Off")
    end

    test "with a stale mark, asks for a code and saves with a good one", %{conn: conn} do
      site = org("tfpl-code")
      {admin, secret} = app_admin(site)

      {:ok, view, html} = conn |> session(admin, site, 3_600) |> live(@path)
      assert html =~ ~s(id="two-factor-policy-code")

      html = submit(view, %{required_for: "admins", grace_days: "7"})
      assert html =~ "Confirm with a code from your authenticator app"
      assert stored(site) == nil

      html = submit(view, %{required_for: "admins", grace_days: "7", code: "000000"})
      assert html =~ "That code isn&#39;t valid."
      assert stored(site) == nil

      code = Totp.code_at(secret, System.system_time(:second))
      html = submit(view, %{required_for: "admins", grace_days: "7", code: code})

      assert html =~ "Two-step sign-in settings saved."
      assert %{required_for: :admins, grace_days: 7} = stored(site)
    end

    test "an admin with no second factor is told to set one up, and nothing is saved", %{
      conn: conn
    } do
      site = org("tfpl-unenrolled")
      admin = seed_user() |> member!(site, :admin)

      {:ok, view, html} = conn |> session(admin, site, nil) |> live(@path)
      assert html =~ ~s(id="two-factor-policy-not-enrolled")
      # On the site's host: the main host's setup page (the page is not
      # served here). Which host says what is `TwoFactorPolicyLiveHostTest`.
      assert html =~ ~s(href="#{KilnCMSWeb.SecondFactorGate.main_setup_url()}")

      html = submit(view, %{required_for: "admins", grace_days: "14"})

      assert html =~ "Set up two-step sign-in on your own account first."
      assert stored(site) == nil
    end

    test "turning it off from a requirement is refused just the same without a factor", %{
      conn: conn
    } do
      site = org("tfpl-weaken")
      row = policy_row!(site, :editors, grace_days: 30, since: DateTime.utc_now())
      admin = seed_user() |> member!(site, :admin)

      {:ok, view, _html} = conn |> session(admin, site, nil) |> live(@path)
      submit(view, %{required_for: "off", grace_days: "0"})

      assert %{required_for: :editors, grace_days: 30} = stored(site)
      assert stored(site).updated_at == row.updated_at
    end

    test "with no grace, the people it holds are disconnected at once", %{conn: conn} do
      site = org("tfpl-evict")
      {admin, _secret} = app_admin(site)
      held = editor(site)
      KilnCMSWeb.Endpoint.subscribe(SessionEviction.topic(held.id))

      {:ok, view, _html} = conn |> session(admin, site, 60) |> live(@path)
      submit(view, %{required_for: "editors", grace_days: "0"})

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 2_000
    end
  end

  describe "what it shows" do
    test "counts per covered role, and no one's name or address", %{conn: conn} do
      site = org("tfpl-roster")
      policy_row!(site, :editors, grace_days: 30, since: DateTime.utc_now())
      {admin, _secret} = app_admin(site)
      in_grace = editor(site)
      _enrolled = site |> editor() |> with_app()

      {:ok, view, html} = conn |> session(admin, site, 60) |> live(@path)

      assert has_element?(view, "#two-factor-roster-editor")
      assert has_element?(view, "#two-factor-roster-admin")
      refute has_element?(view, "#two-factor-roster-viewer")

      assert view |> element("#two-factor-roster-editor") |> render() =~
               ~r{<td[^>]*>2</td>\s*<td[^>]*>1</td>\s*<td[^>]*>\s*1}

      refute html =~ to_string(in_grace.email)
    end

    test "previews how many would be asked, and how many at once", %{conn: conn} do
      site = org("tfpl-preview")
      {admin, _secret} = app_admin(site)
      _editors = [editor(site), editor(site)]
      _reader = viewer(site)

      {:ok, view, _html} = conn |> session(admin, site, 60) |> live(@path)

      html =
        view
        |> form("#two-factor-policy-form", policy: %{required_for: "editors", grace_days: "0"})
        |> render_change()

      assert html =~ "2 people will be asked to set it up;"
      assert html =~ "2 of them right away."

      html =
        view
        |> form("#two-factor-policy-form", policy: %{required_for: "everyone", grace_days: "14"})
        |> render_change()

      assert html =~ "3 people will be asked to set it up;"
      assert html =~ "0 of them right away."
    end

    test "typing the code previews nothing: no roster read per keystroke", %{conn: conn} do
      site = org("tfpl-code-keys")
      {admin, _secret} = app_admin(site)
      _editor = editor(site)

      {:ok, view, html} = conn |> session(admin, site, 3_600) |> live(@path)
      assert html =~ ~s(id="two-factor-policy-code")

      html =
        render_change(view, "preview", %{
          "_target" => ["policy", "code"],
          "policy" => %{"required_for" => "editors", "grace_days" => "0", "code" => "12"}
        })

      refute html =~ "will be asked to set it up"

      html =
        render_change(view, "preview", %{
          "_target" => ["policy", "required_for"],
          "policy" => %{"required_for" => "editors", "grace_days" => "0", "code" => "12"}
        })

      assert html =~ "1 person will be asked to set it up;"
    end

    test "a page left open after a demotion previews nothing", %{conn: conn} do
      site = org("tfpl-demoted")
      {admin, _secret} = app_admin(site)
      _editor = editor(site)

      {:ok, view, _html} = conn |> session(admin, site, 60) |> live(@path)

      {:ok, membership} =
        KilnCMS.Accounts.get_org_membership(admin.id, site.id, authorize?: false)

      Ash.Seed.update!(membership, %{role: :viewer})

      html =
        view
        |> form("#two-factor-policy-form", policy: %{required_for: "editors", grace_days: "0"})
        |> render_change()

      refute html =~ "will be asked to set it up"
    end

    test "names the operator's way back in", %{conn: conn} do
      site = org("tfpl-break-glass")
      {admin, _secret} = app_admin(site)

      {:ok, _view, html} = conn |> session(admin, site, 60) |> live(@path)

      assert html =~ "KilnCMS.Release.second_factor_requirement_off"
    end
  end
end
