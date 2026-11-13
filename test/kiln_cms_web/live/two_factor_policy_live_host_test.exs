defmodule KilnCMSWeb.TwoFactorPolicyLiveHostTest do
  @moduledoc """
  `/editor/two-factor` (#2872): the way forward it offers depends on the host.
  The setup page is not served on a tenant site host, so "Set up two-step
  sign-in" links to the main host's page there and says so; and a passkey can
  only confirm a save where its ceremony runs, so the help under the code field
  tells a passkey-only admin on a site host to add an authenticator app instead
  of signing in again with the passkey.

  A site host serves the console only while no console host is configured
  (with one, it redirects there), so the site-host tests run without one. The
  ceremony hosts are the site's console host (`<slug>.<console host>`, under
  the main host), which resolves to the test's own site, and the main host,
  which is the default org's. A console host outside the main host is not one.

  `async: false`: the console host is `Application.put_env`, VM-global.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.SecondFactorFixtures
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.TwoFactorFixtures
  alias KilnCMSWeb.SecondFactorGate

  @moduletag :capture_log

  @path "/editor/two-factor"

  @code_or_passkey "Changing this setting needs a second factor from the last 15 minutes. Use a code, or sign in again with your passkey."
  @code_only "Changing this setting needs a second factor from the last 15 minutes. Enter a current code from your authenticator app."
  @passkey_sign_in "Changing this setting needs a second factor from the last 15 minutes. No authenticator app? Sign out and sign in again with your passkey, then save within 15 minutes."
  @add_app "Changing this setting needs a second factor from the last 15 minutes. A passkey can't confirm it at this address: add an authenticator app, then enter its code here."

  # Signed in on `host` as `user`, with no verified second factor on the
  # session, so the page asks for a code.
  defp session(conn, user, host) do
    token = jwt(user)
    {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(token)

    %{conn | host: host}
    |> Phoenix.ConnTest.init_test_session(%{
      "user_token" => token,
      "sign_in" => %{"jti" => jti, "method" => "password"}
    })
  end

  defp site_host(site), do: "#{site.slug}.#{KilnCMSWeb.Tenant.base_host()}"
  defp console_host(site), do: "#{site.slug}.#{KilnCMSWeb.Plugs.ConsoleHost.console_host()}"
  defp main_host, do: URI.parse(SecondFactorGate.main_setup_url()).host

  defp app_admin(site) do
    {user, _secret} = TwoFactorFixtures.enabled_user(role: :viewer, inserted_at: long_ago())
    member!(user, site, :admin)
  end

  defp passkey_admin(site), do: seed_user() |> member!(site, :admin) |> with_passkey()

  defp with_passkey(user) do
    Ash.Seed.seed!(Accounts.Passkey, %{
      user_id: user.id,
      name: "Key",
      credential_id: "cred-#{System.unique_integer([:positive])}",
      public_key: <<1, 2, 3>>,
      sign_count: 0
    })

    user
  end

  # A console host outside the main host, where the browser would refuse the
  # passkeys' RP ID (`ConsoleHost.passkey_capable?/0` is false). Restored on
  # exit, as `with_console_host/0` does.
  defp with_foreign_console_host do
    previous = Application.get_env(:kiln_cms, :console_host)

    Application.put_env(
      :kiln_cms,
      :console_host,
      "sfforeign#{System.unique_integer([:positive])}.example.net"
    )

    KilnCMS.Cache.Hosts.clear()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kiln_cms, :console_host, previous),
        else: Application.delete_env(:kiln_cms, :console_host)

      KilnCMS.Cache.Hosts.clear()
    end)

    :ok
  end

  defp help(view), do: view |> element("#two-factor-policy-code-help") |> render()

  describe "the help under the code field, on a site host" do
    test "on a site host, a passkey-only admin is sent to add an authenticator app", %{
      conn: conn
    } do
      site = org("tfph-site-passkey")
      admin = passkey_admin(site)

      {:ok, view, _html} = conn |> session(admin, site_host(site)) |> live(@path)

      assert help(view) =~ "add an authenticator app, then enter its code here."
      refute help(view) =~ "Sign out and sign in again"

      assert has_element?(
               view,
               ~s(#two-factor-policy-add-app[href="#{SecondFactorGate.main_setup_url()}"])
             )

      assert help(view) =~ "This opens on #{main_host()}, where you sign in again."
    end

    test "on a site host, an admin with the app is asked for its code, not a passkey", %{
      conn: conn
    } do
      site = org("tfph-site-app")
      admin = app_admin(site)

      {:ok, view, _html} = conn |> session(admin, site_host(site)) |> live(@path)

      assert has_element?(view, "#two-factor-policy-code-help", @code_only)
      refute help(view) =~ "passkey"
      refute has_element?(view, "#two-factor-policy-add-app")
    end
  end

  describe "the help under the code field, on a console host" do
    setup do
      with_console_host()
    end

    test "where passkeys work, a passkey-only admin is told to sign in again with it", %{
      conn: conn
    } do
      site = org("tfph-console-passkey")
      admin = passkey_admin(site)

      {:ok, view, _html} = conn |> session(admin, console_host(site)) |> live(@path)

      assert has_element?(view, "#two-factor-policy-code-help", @passkey_sign_in)
      refute has_element?(view, "#two-factor-policy-add-app")
    end

    test "where passkeys work, an admin with the app and a passkey may use either", %{
      conn: conn
    } do
      site = org("tfph-console-both")
      admin = site |> app_admin() |> with_passkey()

      {:ok, view, _html} = conn |> session(admin, console_host(site)) |> live(@path)

      assert has_element?(view, "#two-factor-policy-code-help", @code_or_passkey)
      refute has_element?(view, "#two-factor-policy-add-app")
    end

    test "an admin with the app and no passkey is asked for its code only", %{conn: conn} do
      site = org("tfph-console-app")
      admin = app_admin(site)

      {:ok, view, _html} = conn |> session(admin, console_host(site)) |> live(@path)

      assert has_element?(view, "#two-factor-policy-code-help", @code_only)
      refute help(view) =~ "passkey"
    end

    test "an admin with no factor gets the plain code line under the setup notice", %{
      conn: conn
    } do
      site = org("tfph-console-none")
      admin = seed_user() |> member!(site, :admin)

      {:ok, view, _html} = conn |> session(admin, console_host(site)) |> live(@path)

      assert has_element?(view, "#two-factor-policy-not-enrolled")
      assert has_element?(view, "#two-factor-policy-code-help", @code_only)
      refute help(view) =~ "passkey"
    end

    test "Set up two-step sign-in goes to the page on this host, with no host line", %{
      conn: conn
    } do
      site = org("tfph-setup-console")
      admin = seed_user() |> member!(site, :admin)

      {:ok, view, html} = conn |> session(admin, console_host(site)) |> live(@path)

      assert has_element?(view, ~s(#two-factor-policy-setup-link[href="/account/two-factor"]))
      refute html =~ "where you sign in again"
    end
  end

  describe "Set up two-step sign-in, for an admin with no factor" do
    test "on a site host goes to the main host's setup page, and says so", %{conn: conn} do
      site = org("tfph-setup-site")
      admin = seed_user() |> member!(site, :admin)

      {:ok, view, html} = conn |> session(admin, site_host(site)) |> live(@path)

      assert has_element?(
               view,
               ~s(#two-factor-policy-setup-link[href="#{SecondFactorGate.main_setup_url()}"])
             )

      assert html =~ "This opens on #{main_host()}, where you sign in again."
    end
  end

  describe "on a console host outside the main host" do
    setup do
      with_foreign_console_host()
    end

    test "a passkey-only admin is sent to add an app on the setup page here, with no host line",
         %{conn: conn} do
      refute KilnCMSWeb.Plugs.ConsoleHost.passkey_capable?()
      site = org("tfph-foreign")
      admin = passkey_admin(site)

      {:ok, view, _html} = conn |> session(admin, console_host(site)) |> live(@path)

      assert has_element?(view, "#two-factor-policy-code-help", @add_app)
      assert has_element?(view, ~s(#two-factor-policy-add-app[href="/account/two-factor"]))
      refute help(view) =~ "where you sign in again"
    end
  end

  describe "on the main host" do
    test "a passkey-only admin of its site is told to sign in again with the passkey", %{
      conn: conn
    } do
      main = %{id: Accounts.default_org_id()}
      admin = passkey_admin(main)

      {:ok, view, _html} = conn |> session(admin, main_host()) |> live(@path)

      assert has_element?(view, "#two-factor-policy-code-help", @passkey_sign_in)
      refute has_element?(view, "#two-factor-policy-add-app")
    end

    test "Set up two-step sign-in goes to the page on this host, with no host line", %{
      conn: conn
    } do
      main = %{id: Accounts.default_org_id()}
      admin = seed_user() |> member!(main, :admin)

      {:ok, view, html} = conn |> session(admin, main_host()) |> live(@path)

      assert has_element?(view, ~s(#two-factor-policy-setup-link[href="/account/two-factor"]))
      refute html =~ "where you sign in again"
    end
  end
end
