defmodule KilnCMSWeb.SettingsLiveEnrolmentProofTest do
  @moduledoc """
  `/editor/settings` when adding a second factor needs the email proof
  (#2872): the page has no step to give it, so beside the add controls it says
  where to go (the setup page, on the main host when this is a site host),
  and an add tried anyway is still refused.

  The proof is owed when a site holds the account past its deadline and the
  session signed in with a password. The account is held on one site and
  opens settings on another, which holds nothing: on the holding site the
  gate would send it to the setup page before settings mounts.

  A site host serves settings only while no console host is configured (with
  one, it redirects there), so only the console-host test sets one.

  `async: false`: the console host is `Application.put_env`, VM-global.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.SecondFactorFixtures
  import Phoenix.LiveViewTest

  alias KilnCMSWeb.SecondFactorGate

  @moduletag :capture_log

  @note "You need to confirm your email address before you add a second factor."

  defp main_host, do: URI.parse(SecondFactorGate.main_setup_url()).host

  # An editor held on one site (editors required, no grace, from long ago),
  # and the other site, which requires nothing, where they open settings.
  defp held_elsewhere(slug) do
    holding = org("#{slug}-holds")
    policy_row!(holding, :editors)
    here = org("#{slug}-here")
    user = seed_user() |> member!(holding, :editor) |> member!(here, :editor)
    {user, here}
  end

  test "on a site host, both add controls say where to confirm, linking the main host", %{
    conn: conn
  } do
    {user, here} = held_elsewhere("slep-site")

    {:ok, view, html} = conn |> signed_in(user, here) |> live(~p"/editor/settings")

    for id <- ["#totp-proof-elsewhere", "#passkey-proof-elsewhere"] do
      assert has_element?(view, id, @note), id
      assert has_element?(view, ~s(#{id} a[href="#{SecondFactorGate.main_setup_url()}"])), id
    end

    assert html =~ "This opens on #{main_host()}, where you sign in again."
  end

  test "on a console host, the link is the setup page on this host", %{conn: conn} do
    with_console_host()
    {user, here} = held_elsewhere("slep-console")

    {:ok, view, html} =
      conn |> signed_in(user, here) |> console_conn(here) |> live(~p"/editor/settings")

    assert has_element?(view, ~s(#totp-proof-elsewhere a[href="/account/two-factor"]))
    refute html =~ "where you sign in again"
  end

  test "an add tried anyway is still refused with the flash", %{conn: conn} do
    {user, here} = held_elsewhere("slep-refused")

    {:ok, view, _html} = conn |> signed_in(user, here) |> live(~p"/editor/settings")

    view |> element("button", "Enable two-factor authentication") |> render_click()
    staged = Ash.get!(KilnCMS.Accounts.User, user.id, authorize?: false)
    code = KilnCMS.Accounts.Totp.code_at(staged.totp_pending_secret, System.system_time(:second))
    html = view |> form("#confirm-totp-form", %{"code" => code}) |> render_submit()

    assert html =~ "Confirm your email address before adding a second factor."
    refute Ash.get!(KilnCMS.Accounts.User, user.id, authorize?: false).totp_confirmed_at
  end

  test "no note when no site holds the account", %{conn: conn} do
    site = org("slep-free")
    user = seed_user() |> member!(site, :editor)

    {:ok, view, html} = conn |> signed_in(user, site) |> live(~p"/editor/settings")

    refute html =~ @note
    refute has_element?(view, "#totp-proof-elsewhere")
    refute has_element?(view, "#passkey-proof-elsewhere")
  end

  test "no note for a session that signed in with a passkey", %{conn: conn} do
    {user, here} = held_elsewhere("slep-passkey")
    token = jwt(user)
    {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(token)

    {:ok, _view, html} =
      conn
      |> org_conn(here)
      |> Phoenix.ConnTest.init_test_session(%{
        "user_token" => token,
        "sign_in" => %{"jti" => jti, "method" => "passkey"}
      })
      |> live(~p"/editor/settings")

    refute html =~ @note
  end
end
