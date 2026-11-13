defmodule KilnCMSWeb.EnumerationRequestFormsTest do
  @moduledoc """
  The password-reset and magic-link request forms do not say whether an address
  has an account (#2255).

  Both forms submit as a LiveView event, discard the action's result, blank
  themselves and flash one fixed sentence. So the browser-visible response is
  asserted whole (`KilnCMS.EnumerationAssertions`) and the *action* — the thing
  a client reaching `AshAuthentication.Strategy.action/4` directly sees — is
  asserted to answer `:ok` for a known and an unknown address alike.

  What is **not** the same, and cannot be: a known address is mailed. That
  difference lands in the owner's inbox, not in the requester's response, and is
  pinned here (one mail for the owner, none for a stranger) so it stays the
  *only* difference. Mail is enqueued on the `mail` queue, never sent inline, so
  the SMTP round trip is not on the response path of either case.
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.EnumerationAssertions
  import KilnCMS.MailAssertions
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias KilnCMS.Accounts.User

  defp address(tag), do: "#{tag}-#{System.unique_integer([:positive])}@example.com"

  defp seed_user(address) do
    Ash.Seed.seed!(User, %{
      email: address,
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })
  end

  describe "password reset request, the form" do
    defp submit_reset(conn, address) do
      {:ok, view, _html} = live(conn, ~p"/reset")

      view
      |> form("#user-password-request-password-reset-token", user: %{email: address})
      |> render_submit()

      # The confirmation arrives as a message to the view; render after it.
      render(view)
    end

    test "a known and an unknown address render the same page", %{conn: conn} do
      known = address("known")
      unknown = address("unknown")
      seed_user(known)

      html =
        assert_indistinguishable(
          fn -> submit_reset(conn, known) end,
          fn -> submit_reset(build_conn(), unknown) end,
          [known, unknown]
        )

      # Pinned, so "equal" cannot mean "equally empty".
      assert html =~
               "If this user exists in our system, you will be contacted with password reset instructions shortly."
    end
  end

  describe "magic link request, the form" do
    defp submit_magic_link(conn, address) do
      {:ok, view, _html} = live(conn, ~p"/sign-in")

      view
      |> form("#user-magic-link-request-magic-link", user: %{email: address})
      |> render_submit()

      render(view)
    end

    test "a known and an unknown address render the same page", %{conn: conn} do
      known = address("known")
      unknown = address("unknown")
      seed_user(known)

      html =
        assert_indistinguishable(
          fn -> submit_magic_link(conn, known) end,
          fn -> submit_magic_link(build_conn(), unknown) end,
          [known, unknown]
        )

      assert html =~
               "If this user exists in our database, you will be contacted with a sign-in link shortly."
    end
  end

  describe "the plain POST routes behind them" do
    # These routes are the no-JavaScript fallback for the two forms. As shipped
    # they raise for EVERY address — `AuthController.success/4` is handed a nil
    # user by a request activity and `totp_enabled?/1` has no clause for it — so
    # the response is a 500 either way. The raise is observed rather than
    # asserted away: what matters here is that known and unknown fail alike, and
    # that a future fix (a redirect with one flash) is held to the same bar.
    defp post_request(path, address) do
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> post(path, %{"user" => %{"email" => address}})
    rescue
      error -> {:raised, error.__struct__}
    end

    test "POST /auth/user/password/reset_request answers a known and an unknown address alike" do
      known = address("known")
      unknown = address("unknown")
      seed_user(known)

      assert_indistinguishable(
        fn -> post_request("/auth/user/password/reset_request", known) end,
        fn -> post_request("/auth/user/password/reset_request", unknown) end,
        [known, unknown]
      )
    end

    test "POST /auth/user/magic_link/request answers a known and an unknown address alike" do
      known = address("known")
      unknown = address("unknown")
      seed_user(known)

      assert_indistinguishable(
        fn -> post_request("/auth/user/magic_link/request", known) end,
        fn -> post_request("/auth/user/magic_link/request", unknown) end,
        [known, unknown]
      )
    end
  end

  describe "the actions behind them" do
    defp request(strategy_name, action, address) do
      strategy = AshAuthentication.Info.strategy!(User, strategy_name)
      AshAuthentication.Strategy.action(strategy, action, %{"email" => address}, [])
    end

    test "a reset request answers :ok for a known and an unknown address" do
      known = address("known")
      seed_user(known)

      assert_indistinguishable(
        fn -> request(:password, :reset_request, known) end,
        fn -> request(:password, :reset_request, address("unknown")) end,
        [known]
      )

      assert :ok = request(:password, :reset_request, known)
    end

    test "a magic link request answers :ok for a known and an unknown address" do
      known = address("known")
      seed_user(known)

      assert_indistinguishable(
        fn -> request(:magic_link, :request, known) end,
        fn -> request(:magic_link, :request, address("unknown")) end,
        [known]
      )

      assert :ok = request(:magic_link, :request, known)
    end

    test "the one difference is the owner's mail: enqueued for a known address, never for a stranger" do
      known = address("known")
      stranger = address("stranger")
      seed_user(known)

      assert :ok = request(:password, :reset_request, stranger)
      assert :ok = request(:magic_link, :request, stranger)
      KilnCMS.DataCase.drain_oban()
      refute_email_sent()

      assert :ok = request(:password, :reset_request, known)
      assert :ok = request(:magic_link, :request, known)

      # Queued, not sent: nothing has left yet, so neither response waited on
      # SMTP. Draining is what delivers it.
      refute_email_sent()
      KilnCMS.DataCase.drain_oban()

      # Drained together, the mails arrive in no fixed order: Oban fetches the
      # :mail queue through UPDATE ... RETURNING, whose row order Postgres does
      # not guarantee. So assert the set (#2617).
      assert_delivered([
        &(&1.subject =~ "Reset your" and &1.to == [{"", known}]),
        &(&1.subject =~ "sign-in link" and &1.to == [{"", known}])
      ])
    end
  end
end
