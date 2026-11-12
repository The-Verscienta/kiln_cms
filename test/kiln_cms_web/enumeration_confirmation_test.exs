defmodule KilnCMSWeb.EnumerationConfirmationTest do
  @moduledoc """
  The email-confirmation link does not say what became of the account behind it
  (#2255).

  A confirmation token is mailed only to the address it names, so it is not a
  way to find accounts; what is guarded is a token that has *stopped* working.
  A token that never existed, one already used and one whose account was since
  deleted must be refused with the same response, and the page the link opens
  must be the same page for a real token and a made-up one (it only offers the
  button; the check happens on the POST). Compared whole by
  `KilnCMS.EnumerationAssertions`.
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.EnumerationAssertions
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias KilnCMS.Accounts.User

  @password "password123456"

  defp address(tag), do: "#{tag}-#{System.unique_integer([:positive])}@example.com"

  # Registers a new address and returns the token from its confirmation mail.
  defp mailed_token do
    email = address("confirm")
    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, _user} =
      AshAuthentication.Strategy.action(
        strategy,
        :register,
        %{"email" => email, "password" => @password, "password_confirmation" => @password},
        []
      )

    KilnCMS.DataCase.drain_oban()

    assert_email_sent(fn mail ->
      send(self(), {:token, mail.html_body})
      mail.to == [{"", email}]
    end)

    assert_received {:token, body}
    [_, token] = Regex.run(~r{/confirm_new_user/([^"<\s]+)}, body)
    {email, token}
  end

  defp post_confirm(token) do
    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> post(~p"/auth/user/confirm_new_user", %{"confirm" => token, "password" => @password})
  end

  test "a made-up token, a used one and one for a deleted account are refused alike" do
    {_email, used} = mailed_token()
    assert post_confirm(used).status == 302
    # The first use confirmed the account; this is the same token again.
    {gone_email, gone} = mailed_token()

    # Users have no destroy action (accounts are anonymised, not deleted), so
    # the row goes the way a hard removal would: straight out of the table.
    KilnCMS.Repo.query!("DELETE FROM users WHERE email = $1", [gone_email])

    made_up = "eyJhbGciOiJIUzI1NiJ9.e30.#{String.duplicate("a", 43)}"

    seen =
      assert_indistinguishable(fn -> post_confirm(made_up) end, fn -> post_confirm(used) end, [])

    assert_indistinguishable(fn -> post_confirm(made_up) end, fn -> post_confirm(gone) end, [])

    assert seen.status == 302
    assert seen.headers == [{"location", "/sign-in"}]
    assert seen.flash["error"]
  end

  test "the link opens the same page for a real token and a made-up one" do
    {_email, real} = mailed_token()
    made_up = "eyJhbGciOiJIUzI1NiJ9.e30.#{String.duplicate("a", 43)}"

    page = fn token ->
      {:ok, _view, html} = live(build_conn(), ~p"/confirm_new_user/#{token}")
      # The CSP nonce is minted per render, like the CSRF token.
      String.replace(html, ~r/nonce="[^"]*"/, "")
    end

    assert_indistinguishable(fn -> page.(real) end, fn -> page.(made_up) end, [real, made_up])
  end
end
