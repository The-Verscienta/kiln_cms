defmodule KilnCMSWeb.TwoFactorSetupLiveTest do
  @moduledoc """
  `/account/two-factor` (#2247): setting up a second factor, for every tier,
  with the email proof a held password session must give first (owner
  decision 1b), the grace-period "Not now", the reader's billing and export
  (decision 4), the recovery-code replacement, and `return_to`.

  Each test signs a viewer in on its own site's host, with the session's
  sign-in marker (`KilnCMSWeb.SignInMarker`) saying how. The site requires
  everyone with no grace, from long before the account was made, unless the
  test says otherwise. Demo mode, which needs `Application.put_env`, is
  `TwoFactorSetupLiveDemoTest` below.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import KilnCMS.OrgFixtures, only: [org: 1]
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Totp
  alias KilnCMS.Accounts.User

  @moduletag :capture_log

  @password "password123456"
  @long_ago ~U[2026-01-01 00:00:00.000000Z]

  def policy!(site, required_for, opts \\ []) do
    since = Keyword.get(opts, :since, @long_ago)

    Ash.Seed.seed!(KilnCMS.CMS.SiteSecondFactorPolicy, %{
      org_id: site.id,
      required_for: required_for,
      grace_days: Keyword.get(opts, :grace_days, 0),
      admin_required_since: since,
      editor_required_since: since,
      viewer_required_since: since,
      policy_changed_at: since
    })

    KilnCMS.Cache.bust_second_factor_policy(site.id)
    site
  end

  def member!(user, site, role \\ :viewer) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: site.id,
      user_id: user.id,
      role: role,
      inserted_at: @long_ago
    })

    user
  end

  def seed_user(attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "tfs-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: :viewer,
          inserted_at: @long_ago
        },
        attrs
      )
    )
  end

  # Signed in as `user` on `site`'s host. `method` is what the session's
  # marker says it signed in with; `nil` leaves no marker (a remember-me or
  # pre-upgrade session).
  def signed_in(conn, user, site, method, extra_session \\ %{}) do
    {:ok, user} =
      User
      |> AshAuthentication.Info.strategy!(:password)
      |> AshAuthentication.Strategy.action(
        :sign_in,
        %{"email" => to_string(user.email), "password" => @password},
        []
      )

    {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(user.__metadata__.token)

    marker =
      if method, do: %{"sign_in" => %{"jti" => jti, "method" => method}}, else: %{}

    conn
    |> org_conn(site)
    |> Phoenix.ConnTest.init_test_session(Map.merge(marker, extra_session))
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp held_site, do: "tfs" |> org() |> policy!(:everyone)

  defp emailed_code do
    assert_email_sent(fn email ->
      [_, code] = Regex.run(~r/<strong>(\d{6})<\/strong>/, email.html_body)
      send(self(), {:code, code})
    end)

    assert_received {:code, code}
    code
  end

  defp prove(view) do
    view |> element("#send-proof-code") |> render_click()
    render_async(view, 2_000)
    code = emailed_code()
    refute render(view) =~ code

    view |> form("#proof-code-form", %{"code" => code}) |> render_submit()
    code
  end

  defp enrol_app(view, user) do
    view |> element("#start-totp") |> render_click()
    staged = Ash.get!(User, user.id, authorize?: false)
    code = Totp.code_at(staged.totp_pending_secret, System.system_time(:second))
    view |> form("#confirm-totp-form", %{"code" => code}) |> render_submit()
  end

  defp reload(user), do: Ash.get!(User, user.id, authorize?: false)

  defp proof_recorded(user) do
    KilnCMS.Repo.all(
      from(e in "security_events",
        where: e.target_id == type(^user.id, :binary_id) and e.type == "second_factor_enrolled",
        select: e.metadata
      )
    )
  end

  describe "where nothing is required" do
    test "a viewer enrolls, and Continue goes back", %{conn: conn} do
      site = org("tfs-free")
      user = seed_user() |> member!(site)

      {:ok, view, html} =
        conn
        |> signed_in(user, site, "password")
        |> live(~p"/account/two-factor?return_to=/membership")

      refute html =~ "two-factor-proof"
      enrol_app(view, user)

      assert reload(user).totp_confirmed_at
      assert has_element?(view, "[data-role=recovery-codes]")
      assert view |> element("#two-factor-continue") |> render() =~ ~s(href="/membership")
    end

    test "an external return_to falls back to the account page", %{conn: conn} do
      site = org("tfs-return")
      user = seed_user() |> member!(site)

      for target <- ["https://evil.example/x", "//evil.example/x", "javascript:alert(1)"] do
        {:ok, view, _html} =
          conn
          |> signed_in(user, site, "password")
          |> live(~p"/account/two-factor?#{[return_to: target]}")

        assert view |> element("#two-factor-continue") |> render() =~ ~s(href="/account"),
               target
      end
    end
  end

  describe "a held password session" do
    test "must confirm the emailed code before the factors open", %{conn: conn} do
      site = held_site()
      user = seed_user() |> member!(site)

      {:ok, view, html} =
        conn |> signed_in(user, site, "password") |> live(~p"/account/two-factor")

      assert html =~ "requires two-step sign-in for your role"
      assert has_element?(view, "#two-factor-proof")
      assert has_element?(view, "#start-totp[disabled]")

      # A forged click does not get past it either.
      render_click(view, "start_totp", %{})
      refute has_element?(view, "#confirm-totp-form")
    end

    test "proves the code, then enrolls; the proof is recorded", %{conn: conn} do
      site = held_site()
      user = seed_user() |> member!(site)

      {:ok, view, _html} =
        conn |> signed_in(user, site, "password") |> live(~p"/account/two-factor")

      prove(view)
      refute has_element?(view, "#two-factor-proof")

      enrol_app(view, user)
      assert reload(user).totp_confirmed_at
      assert proof_recorded(user) == [%{"kind" => "totp", "proof" => "email"}]
      assert has_element?(view, "#two-factor-continue")
    end

    test "editors and administrators enroll the same way; Continue defaults to the console", %{
      conn: conn
    } do
      for role <- [:editor, :admin] do
        site = held_site()
        user = seed_user(%{role: role}) |> member!(site, role)

        {:ok, view, _html} =
          conn |> signed_in(user, site, "password") |> live(~p"/account/two-factor")

        assert has_element?(view, "#two-factor-proof"), "#{role}"
        prove(view)
        enrol_app(view, user)

        assert reload(user).totp_confirmed_at, "#{role}"

        assert view |> element("#two-factor-continue") |> render() =~
                 ~s(href="/editor/overview")
      end
    end

    test "a code is good once", %{conn: conn} do
      site = held_site()
      user = seed_user() |> member!(site)

      {:ok, view, _html} =
        conn |> signed_in(user, site, "password") |> live(~p"/account/two-factor")

      code = prove(view)

      assert render_hook(view, "verify_proof_code", %{"code" => code}) =~
               "That code isn&#39;t valid"
    end

    test "events missing their code change nothing and crash nothing", %{conn: conn} do
      site = held_site()
      user = seed_user() |> member!(site)

      {:ok, view, _html} =
        conn |> signed_in(user, site, "password") |> live(~p"/account/two-factor")

      view |> element("#send-proof-code") |> render_click()
      render_async(view, 2_000)
      _code = emailed_code()

      assert render_hook(view, "verify_proof_code", %{}) =~ "That code isn&#39;t valid"

      assert render_hook(view, "verify_proof_code", %{"code" => 123_456}) =~
               "That code isn&#39;t valid"

      assert render_hook(view, "confirm_totp", %{})
      assert render_hook(view, "confirm_totp", %{"code" => nil})
      assert has_element?(view, "#two-factor-proof")
      refute reload(user).totp_confirmed_at
    end

    test "a site that holds nothing still asks, when another site holds the account", %{
      conn: conn
    } do
      held = held_site()
      free = org("tfs-free-host")
      user = seed_user() |> member!(held) |> member!(free)

      {:ok, view, _html} =
        conn |> signed_in(user, free, "password") |> live(~p"/account/two-factor")

      assert has_element?(view, "#two-factor-proof")
    end

    test "a confirm without the proof is refused by the action, page bypassed", %{conn: conn} do
      site = held_site()
      user = seed_user() |> member!(site)

      {:ok, view, _html} =
        conn |> signed_in(user, site, "password") |> live(~p"/account/two-factor")

      # The page never showed the form; a client sends the event anyway, over
      # a secret it staged itself.
      {:ok, staged} = Accounts.setup_totp(user, %{}, actor: user)
      code = Totp.code_at(staged.totp_pending_secret, System.system_time(:second))

      assert render_hook(view, "confirm_totp", %{"code" => code}) =~
               "Confirm your email address before adding a second factor."

      refute reload(user).totp_confirmed_at
      assert proof_recorded(user) == []
    end

    test "with no sign-in marker (remember-me, or older) must prove too", %{conn: conn} do
      site = held_site()
      user = seed_user() |> member!(site)

      {:ok, view, _html} = conn |> signed_in(user, site, nil) |> live(~p"/account/two-factor")

      assert has_element?(view, "#two-factor-proof")
    end

    test "a transient relay failure does not skip the proof", %{conn: conn} do
      site = held_site()
      user = seed_user() |> member!(site)

      relay =
        KilnCMS.CMS.save_site_mail_relay!(
          %{host: "smtp.example.com", port: 587, from_email: "news@site.example"},
          tenant: site,
          authorize?: false
        )

      # Resolves somewhere private now: held for a retry, not a missing relay.
      {1, _} =
        KilnCMS.Repo.update_all(
          from(r in "site_mail_relays", where: r.id == type(^relay.id, :binary_id)),
          set: [host: "10.0.0.25"]
        )

      {:ok, view, _html} =
        conn |> signed_in(user, site, "password") |> live(~p"/account/two-factor")

      view |> element("#send-proof-code") |> render_click()
      assert render_async(view, 2_000) =~ "We couldn&#39;t send the code. Try again."
      assert has_element?(view, "#two-factor-proof")
      assert has_element?(view, "#start-totp[disabled]")
    end

    test "no working relay skips the proof, and the event says so", %{conn: conn} do
      site = held_site()
      user = seed_user() |> member!(site)

      relay =
        KilnCMS.CMS.save_site_mail_relay!(
          %{
            host: "smtp.example.com",
            port: 587,
            username: "apikey",
            password: "s3cret",
            from_email: "news@site.example"
          },
          tenant: site,
          authorize?: false
        )

      # What a SECRET_KEY_BASE rotation leaves behind: it must be re-entered.
      {1, _} =
        KilnCMS.Repo.update_all(
          from(r in "site_mail_relays", where: r.id == type(^relay.id, :binary_id)),
          set: [password_encrypted: :crypto.strong_rand_bytes(48)]
        )

      {:ok, view, _html} =
        conn |> signed_in(user, site, "password") |> live(~p"/account/two-factor")

      view |> element("#send-proof-code") |> render_click()
      render_async(view, 2_000)
      refute has_element?(view, "#two-factor-proof")

      enrol_app(view, user)
      assert proof_recorded(user) == [%{"kind" => "totp", "proof" => "email_skipped_no_relay"}]
    end
  end

  describe "sessions that are not asked" do
    test "magic-link and SSO sessions go straight to the factors", %{conn: conn} do
      for {method, label} <- [{"magic_link", "magic_link_session"}, {"sso", "not_required"}] do
        site = held_site()
        user = seed_user() |> member!(site)

        {:ok, view, _html} =
          conn |> signed_in(user, site, method) |> live(~p"/account/two-factor")

        refute has_element?(view, "#two-factor-proof"), method
        enrol_app(view, user)
        assert proof_recorded(user) == [%{"kind" => "totp", "proof" => label}], method
      end
    end

    test "a recovery-code session can replace its authenticator", %{conn: conn} do
      site = held_site()

      {user, _secret} =
        KilnCMS.TwoFactorFixtures.enabled_user(role: :viewer, inserted_at: @long_ago)

      member!(user, site)
      old_secret = reload(user).totp_secret

      {:ok, view, _html} =
        conn
        |> signed_in(user, site, "password", %{"totp_recovery_login" => true})
        |> live(~p"/account/two-factor")

      assert has_element?(view, "#two-factor-recovery-login")
      view |> element("#two-factor-recovery-login button") |> render_click()

      staged = reload(user)
      code = Totp.code_at(staged.totp_pending_secret, System.system_time(:second))
      view |> form("#confirm-totp-form", %{"code" => code}) |> render_submit()

      assert reload(user).totp_secret != old_secret
    end
  end

  describe "grace and readers" do
    test "Not now appears only with ?reminder=1 during the grace period", %{conn: conn} do
      grace =
        "tfs-grace" |> org() |> policy!(:everyone, grace_days: 30, since: DateTime.utc_now())

      user = seed_user() |> member!(grace)

      {:ok, view, html} =
        conn |> signed_in(user, grace, "password") |> live(~p"/account/two-factor?reminder=1")

      assert html =~ "requires two-step sign-in for your role from"
      assert has_element?(view, "#two-factor-not-now")
      refute has_element?(view, "#two-factor-proof")

      {:ok, view, _html} =
        conn |> signed_in(user, grace, "password") |> live(~p"/account/two-factor")

      refute has_element?(view, "#two-factor-not-now")

      held = held_site()
      held_user = seed_user() |> member!(held)

      {:ok, view, _html} =
        conn |> signed_in(held_user, held, "password") |> live(~p"/account/two-factor?reminder=1")

      refute has_element?(view, "#two-factor-not-now")
    end

    test "a reader held under everyone keeps the data export", %{conn: conn} do
      site = held_site()
      user = seed_user() |> member!(site)

      {:ok, view, _html} =
        conn |> signed_in(user, site, "password") |> live(~p"/account/two-factor")

      assert has_element?(
               view,
               ~s(#two-factor-reader-controls a[href="/editor/account/export.json"])
             )
    end

    test "nobody else gets the reader controls", %{conn: conn} do
      site = "tfs-editors" |> org() |> policy!(:editors)
      editor = seed_user(%{role: :editor}) |> member!(site, :editor)
      viewer = seed_user() |> member!(site)

      for user <- [editor, viewer] do
        {:ok, view, _html} =
          conn |> signed_in(user, site, "password") |> live(~p"/account/two-factor")

        refute has_element?(view, "#two-factor-reader-controls")
      end
    end
  end

  test "signed out, the page sends you to sign in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/account/two-factor")
  end
end

defmodule KilnCMSWeb.TwoFactorSetupLiveDemoTest do
  @moduledoc """
  `/account/two-factor` and the shared demo account (#2247): its sign-in
  methods are fixed, so the page offers no factor and asks no proof.

  `async: false`: demo mode is `Application.put_env`, a process-wide write.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]
  import Phoenix.LiveViewTest

  alias KilnCMSWeb.TwoFactorSetupLiveTest, as: Fixtures

  @moduletag :capture_log

  setup do
    previous = Application.get_env(:kiln_cms, KilnCMS.Demo, [])
    Application.put_env(:kiln_cms, KilnCMS.Demo, Keyword.put(previous, :enabled, true))
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Demo, previous) end)
    :ok
  end

  test "the shared demo account sees why, and nothing to change", %{conn: conn} do
    site = "tfs-demo" |> org() |> Fixtures.policy!(:everyone)
    user = Fixtures.seed_user() |> Fixtures.member!(site)

    {:ok, view, _html} =
      conn |> Fixtures.signed_in(user, site, "password") |> live(~p"/account/two-factor")

    assert has_element?(view, "[data-role=demo-locked]")
    refute has_element?(view, "#two-factor-proof")
    refute has_element?(view, "#two-factor-app")

    render_click(view, "passkey_begin", %{})
    refute has_element?(view, "#passkey-waiting")
  end
end
