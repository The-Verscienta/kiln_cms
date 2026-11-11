defmodule KilnCMSWeb.ConfirmWithPasswordTest do
  @moduledoc """
  The confirmation page asks for the password chosen at sign-up (#2594), and a
  wrong one comes back to the page with the link still usable, rather than
  landing on sign-in.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.Repo

  @password "sign-up-password-123"

  defp registrant do
    Ash.Seed.seed!(User, %{
      email: "confirm-pw-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      role: :viewer
    })
  end

  defp token(user) do
    strategy = AshAuthentication.Info.strategy!(User, :confirm_new_user)

    {:ok, token} =
      AshAuthentication.AddOn.Confirmation.confirmation_token(
        strategy,
        Ash.Changeset.new(user),
        user
      )

    token
  end

  # The form's own shape: fields nested under `user`.
  defp post_confirm(token, password) do
    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> post(~p"/auth/user/confirm_new_user", %{
      "user" => %{"confirm" => token, "password" => password}
    })
  end

  test "the page asks for the password and points to a reset" do
    {:ok, view, _html} = live(build_conn(), ~p"/confirm_new_user/#{token(registrant())}")

    assert has_element?(
             view,
             "#user-confirm-new-user-form input[type=password][name='user[password]']"
           )

    assert has_element?(
             view,
             "#user-confirm-new-user-form input[type=hidden][name='user[confirm]']"
           )

    assert has_element?(view, "a[href='/reset']")
  end

  test "the right password confirms the address and signs in" do
    user = registrant()
    conn = post_confirm(token(user), @password)

    assert redirected_to(conn) != ~p"/sign-in"
    refute String.starts_with?(redirected_to(conn), "/confirm_new_user/")
    assert %DateTime{} = Repo.reload!(user).confirmed_at
  end

  test "a wrong password goes back to the page, and the link still works" do
    user = registrant()
    token = token(user)
    conn = post_confirm(token, "not-the-password-1")

    assert redirected_to(conn) == ~p"/confirm_new_user/#{token}"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "isn't the password"
    assert Repo.reload!(user).confirmed_at == nil

    post_confirm(token, @password)
    assert %DateTime{} = Repo.reload!(user).confirmed_at
  end

  test "a made-up token lands on sign-in whatever the password" do
    made_up = "eyJhbGciOiJIUzI1NiJ9.e30.#{String.duplicate("a", 43)}"
    conn = post_confirm(made_up, "anything-at-all-1")

    assert redirected_to(conn) == ~p"/sign-in"
  end
end
