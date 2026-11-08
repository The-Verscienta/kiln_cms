defmodule KilnCMSWeb.EnumerationRegistrationTest do
  @moduledoc """
  Registering does not say whether an address already has an account (#2255).

  Before this, a known address failed with "has already been taken" (the form)
  or "Incorrect email or password" (the POST) while an unknown one succeeded and
  was signed straight in, so the register form answered "does this address have
  an account?" for anyone who asked. Now both get one sentence and no session; a
  known address gets no row and its owner is mailed instead.

  Asserted here: the browser form (a LiveView event over `/live`), the POST
  behind it, and the work each side does (one bcrypt hash apiece, so the clock
  tells nothing either).

  `async: false`: the registration-disabled and mail-budget cases flip
  `Application` env that every other test would inherit.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.EnumerationAssertions
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.User

  @password "password123456"
  @sentence "Check your email - we have sent instructions for what to do next."

  defp address(tag), do: "#{tag}-#{System.unique_integer([:positive])}@example.com"

  defp seed_user(address) do
    Ash.Seed.seed!(User, %{
      email: address,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })
  end

  defp users_named(address),
    do: User |> Ash.read!(authorize?: false) |> Enum.count(&(to_string(&1.email) == address))

  defp submit_register(conn, address, password \\ @password) do
    {:ok, view, _html} = live(conn, ~p"/register")

    view
    |> form("form[action='/auth/user/password/register']",
      user: %{email: address, password: password, password_confirmation: password}
    )
    |> render_submit()

    # The flash arrives as a message to the view; render after it.
    {render(view), view}
  end

  defp post_register(address) do
    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> post(~p"/auth/user/password/register", %{
      "user" => %{
        "email" => address,
        "password" => @password,
        "password_confirmation" => @password
      }
    })
  end

  defp register_action(address) do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    AshAuthentication.Strategy.action(
      strategy,
      :register,
      %{"email" => address, "password" => @password, "password_confirmation" => @password},
      []
    )
  end

  defp readable({:error, error}),
    do:
      {:error,
       for(e <- error.errors, do: {e.__struct__, Map.get(e, :field), Exception.message(e)})}

  defp readable(other), do: other

  describe "the register form, the LiveView submit" do
    test "a known and an unknown address render the same page", %{conn: conn} do
      known = address("known")
      unknown = address("unknown")
      seed_user(known)

      html =
        assert_indistinguishable(
          fn -> conn |> submit_register(known) |> elem(0) end,
          fn -> build_conn() |> submit_register(unknown) |> elem(0) end,
          [known, unknown]
        )

      # Pinned, so "equal" cannot mean "equally empty".
      assert html =~ @sentence
      refute html =~ "already been taken"
    end

    test "neither address is signed in or redirected", %{conn: conn} do
      known = address("known")
      unknown = address("unknown")
      seed_user(known)

      {_html, known_view} = submit_register(conn, known)
      {_html, unknown_view} = submit_register(build_conn(), unknown)

      # `render_submit` returns a redirect tuple when the view navigates away;
      # a view still alive and rendering the form is one that did not.
      assert render(known_view) =~ "Register"
      assert render(unknown_view) =~ "Register"
    end

    test "a known address creates no row; an unknown one creates exactly one", %{conn: conn} do
      known = address("known")
      unknown = address("unknown")
      seed_user(known)

      submit_register(conn, known)
      submit_register(build_conn(), unknown)

      assert users_named(known) == 1
      assert users_named(unknown) == 1
    end

    test "a real validation error is still shown, alike for both", %{conn: conn} do
      known = address("known")
      unknown = address("unknown")
      seed_user(known)

      html =
        assert_indistinguishable(
          fn -> conn |> submit_register(known, "short") |> elem(0) end,
          fn -> build_conn() |> submit_register(unknown, "short") |> elem(0) end,
          [known, unknown]
        )

      refute html =~ @sentence
      assert users_named(unknown) == 0
    end
  end

  describe "the register form, the POST behind it" do
    test "a known and an unknown address redirect alike, with one flash" do
      known = address("known")
      unknown = address("unknown")
      seed_user(known)

      seen =
        assert_indistinguishable(
          fn -> post_register(known) end,
          fn -> post_register(unknown) end,
          [known, unknown]
        )

      assert seen.status == 302
      assert seen.headers == [{"location", "/sign-in"}]
      assert seen.flash == %{"info" => @sentence}
    end

    test "neither is signed in" do
      known = address("known")
      unknown = address("unknown")
      seed_user(known)

      for conn <- [post_register(known), post_register(unknown)] do
        refute Plug.Conn.get_session(conn, "user_token")
        refute conn.assigns[:current_user]
      end
    end
  end

  describe "the work behind it" do
    test "a known and an unknown address each pay for exactly one bcrypt hash" do
      known = address("known")
      seed_user(known)

      {_, known_calls} =
        count_calls(fn -> register_action(known) end, [{Bcrypt, :hash_pwd_salt, 2}])

      {_, unknown_calls} =
        count_calls(fn -> register_action(address("unknown")) end, [{Bcrypt, :hash_pwd_salt, 2}])

      assert known_calls == unknown_calls
      assert known_calls == %{{Bcrypt, :hash_pwd_salt, 2} => 1}
    end

    test "the action itself refuses a known address with a recognisable error, and creates nothing" do
      known = address("known")
      seed_user(known)

      assert {:error, error} = register_action(known)
      assert KilnCMS.Accounts.Errors.AlreadyRegistered.in?(error)
      assert users_named(known) == 1
    end
  end

  describe "the one permitted difference: mail" do
    test "the owner of a known address is told, a new address is asked to confirm" do
      known = address("known")
      unknown = address("unknown")
      seed_user(known)

      submit_register(build_conn(), known)
      submit_register(build_conn(), unknown)
      KilnCMS.DataCase.drain_oban()

      assert_email_sent(fn email ->
        email.subject =~ "Someone tried to create" and email.to == [{"", known}]
      end)

      assert_email_sent(fn email ->
        email.subject =~ "Confirm your email" and email.to == [{"", unknown}]
      end)

      # Exactly one mail each: nothing confirmable went to the owner, nothing
      # accusatory to the stranger.
      refute_email_sent()
    end

    test "the notice carries no token, only the sign-in and reset pages" do
      known = address("known")
      seed_user(known)

      submit_register(build_conn(), known)
      KilnCMS.DataCase.drain_oban()

      assert_email_sent(fn email ->
        email.html_body =~ "/sign-in" and email.html_body =~ "/reset" and
          not (email.html_body =~ "confirm_new_user")
      end)
    end

    test "the notice respects the per-address mail budget, with no change to the response" do
      previous = Application.get_env(:kiln_cms, AccountThrottle, [])

      Application.put_env(:kiln_cms, AccountThrottle, Keyword.merge(previous, mail_budget: 1))
      on_exit(fn -> Application.put_env(:kiln_cms, AccountThrottle, previous) end)

      known = address("known")
      seed_user(known)
      on_exit(fn -> AccountThrottle.reset(known) end)

      first = post_register(known)
      second = post_register(known)
      KilnCMS.DataCase.drain_oban()

      assert observe(first, [known]) == observe(second, [known])

      assert_email_sent(subject: ~r/Someone tried/)
      refute_email_sent()
    end
  end

  describe "registration switched off" do
    setup do
      previous = Application.get_env(:kiln_cms, :registration_enabled)
      Application.put_env(:kiln_cms, :registration_enabled, false)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:kiln_cms, :registration_enabled),
          else: Application.put_env(:kiln_cms, :registration_enabled, previous)
      end)
    end

    test "a known and an unknown address are refused alike, and nobody is mailed" do
      known = address("known")
      unknown = address("unknown")
      seed_user(known)

      # An Ash error carries a stacktrace and ids that differ between any two
      # calls, so what is compared is what a caller can read out of it.
      assert_indistinguishable(
        fn -> known |> register_action() |> readable() end,
        fn -> unknown |> register_action() |> readable() end,
        [known, unknown]
      )

      assert {:error, error} = register_action(unknown)
      refute KilnCMS.Accounts.Errors.AlreadyRegistered.in?(error)
      assert Exception.message(error) =~ "self-registration is disabled"

      assert users_named(unknown) == 0
      assert users_named(known) == 1
      KilnCMS.DataCase.drain_oban()
      refute_email_sent()
    end
  end
end
