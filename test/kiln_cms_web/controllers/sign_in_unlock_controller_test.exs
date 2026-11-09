defmodule KilnCMSWeb.SignInUnlockControllerTest do
  @moduledoc """
  The sign-in unlock pages (#2250): asking for a link at `/sign-in/unlock`, and
  the page the emailed link opens at `/auth/unlock/:unlock_token`.

  `async: false`: tests lower `AccountThrottle`'s budget, set `:console_host`
  and tighten the `:auth` rate limit with `Application.put_env/3`, all
  node-wide.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.SignInUnlock
  alias KilnCMS.Accounts.User
  alias KilnCMS.RateLimitHelpers
  alias KilnCMSWeb.Tenant

  @password "password123456"
  @budget 3

  setup do
    original = Application.get_env(:kiln_cms, AccountThrottle, [])
    Application.put_env(:kiln_cms, AccountThrottle, Keyword.put(original, :budget, @budget))
    on_exit(fn -> Application.put_env(:kiln_cms, AccountThrottle, original) end)
    :ok
  end

  defp email, do: "unlock-page-#{System.unique_integer([:positive])}@example.com"

  defp paused_user! do
    address = email()

    user =
      Ash.Seed.seed!(User, %{
        email: address,
        hashed_password: Bcrypt.hash_pwd_salt(@password),
        confirmed_at: DateTime.utc_now(),
        role: :editor
      })

    Enum.each(1..@budget, fn _ -> AccountThrottle.consume(address) end)
    {user, address}
  end

  # The link in the one unlock mail sent to `address`.
  defp mailed_link(address) do
    KilnCMS.DataCase.drain_oban()

    assert_email_sent(fn mail ->
      send(self(), {:body, mail.html_body})
      mail.to == [{"", address}]
    end)

    assert_received {:body, body}
    [link] = Regex.run(~r{href="([^"]+/auth/unlock/[^"]+)"}, body, capture: :all_but_first)
    URI.parse(link)
  end

  defp member!(user, site) do
    Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
      organization_id: site.id,
      user_id: user.id,
      role: :editor
    })
  end

  defp token(%URI{path: "/auth/unlock/" <> token}), do: token

  defp ask(conn, address), do: post(conn, ~p"/sign-in/unlock", %{"email" => address})

  describe "asking for a link" do
    test "the form has a labelled email field and no script", %{conn: conn} do
      html = conn |> get(~p"/sign-in/unlock") |> html_response(200)

      assert html =~ ~s(id="sign-in-unlock-form")
      assert html =~ ~s(name="email")
      assert html =~ "Email me an unlock link"
      refute html =~ "<script>"
    end

    test "a blank, whitespace-only or non-string address is asked for again", %{conn: conn} do
      for email <- ["", "   ", %{"a" => "b"}, ["x@example.com"]] do
        html = conn |> post(~p"/sign-in/unlock", %{"email" => email}) |> html_response(422)
        assert html =~ "Enter the email address you sign in with."
      end

      html = conn |> post(~p"/sign-in/unlock", %{}) |> html_response(422)
      assert html =~ "Enter the email address you sign in with."
    end

    test "a site's non-member is mailed nothing there", %{conn: conn} do
      site = KilnCMS.OrgFixtures.org("unlock-stranger")
      {_user, address} = paused_user!()

      conn |> org_conn(site) |> ask(address) |> html_response(200)

      KilnCMS.DataCase.drain_oban()
      refute_email_sent()
      assert AccountThrottle.sign_in_paused?(address)
    end

    for {locale, copy} <- [
          {"es", "Envíame un enlace de desbloqueo"},
          {"fr", "Envoyez-moi un lien de déblocage"}
        ] do
      test "is translated (#{locale})", %{conn: conn} do
        html = conn |> get("/#{unquote(locale)}/sign-in/unlock") |> html_response(200)
        assert html =~ unquote(copy)
      end
    end

    test "the mailed link opens on the request's site host", %{conn: conn} do
      site = KilnCMS.OrgFixtures.org("unlock-host")
      {user, address} = paused_user!()
      member!(user, site)

      conn |> org_conn(site) |> ask(address) |> html_response(200)

      link = mailed_link(address)
      assert link.host == "#{site.slug}.#{Tenant.base_host()}"
    end

    test "with the console gate on, the link opens on the site's console host", %{conn: conn} do
      previous = Application.get_env(:kiln_cms, :console_host)
      console = "console#{System.unique_integer([:positive])}.#{Tenant.base_host()}"
      Application.put_env(:kiln_cms, :console_host, console)
      KilnCMS.Cache.Hosts.clear()

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:kiln_cms, :console_host),
          else: Application.put_env(:kiln_cms, :console_host, previous)

        KilnCMS.Cache.Hosts.clear()
      end)

      site = KilnCMS.OrgFixtures.org("unlock-console")
      {user, address} = paused_user!()
      member!(user, site)
      host = "#{site.slug}.#{console}"

      %{conn | host: host} |> ask(address) |> html_response(200)

      link = mailed_link(address)
      assert link.host == host

      # And there it is served, and redeems.
      assert %{conn | host: host} |> get(link.path) |> html_response(200) =~ "Lift the pause"
      assert redirected_to(post(%{build_conn() | host: host}, link.path)) == ~p"/sign-in"
    end

    test "is charged to the per-IP :auth bucket" do
      RateLimitHelpers.restore_limits_on_exit()
      # A window no test run straddles: `:auth` counts in epoch-aligned windows.
      RateLimitHelpers.put_limit(:auth, 2, :timer.hours(24 * 365 * 100))
      address = RateLimitHelpers.client_address()

      from_client = fn ->
        build_conn()
        |> Plug.Test.put_peer_data(%{address: address, port: 111, ssl_cert: nil})
        |> Map.put(:remote_ip, address)
      end

      assert from_client.() |> get(~p"/sign-in/unlock") |> html_response(200)
      assert from_client.() |> ask(email()) |> html_response(200)
      assert from_client.() |> ask(email()) |> response(429)
    end
  end

  describe "opening the link" do
    test "a GET spends nothing, however often, and the POST then redeems", %{conn: conn} do
      {_user, address} = paused_user!()
      conn |> ask(address)
      link = mailed_link(address)

      # A mail scanner following the link, twice.
      for _ <- 1..2 do
        html = build_conn() |> get(link.path) |> html_response(200)
        assert html =~ "Lift the pause"
        assert html =~ ~s(action="#{link.path}")
      end

      assert AccountThrottle.sign_in_paused?(address)

      conn = post(build_conn(), link.path)
      assert redirected_to(conn) == ~p"/sign-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "The sign-in pause on your account is lifted."

      refute AccountThrottle.sign_in_paused?(address)
    end

    test "the GET page is the same for a real and a made-up token", %{conn: conn} do
      {_user, address} = paused_user!()
      ask(conn, address)
      real = mailed_link(address) |> token()

      page = fn token ->
        build_conn()
        |> get(~p"/auth/unlock/#{token}")
        |> html_response(200)
        |> String.replace(token, "<TOKEN>")
        |> KilnCMS.EnumerationAssertions.observe([])
      end

      assert page.(real) == page.("made-up-token")
    end

    test "redeeming signs nobody in", %{conn: conn} do
      {_user, address} = paused_user!()
      ask(conn, address)
      link = mailed_link(address)

      conn = post(build_conn(), link.path)
      assert redirected_to(conn) == ~p"/sign-in"
      assert get_session(conn, "user_token") == nil
      assert get_session(conn, :pending_2fa) == nil
      assert conn.resp_cookies |> Map.keys() |> Enum.all?(&(not String.contains?(&1, "remember")))

      # The console still sends this browser to sign in.
      assert conn |> recycle() |> get(~p"/editor") |> redirected_to() =~ "/sign-in"
    end

    test "every refusal is one page that offers a new link", %{conn: conn} do
      {_user, address} = paused_user!()
      ask(conn, address)
      link = mailed_link(address)
      assert redirected_to(post(build_conn(), link.path)) == ~p"/sign-in"

      used = build_conn() |> post(link.path) |> html_response(422)
      forged = build_conn() |> post(~p"/auth/unlock/made-up-token") |> html_response(422)

      for html <- [used, forged] do
        assert html =~ "This link has already been used or is no longer valid."
        assert html =~ ~s(href="/sign-in/unlock")
      end
    end

    test "on another site's host it is refused, and still works on its own", %{conn: conn} do
      other = KilnCMS.OrgFixtures.org("unlock-wrong")
      {_user, address} = paused_user!()
      ask(conn, address)
      link = mailed_link(address)

      assert build_conn() |> org_conn(other) |> post(link.path) |> html_response(422) =~
               "no longer valid"

      assert AccountThrottle.sign_in_paused?(address)
      assert redirected_to(post(build_conn(), link.path)) == ~p"/sign-in"
      refute AccountThrottle.sign_in_paused?(address)
    end

    test "after an unlock the password signs in through the sign-in page", %{conn: conn} do
      {_user, address} = paused_user!()
      ask(conn, address)
      assert redirected_to(post(build_conn(), mailed_link(address).path)) == ~p"/sign-in"

      assert {:ok, %User{}} =
               AshAuthentication.Strategy.action(
                 AshAuthentication.Info.strategy!(User, :password),
                 :sign_in,
                 %{"email" => address, "password" => @password},
                 []
               )
    end
  end

  describe "the sign-in page" do
    test "always links here, without saying an account is paused", %{conn: conn} do
      {_user, address} = paused_user!()
      {:ok, view, html} = live(conn, ~p"/sign-in")

      assert has_element?(view, ~s(#sign-in-unlock-link a[href="/sign-in/unlock"]))
      assert html =~ "Paused after too many attempts?"

      html =
        view
        |> form("form[action='/auth/user/password/sign_in']",
          user: %{email: address, password: @password}
        )
        |> render_submit()

      refute html =~ ~r/locked/i
      assert has_element?(view, "#sign-in-unlock-link")
    end

    test "the registration and reset pages do not", %{conn: conn} do
      for path <- [~p"/register", ~p"/reset"] do
        {:ok, view, _html} = live(build_conn(), path)
        refute has_element?(view, "#sign-in-unlock-link")
      end

      _ = conn
    end
  end

  test "the owner alert links to the unlock page, never with a token" do
    {user, address} = paused_user!()
    :ok = KilnCMS.Accounts.SignInAlert.account_locked(address)
    KilnCMS.DataCase.drain_oban()

    assert_email_sent(fn mail ->
      assert mail.html_body =~ "/sign-in/unlock\""
      refute mail.html_body =~ "/auth/unlock/"
      mail.to == [{"", address}]
    end)

    # Nothing was minted for it.
    subject = AshAuthentication.user_to_subject(user)
    purpose = SignInUnlock.purpose()

    assert KilnCMS.Repo.aggregate(
             from(t in "tokens", where: t.subject == ^subject and t.purpose == ^purpose),
             :count
           ) == 0
  end
end
