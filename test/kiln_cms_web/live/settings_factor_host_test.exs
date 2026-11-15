defmodule KilnCMSWeb.SettingsFactorHostTest do
  @moduledoc """
  Where `/editor/settings` manages second factors (GHSA-mq8x-2p99-6q8c): on
  the main host and console hosts only, as `/account/two-factor` is
  (`KilnCMSWeb.SecondFactorGate.setup_host?/1`). A tenant site host is the
  origin a site administrator's injected script runs on, and that script can
  send the page's events directly, so on a site host every factor event is
  refused server-side, not only hidden, and the sections link to the main
  host's page instead.

  The passkey registration is pinned to the host the page was served on
  (`KilnCMS.Accounts.WebAuthn.register_passkey/4`), so an attestation whose
  client-reported origin is another host is refused.

  `async: false`: the console-host test sets `Application.put_env`, VM-global.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.SecondFactorFixtures
  import KilnCMS.PasskeyFixtures, only: [b64: 1, client_data_create: 1, main_origin: 0]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.Accounts.WebAuthn

  @moduletag :capture_log

  @refused "Passkeys and two-factor authentication are managed on the main sign-in host"

  # What only the factor sections draw where they are managed.
  @factor_ui ~w(two-factor-manage passkeys-manage add-passkey-form regenerate-recovery-form
                disable-totp-form)

  defp main_host, do: URI.parse(KilnCMSWeb.Endpoint.url()).host

  # A global editor, signed in on the main host (which resolves to the
  # default site, whose `/editor` a site-only editor could not open).
  defp on_main_host(conn) do
    user = KilnCMS.PasskeyFixtures.passkey_user(:editor)
    token = jwt(user)
    {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(token)

    conn =
      conn
      |> main_host_conn()
      |> Phoenix.ConnTest.init_test_session(%{
        "user_token" => token,
        "sign_in" => %{"jti" => jti, "method" => "password"}
      })

    {conn, user}
  end

  defp editor_on_free_site(slug) do
    site = org(slug)
    {seed_user() |> member!(site, :editor), site}
  end

  defp reload(user), do: Ash.get!(User, user.id, authorize?: false)

  defp attestation(bytes, origin) do
    %{
      "attestation_object" => b64(bytes),
      "client_data_json" => b64(client_data_create(origin)),
      "name" => "Forged"
    }
  end

  describe "on a tenant site host (no console host)" do
    test "the mount draws no factor controls, only a link to the main host", %{conn: conn} do
      {user, site} = editor_on_free_site("sfh-mount")

      {:ok, view, html} = conn |> signed_in(user, site) |> live(~p"/editor/settings")

      for id <- @factor_ui, do: refute(has_element?(view, "##{id}"), id)

      expected = KilnCMSWeb.SecondFactorGate.main_setup_url()

      for id <- ["#two-factor-elsewhere", "#passkeys-elsewhere"] do
        assert has_element?(view, ~s(#{id} a[href="#{expected}"])), id
      end

      assert html =~ "This opens on #{main_host()}, where you sign in again."
    end

    test "passkey_begin mints no challenge and pushes no ceremony", %{conn: conn} do
      {user, site} = editor_on_free_site("sfh-begin")
      {:ok, view, _html} = conn |> signed_in(user, site) |> live(~p"/editor/settings")

      assert render_hook(view, "passkey_begin", %{"name" => "x"}) =~ @refused
      refute_push_event(view, "passkey-register", %{}, 50)
    end

    test "passkey_attestation registers nothing, whatever origin it claims", %{conn: conn} do
      {user, site} = editor_on_free_site("sfh-attest")
      {:ok, view, _html} = conn |> signed_in(user, site) |> live(~p"/editor/settings")

      render_hook(view, "passkey_begin", %{})

      assert render_hook(view, "passkey_attestation", attestation("sfh-forged", main_origin())) =~
               @refused

      assert WebAuthn.list(user) == []
    end

    test "remove_passkey removes nothing", %{conn: conn} do
      {user, site} = editor_on_free_site("sfh-remove")
      {:ok, _} = KilnCMS.PasskeyFixtures.enroll(user, "sfh-keep-1")
      {:ok, _} = KilnCMS.PasskeyFixtures.enroll(user, "sfh-keep-2")
      [passkey | _] = WebAuthn.list(user)

      {:ok, view, _html} = conn |> signed_in(user, site) |> live(~p"/editor/settings")

      assert render_hook(view, "remove_passkey", %{"id" => passkey.id}) =~ @refused
      assert length(WebAuthn.list(user)) == 2
    end

    test "start_totp and confirm_totp stage and confirm nothing", %{conn: conn} do
      {user, site} = editor_on_free_site("sfh-totp")
      {:ok, view, _html} = conn |> signed_in(user, site) |> live(~p"/editor/settings")

      assert render_hook(view, "start_totp", %{}) =~ @refused
      assert render_hook(view, "confirm_totp", %{"code" => "123456"}) =~ @refused

      reloaded = reload(user)
      assert is_nil(reloaded.totp_pending_secret)
      assert is_nil(reloaded.totp_confirmed_at)
    end

    test "regenerate_recovery_codes and disable_totp change nothing", %{conn: conn} do
      {user, site} = editor_on_free_site("sfh-disable")
      user = with_app(user)
      {:ok, view, _html} = conn |> signed_in(user, site) |> live(~p"/editor/settings")

      assert render_hook(view, "regenerate_recovery_codes", %{"code" => "123456"}) =~ @refused
      assert render_hook(view, "disable_totp", %{"code" => "123456"}) =~ @refused
      assert reload(user).totp_confirmed_at
    end
  end

  describe "on the main host" do
    test "the factor sections are managed here, and a passkey registers", %{conn: conn} do
      {conn, user} = on_main_host(conn)
      {:ok, view, _html} = live(conn, ~p"/editor/settings")

      assert has_element?(view, "#two-factor-manage")
      assert has_element?(view, "#add-passkey-form")
      refute has_element?(view, "#two-factor-elsewhere")

      render_hook(view, "passkey_begin", %{})
      assert_push_event(view, "passkey-register", %{})

      assert render_hook(view, "passkey_attestation", attestation("sfh-main-ok", main_origin())) =~
               "Passkey added"

      assert [_passkey] = WebAuthn.list(user)
    end

    test "an attestation claiming another host's origin is refused", %{conn: conn} do
      {conn, user} = on_main_host(conn)
      {:ok, view, _html} = live(conn, ~p"/editor/settings")

      render_hook(view, "passkey_begin", %{})
      site_origin = "http://#{org("sfh-mismatch").slug}.#{KilnCMSWeb.Tenant.base_host()}"

      assert render_hook(view, "passkey_attestation", attestation("sfh-mismatch", site_origin)) =~
               "Couldn&#39;t verify that passkey"

      assert WebAuthn.list(user) == []
    end
  end

  describe "on a console host" do
    test "the factor sections are managed here", %{conn: conn} do
      with_console_host()
      {user, site} = editor_on_free_site("sfh-console")

      {:ok, view, _html} =
        conn |> signed_in(user, site) |> console_conn(site) |> live(~p"/editor/settings")

      assert has_element?(view, "#two-factor-manage")
      assert has_element?(view, "#passkeys-manage")
      refute has_element?(view, "#passkeys-elsewhere")
      assert render_hook(view, "start_totp", %{}) =~ "confirm-totp-form"
    end
  end
end
