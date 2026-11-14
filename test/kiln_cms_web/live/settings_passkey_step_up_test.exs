defmodule KilnCMSWeb.SettingsPasskeyStepUpTest do
  @moduledoc """
  Removing a passkey on `/editor/settings` proves a second factor now
  (`KilnCMS.CMS.Changes.SaverVerifiedSecondFactor` on `Passkey.:destroy`): a
  session that verified one in the last 15 minutes removes it at once;
  otherwise the page asks for a code from the authenticator app
  (`KilnCMSWeb.TotpEnrolment.passkey_removal_confirm/1`).
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.SecondFactorFixtures
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.TwoFactorFixtures

  @moduletag :capture_log

  # Signed in on `site`, the session marked as having verified a second
  # factor `ago` seconds ago (nil: not at all).
  defp session(conn, user, site, ago) do
    token = jwt(user)
    {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(token)
    marker = %{"jti" => jti, "method" => "password"}

    marker =
      if ago,
        do: Map.put(marker, "second_factor_at", System.system_time(:second) - ago),
        else: marker

    conn
    |> KilnCMSWeb.ConnCase.org_conn(site)
    |> Phoenix.ConnTest.init_test_session(%{"user_token" => token, "sign_in" => marker})
  end

  defp app_editor(site) do
    {user, secret} = TwoFactorFixtures.enabled_user(role: :viewer, inserted_at: long_ago())
    {member!(user, site, :editor), secret}
  end

  defp passkey!(user) do
    Ash.Seed.seed!(Accounts.Passkey, %{
      user_id: user.id,
      name: "Key",
      credential_id: "cred-#{System.unique_integer([:positive])}",
      public_key: <<1, 2, 3>>,
      sign_count: 0
    })
  end

  defp remove_button(passkey), do: ~s(#passkey-#{passkey.id} button[phx-click="remove_passkey"])

  test "a session that verified a second factor minutes ago removes it at once", %{conn: conn} do
    site = org("spsu-fresh")
    {user, _secret} = app_editor(site)
    passkey = passkey!(user)

    {:ok, view, _html} = conn |> session(user, site, 60) |> live(~p"/editor/settings")

    view |> element(remove_button(passkey)) |> render_click()

    assert Accounts.second_factors(user).passkeys == 0
    refute has_element?(view, "#passkey-removal-confirm")
  end

  test "an older session is asked for a code first", %{conn: conn} do
    site = org("spsu-stale")
    {user, secret} = app_editor(site)
    passkey = passkey!(user)

    {:ok, view, _html} = conn |> session(user, site, 20 * 60) |> live(~p"/editor/settings")

    view |> element(remove_button(passkey)) |> render_click()

    assert Accounts.second_factors(user).passkeys == 1
    assert has_element?(view, "#passkey-removal-confirm #passkey-removal-code")

    view
    |> form("#passkey-removal-confirm", %{"code" => TwoFactorFixtures.current_code(secret)})
    |> render_submit()

    assert Accounts.second_factors(user).passkeys == 0
    refute has_element?(view, "#passkey-removal-confirm")
  end
end
