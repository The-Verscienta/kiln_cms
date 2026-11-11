defmodule KilnCMSWeb.EnumerationInvitationTest do
  @moduledoc """
  A site invitation's link does not say what became of the invitation behind
  it (#2135).

  The token is mailed only to the address it names, so it is not a way to find
  accounts; what is guarded is a link that has *stopped* working. A made-up
  token, an expired one, a revoked one and a used one must all open the same
  page — status, headers, flash and body compared whole by
  `KilnCMS.EnumerationAssertions` — on the first (dead) render and on the
  connected one.
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.EnumerationAssertions
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Invitations
  alias KilnCMS.Accounts.User

  @moduletag :capture_log

  @password "invitee-password-123"

  defp admin do
    Ash.Seed.seed!(User, %{
      email: "enum-inv-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp invite!(admin) do
    invitation =
      Accounts.invite_to_org!(
        %{
          organization_id: Accounts.default_org_id(),
          email: "enum-inv-#{System.unique_integer([:positive])}@example.com",
          role: :editor
        },
        actor: admin
      )

    {invitation, invitation.__metadata__.token}
  end

  defp dead_render(token), do: get(build_conn(), ~p"/auth/invite/#{token}")

  defp live_render(token) do
    {:ok, _view, html} = live(build_conn(), ~p"/auth/invite/#{token}")
    html
  end

  test "made-up, expired, revoked and used links open the same page" do
    admin = admin()

    {expired_invitation, expired} = invite!(admin)

    Ash.Seed.update!(expired_invitation, %{
      expires_at: DateTime.add(DateTime.utc_now(), -1, :minute)
    })

    {revoked_invitation, revoked} = invite!(admin)
    :ok = Accounts.revoke_invitation(revoked_invitation, actor: admin)

    {_used_invitation, used} = invite!(admin)

    {:ok, _user} =
      Accounts.register_with_invitation(
        %{token: used, password: @password, password_confirmation: @password},
        authorize?: false
      )

    made_up = Invitations.generate_token()

    seen =
      assert_indistinguishable(fn -> dead_render(made_up) end, fn -> dead_render(expired) end, [])

    for token <- [revoked, used] do
      assert_indistinguishable(fn -> dead_render(made_up) end, fn -> dead_render(token) end, [])
    end

    for token <- [expired, revoked, used] do
      assert_indistinguishable(fn -> live_render(made_up) end, fn -> live_render(token) end, [])
    end

    assert seen.status == 200
    assert seen.body =~ "no longer valid"
  end
end
