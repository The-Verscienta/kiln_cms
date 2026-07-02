defmodule KilnCMSWeb.MailSettingsLiveTest do
  @moduledoc """
  Coverage for the admin mail-settings page (`/editor/mail`): access control,
  the DKIM key lifecycle through the UI, DNS verification (offline via the
  configured stub resolvers), the port-25 preflight, and test sends.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.Keys
  alias KilnCMS.Mail

  @password "password123456"

  defp authed_user(role) do
    email = "mail-live-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp mount_as_admin(conn) do
    {:ok, lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/mail")
    {lv, html}
  end

  describe "authorization" do
    test "anonymous users are redirected to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/mail")
    end

    test "editors are redirected away", %{conn: conn} do
      conn = log_in(conn, authed_user(:editor))

      assert {:error,
              {:redirect,
               %{to: "/", flash: %{"error" => "You need admin access to view that page."}}}} =
               live(conn, ~p"/editor/mail")
    end

    test "admins can load the page", %{conn: conn} do
      {_lv, html} = mount_as_admin(conn)

      assert html =~ "DKIM key"
      assert html =~ "DNS records"
      assert html =~ "no key — mail goes out unsigned"
      # Local test env: direct delivery off, explained rather than hidden.
      assert html =~ "Direct delivery is off"
    end
  end

  describe "DKIM key lifecycle" do
    test "generate creates a database key and fills the DNS record", %{conn: conn} do
      {lv, _html} = mount_as_admin(conn)

      html = lv |> element(~s{button[phx-click="generate"]}) |> render_click()

      settings = Mail.get_settings()
      assert settings.dkim_public_key
      assert html =~ settings.dkim_selector
      assert html =~ "v=DKIM1; k=rsa; p=#{settings.dkim_public_key}"
      assert html =~ "Rotate key"
    end

    test "rotate replaces the selector after confirmation", %{conn: conn} do
      {lv, _html} = mount_as_admin(conn)
      lv |> element(~s{button[phx-click="generate"]}) |> render_click()
      before_rotate = Mail.get_settings()

      html = lv |> element(~s{button[phx-click="rotate"]}) |> render_click()

      rotated = Mail.get_settings()
      refute rotated.dkim_selector == before_rotate.dkim_selector
      assert html =~ rotated.dkim_selector
    end

    @tag :tmp_dir
    test "pointing the key at a file checks it and marks the provider active", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "dkim.pem")
      File.write!(path, Keys.generate_rsa_pem())
      {lv, _html} = mount_as_admin(conn)

      lv |> element(~s{input[phx-value-provider="file"]}) |> render_click()

      html =
        lv
        |> form(~s{form[phx-submit="save_key_source"]}, source: %{pointer: path})
        |> render_submit()

      assert html =~ "Key source saved and checked."
      settings = Mail.get_settings()
      assert settings.dkim_key_provider == :file
      assert settings.dkim_public_key
    end

    test "an unusable key source surfaces the provider error", %{conn: conn} do
      {lv, _html} = mount_as_admin(conn)

      lv |> element(~s{input[phx-value-provider="env"]}) |> render_click()

      html =
        lv
        |> form(~s{form[phx-submit="save_key_source"]},
          source: %{pointer: "KILN_TEST_UNSET_#{System.unique_integer([:positive])}"}
        )
        |> render_submit()

      assert html =~ "is not set"
      assert Mail.get_settings().dkim_key_provider == :database
    end
  end

  describe "DNS records and verification" do
    test "saving the server IP validates it", %{conn: conn} do
      {lv, _html} = mount_as_admin(conn)

      lv
      |> form(~s{form[phx-submit="save_server_ip"]}, settings: %{server_ip: "203.0.113.9"})
      |> render_submit()

      assert Mail.get_settings().server_ip == "203.0.113.9"

      html =
        lv
        |> form(~s{form[phx-submit="save_server_ip"]}, settings: %{server_ip: "not-an-ip"})
        |> render_submit()

      assert html =~ "is not a valid IP address"
    end

    test "verify runs the checks (stub DNS: absent records) and persists results", %{conn: conn} do
      {lv, _html} = mount_as_admin(conn)
      lv |> element(~s{button[phx-click="generate"]}) |> render_click()

      lv |> element(~s{button[phx-click="verify"]}) |> render_click()
      html = render_async(lv)

      assert html =~ "no SPF record found"
      assert html =~ "no DKIM record found"
      assert html =~ "last checked"

      settings = Mail.get_settings()
      assert %DateTime{} = settings.last_verified_at
      assert settings.verification_results["dmarc"]["status"] == "warn"
    end
  end

  describe "delivery test" do
    test "the port-25 preflight reports the blocked port (stub TCP)", %{conn: conn} do
      {lv, _html} = mount_as_admin(conn)

      lv |> element(~s{button[phx-click="preflight"]}) |> render_click()
      html = render_async(lv)

      assert html =~ "blocks outbound SMTP"
      assert html =~ "MAIL_MODE=smtp"
    end

    test "sending a test email reports the delivery outcome", %{conn: conn} do
      {lv, _html} = mount_as_admin(conn)

      lv
      |> form(~s{form[phx-submit="send_test"]}, test: %{to: "probe@example.com"})
      |> render_submit()

      render_async(lv)
      # Test adapter accepts everything — the point is the outcome rendering.
      assert lv |> element(~s{[data-test-result="ok"]}) |> has_element?()
    end
  end
end
