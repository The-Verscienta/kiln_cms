defmodule KilnCMSWeb.RememberMeTest do
  @moduledoc """
  The "Remember me" checkbox, end to end (#699).

  Before this the strategy was declared but half-wired: no preparation minted a
  token, so `remember_me_field/1` returned `nil` and the checkbox never rendered,
  and the `:browser` pipeline had no plug to read the cookie back. The styling
  for the field existed, which is what made it read as a working feature.

  What is asserted here is the *shape* of the credential as much as the flow.
  `KilnCMSWeb.SessionCookieTest` pins the production name; this pins that the
  cookie is written and deleted with the attributes that name requires, and that
  the round trip actually signs someone in — a cookie whose attributes do not
  match is not a weakened control, it is a browser silently discarding it.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User

  @password "password123456"

  # Whatever this build compiled with — the tests below assert relationships
  # between the written cookie and the configured name, not a literal.
  @cookie to_string(
            KilnCMSWeb.SessionCookie.remember_me_key(
              Application.compile_env(:kiln_cms, :secure_session_cookie, false)
            )
          )

  defp account do
    email = "remember-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })
  end

  # A user carrying the auth token `store_in_session/2` needs — a seeded record
  # has no token metadata, so it cannot stand in for one that actually signed in.
  defp signed_in_user do
    user = account()
    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => to_string(user.email),
        "password" => @password
      })

    user
  end

  defp sign_in(conn, user, params) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> post(~p"/auth/user/password/sign_in", %{
      "user" => Map.merge(%{"email" => to_string(user.email), "password" => @password}, params)
    })
  end

  describe "the checkbox" do
    test "renders on the sign-in page", %{conn: conn} do
      # It renders only when the sign-in action carries
      # `MaybeGenerateTokenPreparation` — `remember_me_field/1` looks for it and
      # returns `nil` otherwise, which is why the field was invisible while the
      # overrides in `KilnCMSWeb.AuthOverrides` styled it.
      {:ok, _view, html} = live(conn, ~p"/sign-in")

      assert html =~ "remember_me"
      assert html =~ "Remember me"
    end
  end

  describe "signing in with it ticked" do
    test "writes the cookie with the attributes its name requires", %{conn: conn} do
      conn = sign_in(conn, account(), %{"remember_me" => "true"})

      assert %{value: token} = cookie = conn.resp_cookies[@cookie]
      assert is_binary(token) and token != ""

      # `__Host-` is honoured only at `Path=/` with no `Domain`, and only
      # alongside `Secure` — the three the browser checks before it will store
      # the cookie at all. `secure` tracks the same flag the name does, so on a
      # plain-HTTP build the bare name is paired with a non-Secure cookie.
      assert cookie.path == "/"
      refute Map.has_key?(cookie, :domain)
      assert cookie.secure == Application.get_env(:kiln_cms, :secure_session_cookie, false)

      assert cookie.http_only
      assert cookie.same_site == "Lax"
      assert cookie.max_age == 30 * 24 * 60 * 60
    end

    test "through the LiveView form, which is the path a browser actually takes", %{conn: conn} do
      user = account()
      {:ok, view, _html} = live(conn, ~p"/sign-in")

      # Not the same path as the POST above, and the one that matters:
      # `sign_in_tokens_enabled?` is on, so the form sets
      # `skip_remember_me_token_generation`, mints nothing on the password
      # action, and forwards the ticked box as a query param to
      # `:sign_in_with_token`. That action is where the token is issued — which
      # is why the preparation has to be declared on both.
      {:error, {:redirect, %{to: exchange}}} =
        view
        |> form("#user-password-sign-in-with-password",
          user: %{email: to_string(user.email), password: @password, remember_me: "true"}
        )
        |> render_submit()

      assert exchange =~ "remember_me=true"

      exchanged = build_conn() |> Phoenix.ConnTest.init_test_session(%{}) |> get(exchange)

      assert %{value: token} = exchanged.resp_cookies[@cookie]
      assert is_binary(token) and token != ""
      assert exchanged.resp_cookies[@cookie].max_age == 30 * 24 * 60 * 60
    end

    test "the cookie alone signs the visitor in on a later request", %{conn: conn} do
      user = account()
      token = sign_in(conn, user, %{"remember_me" => "true"}).resp_cookies[@cookie].value

      # No session at all — which is the whole point, and the reason this cookie
      # is the better prize for a sibling-origin attacker: planting one signs
      # the victim in as the attacker without needing an existing session on the
      # target host.
      signed_in =
        build_conn()
        |> Plug.Test.put_req_cookie(@cookie, token)
        |> get(~p"/")

      assert signed_in.assigns.current_user.id == user.id
    end
  end

  describe "signing in without it" do
    test "writes no remember-me cookie at all", %{conn: conn} do
      conn = sign_in(conn, account(), %{})

      refute Map.has_key?(conn.resp_cookies, @cookie)
    end
  end

  describe "signing out" do
    test "deletes the cookie, so it cannot sign the user straight back in", %{conn: conn} do
      user = account()
      token = sign_in(conn, user, %{"remember_me" => "true"}).resp_cookies[@cookie].value

      out =
        build_conn()
        |> Plug.Test.put_req_cookie(@cookie, token)
        |> Phoenix.ConnTest.init_test_session(%{})
        |> delete(~p"/sign-out")

      # A deletion is a `Set-Cookie` carrying no value and an expiry in the past,
      # and the browser only replaces a cookie whose name, domain and path all
      # match — so the attributes matter here exactly as much as on the way in.
      # `sign_in_with_remember_me` runs ahead of `load_from_session`, so a
      # deletion that missed would sign a signed-out user back in for 30 days.
      deleted = out.resp_cookies[@cookie]

      assert deleted.max_age == 0
      refute Map.has_key?(deleted, :value)
      assert deleted.path == "/"
      assert deleted.secure == Application.get_env(:kiln_cms, :secure_session_cookie, false)
    end
  end

  describe "the read plug" do
    test "does not override a session that is already signed in", %{conn: conn} do
      remembered = account()
      current = signed_in_user()

      token = sign_in(conn, remembered, %{"remember_me" => "true"}).resp_cookies[@cookie].value

      signed_in =
        build_conn()
        |> Plug.Test.put_req_cookie(@cookie, token)
        |> Phoenix.ConnTest.init_test_session(%{})
        |> AshAuthentication.Plug.Helpers.store_in_session(current)
        |> get(~p"/")

      # The plug sits ahead of `load_from_session` so a remembered visitor is
      # resolved within the same request. That ordering is only safe because it
      # is a no-op when the session already names someone — otherwise a stale
      # cookie would silently swap the acting user.
      assert signed_in.assigns.current_user.id == current.id
    end

    test "an invalid token is discarded rather than trusted", %{conn: conn} do
      signed_in =
        conn
        |> Plug.Test.put_req_cookie(@cookie, "not.a.jwt")
        |> get(~p"/")

      assert is_nil(signed_in.assigns[:current_user])
    end
  end
end
