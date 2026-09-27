defmodule KilnCMSWeb.ConsoleSharesOriginTest do
  @moduledoc """
  More than one organization and no `KILN_CONSOLE_HOST` (#1661).

  An org admin's code injection runs on that org's public pages. With the
  console on the same host it is same-origin with the console, so it can act
  as any editor who opens the site signed in — a platform admin included. With
  one org the org admin and the operator are one party. Accepted at 1.0 with a
  warning rather than forced (threat model, residual risk 16), said in the
  three places #660 established: boot, the second org's create, and
  `/editor/system`. The predicate is one function all three ask.

  `async: false` — writes `:console_host` and `:multitenancy_enabled`
  (VM-global).
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import KilnCMS.OrgFixtures

  alias KilnCMS.Accounts
  alias KilnCMSWeb.Tenant

  @console "console.example.test"

  setup do
    console = Application.get_env(:kiln_cms, :console_host)
    multi = Application.get_env(:kiln_cms, :multitenancy_enabled)

    on_exit(fn ->
      restore(:console_host, console)
      restore(:multitenancy_enabled, multi)
    end)

    Application.delete_env(:kiln_cms, :console_host)
    Application.put_env(:kiln_cms, :multitenancy_enabled, true)
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:kiln_cms, key)
  defp restore(key, value), do: Application.put_env(:kiln_cms, key, value)

  defp create_org(slug) do
    Accounts.create_organization(
      %{name: "Org #{slug}", slug: "#{slug}-#{System.unique_integer([:positive])}"},
      authorize?: false
    )
  end

  # The threshold, unit-tested: `Organization` has no destroy action, so the
  # `0`/`1` side is unreachable through the database.
  describe "console_shares_origin?/1" do
    test "an empty or single-org install is one party, so nothing to say" do
      refute Tenant.console_shares_origin?(0)
      refute Tenant.console_shares_origin?(1)
    end

    test "two or more orgs on a shared console origin is" do
      assert Tenant.console_shares_origin?(2)
      assert Tenant.console_shares_origin?(50)
    end

    test "a count that could not be read is not evidence of anything" do
      refute Tenant.console_shares_origin?(:unknown)
    end

    test "a console host closes it, however many orgs exist" do
      Application.put_env(:kiln_cms, :console_host, @console)

      refute Tenant.console_shares_origin?(2)
      refute Tenant.console_shares_origin?(50)
    end

    # `ConsoleHost.console_host/0` treats a blank value as unset; so must this,
    # or a `KILN_CONSOLE_HOST=` typo would silence the warning it most needs.
    test "a blank console host is unset" do
      Application.put_env(:kiln_cms, :console_host, "  ")

      assert Tenant.console_shares_origin?(2)
    end
  end

  describe "console_shares_origin?/0" do
    test "reads the live count" do
      refute Tenant.console_shares_origin?()

      org("cso-second")

      assert Tenant.console_shares_origin?()
    end
  end

  describe "creating the organization that crosses the line" do
    test "warns, naming the setting and the code-injection reach" do
      assert Tenant.org_count() == 1, "another test leaked an org through the action"

      log = capture_log(fn -> assert {:ok, _} = create_org("cso-create") end)

      assert log =~ "[warning]"
      assert log =~ "the second on this deployment"
      assert log =~ "KILN_CONSOLE_HOST is unset"
      assert log =~ "code injection"
      assert log =~ "CHECK_ORIGINS"
    end

    test "says nothing on the third organization and after" do
      assert {:ok, _second} = create_org("cso-crossing")

      log =
        capture_log(fn ->
          assert {:ok, _third} = create_org("cso-third")
        end)

      refute log =~ "KILN_CONSOLE_HOST is unset"
    end

    test "says nothing with a console host set" do
      Application.put_env(:kiln_cms, :console_host, @console)

      log = capture_log(fn -> assert {:ok, _} = create_org("cso-hosted") end)

      refute log =~ "KILN_CONSOLE_HOST is unset"
    end
  end

  describe "the /editor/system panel" do
    @password "password123456"

    setup %{conn: conn} do
      email = "cso-admin-#{System.unique_integer([:positive])}@example.com"

      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: email,
        hashed_password: Bcrypt.hash_pwd_salt(@password),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

      strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

      {:ok, user} =
        AshAuthentication.Strategy.action(strategy, :sign_in, %{
          "email" => email,
          "password" => @password
        })

      Kiln.Updates.clear_cache()
      on_exit(&Kiln.Updates.clear_cache/0)
      Req.Test.stub(Kiln.Updates, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> AshAuthentication.Plug.Helpers.store_in_session(user)

      %{conn: conn}
    end

    # On the second org's own host, which resolves whatever the host-matching
    # settings are.
    defp on_host(conn, org), do: %{conn | host: "#{org.slug}.#{Tenant.base_host()}"}

    test "shows the notice on a multi-org deployment with no console host", %{conn: conn} do
      {:ok, lv, html} = live(on_host(conn, org("cso-panel")), ~p"/editor/system")
      _ = render_async(lv, 2_000)

      assert html =~ "The console shares an origin with every organization"
      assert html =~ "KILN_CONSOLE_HOST is unset"
    end

    test "stays quiet with one organization", %{conn: conn} do
      {:ok, lv, html} = live(%{conn | host: Tenant.base_host()}, ~p"/editor/system")
      _ = render_async(lv, 2_000)

      # The page rendered, so the refute is about the notice.
      assert html =~ "This instance"
      refute html =~ "The console shares an origin"
    end
  end
end
