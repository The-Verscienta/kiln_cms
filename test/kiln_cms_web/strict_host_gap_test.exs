defmodule KilnCMSWeb.StrictHostGapTest do
  @moduledoc """
  The three places a deployment is told that it went multi-tenant while
  `TENANT_STRICT_HOST` was still off (#660).

  With the flag off, a request whose `Host` matches no organization falls back
  to the default org — a bare hostname, an IP, a `Host` a caller made up. On a
  single-org install that is the same site either way, so the fallback is a
  convenience. The moment a second org exists it is another tenant's content,
  branding and analytics, and nothing about the request looks wrong.

  #563 shipped the flag with a CHANGELOG `### Upgrading` note. Boot logs a
  warning. Both help someone who is reading at the right moment; neither fires at
  the moment the condition becomes true, which is the create. So the predicate
  lives in one place and three callers ask it: boot, org creation, and the
  `/editor/system` panel that is still there tomorrow.

  `async: false` — every test here writes `:multitenancy_enabled` or
  `:tenant_strict_host`, which are application-global.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import KilnCMS.OrgFixtures

  alias KilnCMS.Accounts.Organization
  alias KilnCMSWeb.Tenant

  setup do
    strict = Application.get_env(:kiln_cms, :tenant_strict_host)
    multi = Application.get_env(:kiln_cms, :multitenancy_enabled)

    on_exit(fn ->
      restore(:tenant_strict_host, strict)
      restore(:multitenancy_enabled, multi)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:kiln_cms, key)
  defp restore(key, value), do: Application.put_env(:kiln_cms, key, value)

  describe "strict_host_gap?/0" do
    test "is false while strict host is on, however many orgs exist" do
      Application.put_env(:kiln_cms, :multitenancy_enabled, true)
      Application.put_env(:kiln_cms, :tenant_strict_host, true)
      org("gap-strict")

      refute Tenant.strict_host_gap?()
    end

    test "is false when the tenant axis is switched off entirely" do
      Application.put_env(:kiln_cms, :multitenancy_enabled, false)
      Application.put_env(:kiln_cms, :tenant_strict_host, false)
      org("gap-single-tenant")

      refute Tenant.strict_host_gap?()
    end

    # The condition is "more than one org", not "any org": the seeded default
    # org is the whole install on a single-tenant deployment, and warning there
    # would be noise every operator learns to ignore.
    test "is true only once a second org exists" do
      Application.put_env(:kiln_cms, :multitenancy_enabled, true)
      Application.put_env(:kiln_cms, :tenant_strict_host, false)

      # The test database always carries the seeded default org, so one more is
      # the crossing. Asserted as a delta rather than assuming a clean table.
      {:ok, before} = Ash.count(Organization, authorize?: false)
      assert before >= 1

      org("gap-second")

      {:ok, after_count} = Ash.count(Organization, authorize?: false)
      assert after_count == before + 1
      assert Tenant.strict_host_gap?()
    end
  end

  describe "creating the organization that crosses the line" do
    setup do
      Application.put_env(:kiln_cms, :multitenancy_enabled, true)
      :ok
    end

    defp create_org(slug) do
      Organization
      |> Ash.Changeset.for_create(:create, %{
        name: "Org #{slug}",
        slug: "#{slug}-#{System.unique_integer([:positive])}"
      })
      |> Ash.create(authorize?: false)
    end

    test "warns, naming the flag and what an unmatched host gets" do
      Application.put_env(:kiln_cms, :tenant_strict_host, false)

      log = capture_log(fn -> assert {:ok, _org} = create_org("gap-create") end)

      assert log =~ "TENANT_STRICT_HOST"
      assert log =~ "DEFAULT org"
    end

    test "says nothing when strict host is already on" do
      Application.put_env(:kiln_cms, :tenant_strict_host, true)

      log = capture_log(fn -> assert {:ok, _org} = create_org("gap-create-strict") end)

      refute log =~ "TENANT_STRICT_HOST"
    end

    # The advisory runs inside the create's transaction, so anything that raised
    # there would roll the organization back — turning a log line into an outage,
    # a worse failure than the one being warned about. The predicate is total (see
    # `strict_host_gap?/0`) and the change rescues on top of it; this asserts the
    # pair from the outside, with a config value no `and` will accept.
    test "a config value that is not a boolean cannot take the create down" do
      Application.put_env(:kiln_cms, :tenant_strict_host, false)
      Application.put_env(:kiln_cms, :multitenancy_enabled, :yes)

      refute Tenant.strict_host_gap?()

      log = capture_log(fn -> assert {:ok, _org} = create_org("gap-create-boom") end)

      refute log =~ "TENANT_STRICT_HOST"
    end
  end

  describe "the /editor/system panel" do
    @password "password123456"

    setup %{conn: conn} do
      email = "gap-admin-#{System.unique_integer([:positive])}@example.com"

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

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> AshAuthentication.Plug.Helpers.store_in_session(user)

      %{conn: conn}
    end

    # The request is made against the second org's own subdomain, not the test
    # default `www.example.com`. Under strict host that default matches no org
    # and is refused before the router — which would make the "flag on" case pass
    # for the wrong reason, on a 404 body that contains nothing at all.
    defp on_host(conn, org) do
      %{conn | host: "#{org.slug}.#{Tenant.base_host()}"}
    end

    test "shows the notice while the gap is open", %{conn: conn} do
      Application.put_env(:kiln_cms, :multitenancy_enabled, true)
      Application.put_env(:kiln_cms, :tenant_strict_host, false)

      {:ok, _lv, html} = live(on_host(conn, org("gap-panel")), ~p"/editor/system")

      assert html =~ "Host matching is off"
      assert html =~ "TENANT_STRICT_HOST=true"
    end

    test "stays quiet once the flag is on", %{conn: conn} do
      Application.put_env(:kiln_cms, :multitenancy_enabled, true)
      Application.put_env(:kiln_cms, :tenant_strict_host, true)

      {:ok, _lv, html} = live(on_host(conn, org("gap-panel-strict")), ~p"/editor/system")

      # Proves the page rendered rather than 404ing, so the refute below is about
      # the notice and not about an empty body.
      assert html =~ "This instance"
      refute html =~ "Host matching is off"
    end
  end
end
