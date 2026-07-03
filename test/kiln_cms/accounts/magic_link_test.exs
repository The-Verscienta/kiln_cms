defmodule KilnCMS.Accounts.MagicLinkTest do
  @moduledoc """
  Coverage for the passwordless magic-link strategy: existing users get a
  sign-in link by email, and (since registration is disabled) unknown emails
  produce nothing — no account creation, no enumeration leak.
  """
  use KilnCMS.DataCase, async: true
  import Swoosh.TestAssertions

  alias KilnCMS.Accounts.User

  defp confirmed_user do
    Ash.Seed.seed!(User, %{
      email: "ml-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })
  end

  defp request_magic_link(email) do
    strategy = AshAuthentication.Info.strategy!(User, :magic_link)
    AshAuthentication.Strategy.action(strategy, :request, %{"email" => email})
  end

  test "requesting a magic link for an existing user emails a sign-in link" do
    user = confirmed_user()

    assert :ok = request_magic_link(to_string(user.email))

    # The sender enqueues delivery on the :mail queue (KilnCMS.Mail); the
    # email only reaches the test adapter once the job runs.
    KilnCMS.DataCase.drain_oban()

    assert_email_sent(fn email ->
      email.subject == "Your KilnCMS sign-in link" and
        email.to == [{"", to_string(user.email)}]
    end)
  end

  test "requesting a magic link for an unknown email sends nothing (registration disabled)" do
    assert :ok = request_magic_link("nobody-#{System.unique_integer([:positive])}@example.com")

    KilnCMS.DataCase.drain_oban()

    refute_email_sent()
  end
end
