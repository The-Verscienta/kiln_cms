defmodule KilnCMSWeb.TwoFactorControllerTest do
  @moduledoc "The second-factor sign-in gate (issue #331)."
  use KilnCMSWeb.ConnCase, async: true

  import Plug.Conn

  alias KilnCMS.Accounts.PendingSignIn
  alias KilnCMS.TwoFactorFixtures
  alias KilnCMSWeb.BearerAuth

  # A fixed secret so the test can compute the matching code.
  @secret :crypto.strong_rand_bytes(20)

  defp enabled_user do
    {user, _secret} = TwoFactorFixtures.enabled_user(secret: @secret)
    user
  end

  # Simulate the post-first-factor state AuthController.success/4 sets: a signed
  # pending token in the session (and skip CSRF for the direct POST).
  defp with_pending(conn, user) do
    {user, token} = TwoFactorFixtures.with_first_factor_token(user)
    with_pending(conn, user, token)
  end

  # A real, stored first-factor JWT rather than a stub, because `mint/4` holds
  # the stored row (#742) and a stub has none — every test here would exercise
  # the "nothing to hold" path and pass with the hold deleted.
  defp with_pending(conn, user, token) do
    blob =
      PendingSignIn.mint_and_hold(:session, KilnCMSWeb.Endpoint, %{
        user
        | __metadata__: Map.put(user.__metadata__, :token, token)
      })

    conn
    |> put_private(:plug_skip_csrf_protection, true)
    |> init_test_session(%{})
    |> put_session(:pending_2fa, blob)
  end

  describe "the prompt page (#1676)" do
    # The page used to be a dark-only inline HTML string: no label on the code
    # field, `lang="en"` over translated copy, and none of the sign-in page's
    # shell. These pin the move into `Layouts.auth/1` and the kit.
    test "renders in the auth layout with a labelled one-time-code field", %{conn: conn} do
      html =
        conn |> with_pending(enabled_user()) |> get(~p"/sign-in/verify") |> html_response(200)

      doc = LazyHTML.from_document(html)

      assert count(doc, "html[lang='en']") == 1
      # `Layouts.auth/1`'s landmark and brand row, over the kit's auth page.
      assert count(doc, "main#main .auth-page .auth-card") == 1
      assert count(doc, "a.auth-brand[href='/']") == 1
      assert doc |> LazyHTML.query("title") |> LazyHTML.text() =~ "Two-factor authentication"

      # A real <label for>, the platform one-time-code hint, a digit keypad.
      assert count(doc, "label.field-label[for='two-factor-code']") == 1

      assert count(
               doc,
               "input#two-factor-code.field-input[name='code'][autocomplete='one-time-code'][inputmode='numeric'][required]"
             ) == 1

      assert count(doc, "#two-factor-code[aria-describedby='two-factor-help']") == 1
      assert count(doc, "#two-factor-form input[name='_csrf_token']") == 1

      # The recovery-code path is a native disclosure with its own labelled,
      # letter-friendly field — base32 cannot be typed on a numeric keypad.
      assert count(doc, "details#two-factor-recovery:not([open])") == 1
      assert count(doc, "label[for='two-factor-recovery-code']") == 1
      assert count(doc, "#two-factor-recovery-code:not([inputmode])") == 1
      assert count(doc, "#two-factor-recovery-form input[name='factor'][value='recovery']") == 1

      # No hard-coded colours, and nothing the browser CSP would have to allow.
      refute html =~ ~s(style="background)
      refute html =~ "#1c1a17"
      refute Regex.match?(~r/<script(?![^>]*\ssrc=)(?![^>]*\snonce=)[^>]*>/, html)
    end

    for {locale, label} <- [
          {"es", "Código de autenticación"},
          {"fr", "Code d&#39;authentification"}
        ] do
      test "takes <html lang> and its copy from the request locale (#{locale})", %{conn: conn} do
        html =
          conn
          |> with_pending(enabled_user())
          |> get("/#{unquote(locale)}/sign-in/verify")
          |> html_response(200)

        assert html |> LazyHTML.from_document() |> count("html[lang='#{unquote(locale)}']") == 1
        assert html =~ unquote(label)
      end
    end

    test "a refused code is announced and tied to the field it refused", %{conn: conn} do
      html =
        conn
        |> with_pending(enabled_user())
        |> post(~p"/sign-in/verify", %{"code" => "000000"})
        |> html_response(401)

      doc = LazyHTML.from_document(html)

      assert count(doc, "#two-factor-error[role='alert']") == 1
      assert count(doc, "#two-factor-code[aria-invalid='true']") == 1

      assert count(doc, "#two-factor-code[aria-describedby='two-factor-help two-factor-error']") ==
               1

      assert count(doc, "details#two-factor-recovery:not([open])") == 1
    end

    test "a refused recovery code reopens the recovery field", %{conn: conn} do
      html =
        conn
        |> with_pending(enabled_user())
        |> post(~p"/sign-in/verify", %{"code" => "AAAA-AAAA", "factor" => "recovery"})
        |> html_response(401)

      doc = LazyHTML.from_document(html)

      assert count(doc, "details#two-factor-recovery[open]") == 1
      assert count(doc, "#two-factor-recovery-code[aria-invalid='true'][autofocus]") == 1
      assert count(doc, "#two-factor-code[aria-invalid]") == 0
    end
  end

  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  test "GET /sign-in/verify without a pending token redirects to sign-in", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/sign-in/verify")) == ~p"/sign-in"
  end

  test "a valid code completes sign-in and clears the pending state", %{conn: conn} do
    user = enabled_user()
    code = TwoFactorFixtures.current_code(@secret)

    conn = conn |> with_pending(user) |> post(~p"/sign-in/verify", %{"code" => code})

    assert redirected_to(conn) == ~p"/editor/overview"
    assert is_nil(get_session(conn, :pending_2fa))
  end

  test "an invalid code is rejected and keeps the user on the prompt", %{conn: conn} do
    user = enabled_user()

    conn = conn |> with_pending(user) |> post(~p"/sign-in/verify", %{"code" => "000000"})

    assert conn.status == 401
    assert conn.resp_body =~ "isn&#39;t valid" or conn.resp_body =~ "isn't valid"
    refute is_nil(get_session(conn, :pending_2fa))
  end

  test "the first-factor token is held across the prompt and released by a code (#742)", %{
    conn: conn
  } do
    # This door has the same shape as the headless one and #742 says so: the JWT
    # is minted AND stored by the time `success/4` learns the account owes a
    # code, so abandoning this prompt used to leave a live token row for weeks.
    #
    # `BearerAuth.user_from_token/1` is the assertion because it asks exactly
    # what the session plug asks — both run
    # `AshAuthentication.TokenResource.Actions.get_token/3` for this jti under
    # the `"user"` purpose, so a session established on a still-held token would
    # be signed out on its very next request.
    user = enabled_user()
    {user, token} = TwoFactorFixtures.with_first_factor_token(user)

    assert {:ok, _} = BearerAuth.user_from_token(token)

    conn = with_pending(conn, user, token)
    assert :error = BearerAuth.user_from_token(token)

    conn = post(conn, ~p"/sign-in/verify", %{"code" => TwoFactorFixtures.current_code(@secret)})
    assert redirected_to(conn) == ~p"/editor/overview"

    assert {:ok, authed} = BearerAuth.user_from_token(token)
    assert authed.id == user.id
  end

  test "an abandoned prompt leaves the first-factor token unusable (#742)", %{conn: conn} do
    user = enabled_user()
    {user, token} = TwoFactorFixtures.with_first_factor_token(user)

    _abandoned = with_pending(conn, user, token)

    refute match?({:ok, _}, BearerAuth.user_from_token(token))
  end

  test "a wrong code does not release the held token (#742)", %{conn: conn} do
    # The blob survives a wrong code deliberately — "that code isn't valid" must
    # not become "start over" — and the hold has to survive with it, or a wrong
    # guess would be a way to unpark the very token the prompt is guarding.
    user = enabled_user()
    {user, token} = TwoFactorFixtures.with_first_factor_token(user)

    conn = conn |> with_pending(user, token) |> post(~p"/sign-in/verify", %{"code" => "000000"})

    assert conn.status == 401
    assert :error = BearerAuth.user_from_token(token)
  end

  describe "recovery codes (#331 phase 2)" do
    alias KilnCMS.Accounts.RecoveryCodes

    defp with_recovery_codes(user) do
      codes = RecoveryCodes.generate()

      user =
        Ash.Seed.update!(user, %{totp_recovery_hashes: Enum.map(codes, &RecoveryCodes.hash/1)})

      {user, codes}
    end

    test "a recovery code completes sign-in and is burned on use", %{conn: conn} do
      {user, [code | _]} = with_recovery_codes(enabled_user())

      conn2 = conn |> with_pending(user) |> post(~p"/sign-in/verify", %{"code" => code})
      assert redirected_to(conn2) == ~p"/editor/overview"

      # One fewer unused code, and the same code never works again.
      reloaded = KilnCMS.Accounts.get_user!(user.id, authorize?: false)
      assert length(reloaded.totp_recovery_hashes) == RecoveryCodes.count() - 1

      retry =
        build_conn()
        |> unique_ip()
        |> with_pending(user)
        |> post(~p"/sign-in/verify", %{"code" => code})

      assert retry.status == 401
    end

    test "a recovery code is accepted case- and format-insensitively", %{conn: conn} do
      {user, [code | _]} = with_recovery_codes(enabled_user())
      variant = code |> String.downcase() |> String.replace("-", " ")

      conn = conn |> with_pending(user) |> post(~p"/sign-in/verify", %{"code" => variant})
      assert redirected_to(conn) == ~p"/editor/overview"
    end

    test "an unknown recovery code is rejected", %{conn: conn} do
      {user, _codes} = with_recovery_codes(enabled_user())

      conn = conn |> with_pending(user) |> post(~p"/sign-in/verify", %{"code" => "AAAA-AAAA"})
      assert conn.status == 401
    end
  end
end
