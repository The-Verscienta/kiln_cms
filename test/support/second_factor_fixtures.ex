defmodule KilnCMS.SecondFactorFixtures do
  @moduledoc """
  A site that requires a second factor (#2247), and accounts on it, for the
  enforcement tests: the policy row (seeded, so a test can change it after),
  members with an old `inserted_at` so a policy from long ago holds them at
  once, a stored JWT, and a browser session signed in on the site's host.

  Every caller passes a site of its own. The policy is cached per site on the
  whole node, so a policy on the default org would reach every other test.
  """

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS.SiteSecondFactorPolicy

  @password "password123456"
  @long_ago ~U[2026-01-01 00:00:00.000000Z]

  @doc "Before every seeded account and membership here."
  def long_ago, do: @long_ago

  @doc """
  The site's policy row. `since` (default `long_ago/0`) stamps every tier, so
  `grace_days: 0` (the default) holds everyone covered at once.
  """
  def policy_row!(site, required_for, opts \\ []) do
    since = Keyword.get(opts, :since, @long_ago)

    row =
      Ash.Seed.seed!(SiteSecondFactorPolicy, %{
        org_id: site.id,
        required_for: required_for,
        grace_days: Keyword.get(opts, :grace_days, 0),
        admin_required_since: since,
        editor_required_since: since,
        viewer_required_since: since,
        policy_changed_at: since
      })

    KilnCMS.Cache.bust_second_factor_policy(site.id)
    row
  end

  @doc "Rewrite the row directly (no action, no broadcast) and drop the cached policy."
  def change_policy!(row, attrs) do
    row = Ash.Seed.update!(row, attrs)
    KilnCMS.Cache.bust_second_factor_policy(row.org_id)
    row
  end

  @doc "End every tier's grace period long ago."
  def end_grace!(row) do
    change_policy!(row, %{
      grace_days: 0,
      admin_required_since: @long_ago,
      editor_required_since: @long_ago,
      viewer_required_since: @long_ago
    })
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
          email: "sf-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: :viewer,
          inserted_at: @long_ago
        },
        Map.new(attrs)
      )
    )
  end

  def editor(site), do: seed_user() |> member!(site, :editor)
  def viewer(site), do: seed_user() |> member!(site, :viewer)

  @doc "The authenticator app, as far as `TwoFactorRequirement` can tell."
  def with_app(user), do: Ash.Seed.update!(user, %{totp_confirmed_at: DateTime.utc_now()})

  @doc "A JWT for `user`, minted and stored by the password strategy."
  def jwt(user) do
    {:ok, signed_in} =
      User
      |> AshAuthentication.Info.strategy!(:password)
      |> AshAuthentication.Strategy.action(
        :sign_in,
        %{"email" => to_string(user.email), "password" => @password},
        []
      )

    signed_in.__metadata__.token
  end

  @doc """
  Turns the console host (`KilnCMSWeb.Plugs.ConsoleHost`) on for the calling
  test, under the base host as passkeys need, and restores it on exit. The
  setup page is served on console hosts and the main host only, and
  `<slug>.<console host>` is the one of those that resolves to a site of the
  test's own. For an `async: false` module only: the setting is VM-global.
  """
  def with_console_host do
    previous = Application.get_env(:kiln_cms, :console_host)
    console = "sfconsole#{System.unique_integer([:positive])}.#{KilnCMSWeb.Tenant.base_host()}"
    Application.put_env(:kiln_cms, :console_host, console)
    KilnCMS.Cache.Hosts.clear()

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:kiln_cms, :console_host, previous),
        else: Application.delete_env(:kiln_cms, :console_host)

      KilnCMS.Cache.Hosts.clear()
    end)

    :ok
  end

  @doc "`conn` on `site`'s console host (`with_console_host/0`)."
  def console_conn(conn, site),
    do: %{conn | host: "#{site.slug}.#{KilnCMSWeb.Plugs.ConsoleHost.console_host()}"}

  @doc """
  `conn` signed in as `user` on `site`'s host, the session marked as a
  password sign-in (`KilnCMSWeb.SignInMarker`).
  """
  def signed_in(conn, user, site) do
    token = jwt(user)
    {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(token)

    conn
    |> KilnCMSWeb.ConnCase.org_conn(site)
    |> Phoenix.ConnTest.init_test_session(%{
      "user_token" => token,
      "sign_in" => %{"jti" => jti, "method" => "password"}
    })
  end
end
