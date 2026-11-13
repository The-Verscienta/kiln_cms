defmodule KilnCMSWeb.SettingsLastFactorTest do
  @moduledoc """
  `/editor/settings` while a site requires a second factor (#2247): the last
  factor left has no "Disable" or remove button, and a note says why; with
  another factor, or no requirement, both are there. The actions refuse
  regardless (`KilnCMS.Accounts.KeepsRequiredSecondFactorTest`); the forged
  event here proves the page does not stand in for them.

  Each test signs in on a site of its own: the policy is cached per site on
  the whole node.
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.SecondFactorFixtures
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Totp
  alias KilnCMS.TwoFactorFixtures

  @moduletag :capture_log

  defp requiring_site(slug) do
    site = org(slug)
    policy_row!(site, :editors, grace_days: 30, since: DateTime.utc_now())
    site
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

  test "the authenticator app alone can't be turned off, and says why", %{conn: conn} do
    site = requiring_site("slf-app")
    {user, secret} = app_editor(site)

    {:ok, view, _html} = conn |> signed_in(user, site) |> live(~p"/editor/settings")

    refute has_element?(view, "#disable-totp-form")
    assert has_element?(view, "#last-factor-note", "requires two-step sign-in")

    # A forged submit meets the action's refusal.
    html =
      render_submit(view, "disable_totp", %{
        "code" => Totp.code_at(secret, System.system_time(:second))
      })

    assert html =~ "you can&#39;t remove your last second factor"
    assert Accounts.totp_enabled?(Accounts.get_user!(user.id, authorize?: false))
  end

  test "the only passkey has no remove button", %{conn: conn} do
    site = requiring_site("slf-pk")
    user = seed_user() |> member!(site, :editor)
    passkey = passkey!(user)

    {:ok, view, _html} = conn |> signed_in(user, site) |> live(~p"/editor/settings")

    refute has_element?(view, ~s(button[phx-click="remove_passkey"]))
    assert has_element?(view, "#last-factor-note")

    html = render_click(view, "remove_passkey", %{"id" => passkey.id})
    assert html =~ "you can&#39;t remove your last second factor"
    assert Accounts.second_factors(user).passkeys == 1
  end

  test "with two factors, both can be removed", %{conn: conn} do
    site = requiring_site("slf-both")
    {user, _secret} = app_editor(site)
    passkey!(user)

    {:ok, view, _html} = conn |> signed_in(user, site) |> live(~p"/editor/settings")

    assert has_element?(view, "#disable-totp-form")
    assert has_element?(view, ~s(button[phx-click="remove_passkey"]))
    refute has_element?(view, "#last-factor-note")
  end

  test "where nothing is required, the last factor can go", %{conn: conn} do
    site = org("slf-none")
    {user, _secret} = app_editor(site)

    {:ok, view, _html} = conn |> signed_in(user, site) |> live(~p"/editor/settings")

    assert has_element?(view, "#disable-totp-form")
    refute has_element?(view, "#last-factor-note")
  end
end
