defmodule KilnCMSWeb.EnumerationUnlockTest do
  @moduledoc """
  Asking for a sign-in unlock link (#2250) does not say whether an address has
  an account, or whether it is paused.

  `POST /sign-in/unlock` is answered whole the same way for an unknown
  address, a known one that is not paused, a paused one, a paused one whose
  unlock-mail budget is spent, and an erased one — compared by
  `KilnCMS.EnumerationAssertions`, not by substring. The one difference, the
  mail, lands in the owner's inbox, and is pinned here so it stays the only
  one: exactly the paused account with budget left is mailed.

  `async: false`: it lowers `AccountThrottle`'s budget with
  `Application.put_env/3`, which is node-wide.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.EnumerationAssertions
  import Swoosh.TestAssertions

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.User

  @budget 3

  setup do
    original = Application.get_env(:kiln_cms, AccountThrottle, [])

    Application.put_env(
      :kiln_cms,
      AccountThrottle,
      original |> Keyword.put(:budget, @budget) |> Keyword.put(:unlock_mail_budget, 1)
    )

    on_exit(fn -> Application.put_env(:kiln_cms, AccountThrottle, original) end)
    :ok
  end

  defp address(tag), do: "#{tag}-#{System.unique_integer([:positive])}@example.com"

  defp seed_user(address, attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: address,
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :editor
        },
        attrs
      )
    )
  end

  defp pause!(address), do: Enum.each(1..@budget, fn _ -> AccountThrottle.consume(address) end)

  defp ask(address), do: post(build_conn(), ~p"/sign-in/unlock", %{"email" => address})

  test "every kind of address gets the same page, and only a paused account is mailed" do
    unknown = address("unknown")

    unpaused = address("unpaused")
    seed_user(unpaused)

    paused = address("paused")
    seed_user(paused)
    pause!(paused)

    spent = address("spent")
    seed_user(spent)
    pause!(spent)
    # The budget is one here: this spends it.
    assert AccountThrottle.allow_mail?(:sign_in_unlock, spent)

    erased = address("erased")
    seed_user(erased, %{anonymized_at: DateTime.utc_now()})
    pause!(erased)

    others = [unknown, unpaused, spent, erased]

    seen =
      for other <- others do
        assert_indistinguishable(fn -> ask(paused) end, fn -> ask(other) end, [paused, other])
      end

    assert seen |> Enum.uniq() |> length() == 1
    assert %{status: 200, body: body} = hd(seen)

    assert body =~
             "If an account with that address is paused after too many sign-in attempts, " <>
               "we&#39;ve emailed it a link to lift the pause. The link works once, within 15 minutes."

    # Asked four times for the paused account (once per comparison), mailed
    # once: its unlock budget is one here. Nobody else is mailed.
    KilnCMS.DataCase.drain_oban()
    assert_email_sent(fn mail -> mail.to == [{"", paused}] end)
    refute_email_sent()
  end

  test "the page never echoes or prefills an address", %{conn: conn} do
    html = conn |> get(~p"/sign-in/unlock?email=victim@example.com") |> html_response(200)
    refute html =~ "victim@example.com"

    html =
      build_conn()
      |> post(~p"/sign-in/unlock", %{"email" => "someone@example.com"})
      |> html_response(200)

    refute html =~ "someone@example.com"
  end
end
