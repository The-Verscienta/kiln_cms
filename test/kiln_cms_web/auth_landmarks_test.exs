defmodule KilnCMSWeb.AuthLandmarksTest do
  @moduledoc """
  Landmarks, the single `h1`, and `autocomplete` on every auth page (#2162).

  Structural assertions on the dead render only: this is not an axe run, and
  nothing here claims one.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, only: [live: 2, render_patch: 2]
  import Plug.Conn

  alias KilnCMS.Accounts.PendingSignIn
  alias KilnCMS.TwoFactorFixtures

  # The invite-only branch of `sign_in_route` (#2390). `KilnCMSWeb.Router`
  # picks it with `compile_env(:kiln_cms, :registration_enabled)`, so the test
  # build only ever has the open-registration one. This router mounts the other
  # branch's arguments as they stand there: no `register_path`, and the same
  # `live_view`, `layout`, `on_mount` and overrides. Keep the two in step.
  defmodule InviteOnlyRouter do
    use Phoenix.Router
    use AshAuthentication.Phoenix.Router

    scope "/", KilnCMSWeb do
      sign_in_route reset_path: "/reset",
                    auth_routes_prefix: "/auth",
                    live_view: KilnCMSWeb.SignInLive,
                    layout: {KilnCMSWeb.Layouts, :auth},
                    on_mount: [
                      {KilnCMSWeb.AdminAllowlist, :gated},
                      {KilnCMSWeb.LiveUserAuth,
                       [:restore_locale, :assign_current_org, :live_no_user]}
                    ],
                    overrides: [KilnCMSWeb.AuthOverrides]
    end
  end

  # `{path, h1 text}`. The text is the page's `page_title`, so a retitled page
  # changes the heading with it.
  @pages [
    {"/sign-in", "Sign in"},
    {"/register", "Create an account"},
    {"/reset", "Reset your password"},
    {"/password-reset/sometoken", "Reset your password"},
    {"/sign-out", "Sign out"},
    {"/confirm_new_user/sometoken", "Confirm your email"},
    {"/magic_link/sometoken", "Sign in"}
  ]

  defp doc(html), do: LazyHTML.from_document(html)
  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  defp text(doc, selector),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  defp assert_landmarks(doc, h1_text, label) do
    assert count(doc, "h1") == 1, "#{label}: expected exactly one h1"
    assert text(doc, "h1") == h1_text, "#{label}: h1 text"
    assert count(doc, "header") == 1, "#{label}: expected one header"
    assert count(doc, "main") == 1, "#{label}: expected one main"
    assert count(doc, "main#main") == 1, "#{label}: main must be #main"
    assert count(doc, "a[href='#main']") == 1, "#{label}: expected one skip link"
    # The brand row sits in the header, outside <main>, so no content is
    # outside a landmark.
    assert count(doc, "header a.auth-brand") == 1, "#{label}: brand in header"
    assert count(doc, "main header") == 0, "#{label}: header must not be inside main"
  end

  describe "landmarks and one h1 on every auth page" do
    for {path, h1} <- @pages do
      test "GET #{path}", %{conn: conn} do
        html = conn |> get(unquote(path)) |> html_response(200)
        assert_landmarks(doc(html), unquote(h1), unquote(path))
      end
    end

    test "/sign-in/verify, prompt and refused-code re-render", %{conn: conn} do
      {user, _secret} = TwoFactorFixtures.enabled_user()
      {user, token} = TwoFactorFixtures.with_first_factor_token(user)

      blob =
        PendingSignIn.mint_and_hold(:session, KilnCMSWeb.Endpoint, %{
          user
          | __metadata__: Map.put(user.__metadata__, :token, token)
        })

      base =
        conn
        |> put_private(:plug_skip_csrf_protection, true)
        |> init_test_session(%{})
        |> put_session(:pending_2fa, blob)

      prompt = base |> get("/sign-in/verify") |> html_response(200)
      assert_landmarks(doc(prompt), "Two-factor authentication", "verify prompt")

      refused = base |> post("/sign-in/verify", %{"code" => "000000"}) |> html_response(401)
      assert_landmarks(doc(refused), "Two-factor authentication", "verify refused")

      recovery =
        base
        |> post("/sign-in/verify", %{"factor" => "recovery", "code" => "AAAAAAAAAA"})
        |> html_response(401)

      assert_landmarks(doc(recovery), "Two-factor authentication", "verify recovery")
    end
  end

  describe "invite-only sign-in (registration disabled)" do
    # The real router's `:browser` pipeline runs (session, root layout, CSP),
    # then the fixture router answers in its place.
    defp invite_only(conn, path) do
      conn
      |> bypass_through(KilnCMSWeb.Router, [:browser])
      |> get(path)
      |> InviteOnlyRouter.call(InviteOnlyRouter.init([]))
    end

    for {path, h1} <- [{"/sign-in", "Sign in"}, {"/reset", "Reset your password"}] do
      test "GET #{path}", %{conn: conn} do
        html = conn |> invite_only(unquote(path)) |> html_response(200)
        d = doc(html)
        assert_landmarks(d, unquote(h1), "invite-only #{unquote(path)}")
        # The branch under test: nothing links to /register. (The library
        # still renders the register form, hidden, from the strategy alone;
        # the action refuses it when registration is off.)
        refute html =~ ~s(href="/register")
      end
    end

    test "has no /register route", %{conn: conn} do
      assert_raise Phoenix.Router.NoRouteError, fn -> invite_only(conn, "/register") end
    end
  end

  describe "one LiveView, three actions" do
    test "the h1 follows live_patch between sign-in, register and reset", %{conn: conn} do
      {:ok, view, html} = live(conn, "/sign-in")
      assert text(doc(html), "h1") == "Sign in"

      for {path, h1} <- [
            {"/register", "Create an account"},
            {"/reset", "Reset your password"},
            {"/sign-in", "Sign in"}
          ] do
        html = render_patch(view, path)
        d = doc(html)
        assert count(d, "h1") == 1
        assert text(d, "h1") == h1
      end
    end
  end

  describe "autocomplete" do
    # `{path, input id, expected}`. /sign-in, /register and /reset are one page
    # that renders all four forms (the toggles only hide them), so inputs are
    # named by id, not by name.
    @inputs [
      {"/sign-in", "user-password-sign-in-with-password_email", "email"},
      {"/sign-in", "user-password-sign-in-with-password_password", "current-password"},
      {"/sign-in", "user-password-register-with-password_email", "email"},
      {"/sign-in", "user-password-register-with-password_password", "new-password"},
      {"/sign-in", "user-password-register-with-password_password_confirmation", "new-password"},
      {"/sign-in", "user-password-request-password-reset-token_email", "email"},
      {"/register", "user-password-register-with-password_password", "new-password"},
      {"/reset", "user-password-request-password-reset-token_email", "email"},
      {"/password-reset/sometoken", "user-password-reset-password-with-token_password",
       "new-password"},
      {"/password-reset/sometoken",
       "user-password-reset-password-with-token_password_confirmation", "new-password"}
    ]

    for {path, id, expected} <- @inputs do
      test "#{path} ##{id} is #{expected}", %{conn: conn} do
        d = conn |> get(unquote(path)) |> html_response(200) |> doc()
        inputs = LazyHTML.query(d, "input##{unquote(id)}")
        assert Enum.count(inputs) == 1, "no input ##{unquote(id)} on #{unquote(path)}"

        assert inputs |> LazyHTML.attribute("autocomplete") |> List.first() == unquote(expected)
      end
    end

    # The remember-me box and the hidden tokens are left alone, and no other
    # visible text-like input on these pages goes without a hint.
    #
    # Except the magic-link request's email box: the library renders it from
    # `Components.MagicLink`, which `Components.SignIn` names by module with no
    # override to re-point it, so it has no hint yet. Left out by name rather
    # than by a looser selector, so a second gap still fails.
    test "every other email and password input on /sign-in carries autocomplete", %{conn: conn} do
      d = conn |> get("/sign-in") |> html_response(200) |> doc()

      for input <-
            LazyHTML.query(
              d,
              "input[type=email]:not(#user-magic-link-request-magic-link_email), input[type=password]"
            ) do
        assert LazyHTML.attribute(input, "autocomplete") != [],
               "missing autocomplete: #{LazyHTML.to_html(input)}"
      end
    end
  end
end
