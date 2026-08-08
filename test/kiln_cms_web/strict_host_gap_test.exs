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

  # The threshold, unit-tested. `Organization` has no destroy action, so a test
  # cannot get the table below the seeded default org — which means a database
  # -driven test can only ever assert the `> 1` side, and a threshold of `> 0`
  # (or no threshold at all) sits here passing everything. Both mutations did.
  describe "gap?/1" do
    setup do
      Application.put_env(:kiln_cms, :tenant_strict_host, false)
      :ok
    end

    test "an empty or single-org install is not a gap" do
      refute Tenant.gap?(0)
      refute Tenant.gap?(1)
    end

    test "two or more is" do
      assert Tenant.gap?(2)
      assert Tenant.gap?(50)
    end

    test "a count that could not be read is not evidence of anything" do
      refute Tenant.gap?(:unknown)
    end

    test "strict host on beats any count" do
      Application.put_env(:kiln_cms, :tenant_strict_host, true)

      refute Tenant.gap?(2)
      refute Tenant.gap?(50)
    end

    # `TENANT_STRICT_HOST` reaches config through `KilnCMS.Config.Env`, which
    # fails to the DEFAULT rather than to safe — so a garbage value leaves the
    # flag off, and the gap is real.
    test "a non-boolean flag counts as off, because that is what routing does" do
      Application.put_env(:kiln_cms, :tenant_strict_host, :yes)

      assert Tenant.gap?(2)
    end
  end

  describe "strict_host_gap?/0" do
    test "is false while strict host is on, however many orgs exist" do
      Application.put_env(:kiln_cms, :tenant_strict_host, true)
      org("gap-strict")

      refute Tenant.strict_host_gap?()
    end

    # Deliberately NOT gated on `:multitenancy_enabled`. Nothing in the routing
    # path reads that flag — it is a create kill switch — so an operator with
    # several orgs who sets it to `false` to refuse another still has every
    # unrecognized Host landing on the default org. Gating on it would silence
    # all three warnings for exactly the deployment that needs them.
    test "the create kill switch does not silence it" do
      Application.put_env(:kiln_cms, :multitenancy_enabled, false)
      Application.put_env(:kiln_cms, :tenant_strict_host, false)
      org("gap-killswitch")

      assert Tenant.strict_host_gap?()
    end

    test "reads the live count" do
      Application.put_env(:kiln_cms, :tenant_strict_host, false)

      # The test database always carries the seeded default org, so one more is
      # the crossing. Asserted as a delta rather than assuming a clean table.
      before = Tenant.org_count()
      assert is_integer(before) and before >= 1

      org("gap-second")

      assert Tenant.org_count() == before + 1
      assert Tenant.strict_host_gap?()
    end
  end

  describe "creating the organization that crosses the line" do
    setup do
      Application.put_env(:kiln_cms, :multitenancy_enabled, true)
      :ok
    end

    # `Ash.Seed` bypasses the action, so these are the only creates that reach
    # the change — which is also why the fixtures, the multi-tenancy suite and
    # the restore/import paths are unaffected by it.

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
      assert Tenant.org_count() == 1, "another test leaked an org through the action"

      log = capture_log(fn -> assert {:ok, _org} = create_org("gap-create") end)

      assert log =~ "TENANT_STRICT_HOST"
      assert log =~ "DEFAULT org"
    end

    # The crossing only. Saying it again on every create would give a SaaS that
    # has deliberately left the flag off a permanent warning per provisioning
    # event — and the message would be false from the third on, since that create
    # did not make anything multi-tenant. The standing state is what
    # `/editor/system` is for.
    test "says nothing on the third organization and after" do
      Application.put_env(:kiln_cms, :tenant_strict_host, false)
      assert {:ok, _second} = create_org("gap-crossing")

      log =
        capture_log(fn ->
          assert {:ok, _third} = create_org("gap-third")
          assert {:ok, _fourth} = create_org("gap-fourth")
        end)

      refute log =~ "TENANT_STRICT_HOST"
    end

    test "says nothing when strict host is already on" do
      Application.put_env(:kiln_cms, :tenant_strict_host, true)

      log = capture_log(fn -> assert {:ok, _org} = create_org("gap-create-strict") end)

      refute log =~ "TENANT_STRICT_HOST"
    end

    # The advisory reads the database, and it used to do so from an
    # `after_action` — inside the create's own transaction. A read that fails
    # there aborts the Postgres transaction, and no `rescue` can save it: the
    # create comes back as an opaque `{:error, :rollback}` and the organization
    # is gone. `after_transaction` moves it past the commit; this pins that the
    # record survives independently of what the advisory does.
    test "the organization is committed before the advisory runs" do
      Application.put_env(:kiln_cms, :tenant_strict_host, false)

      parent = self()

      log =
        capture_log(fn ->
          assert {:ok, org} = create_org("gap-committed")
          send(parent, {:created, org.id})
        end)

      assert log =~ "TENANT_STRICT_HOST"
      assert_received {:created, id}

      # Read back from the table: a rolled-back create still hands the caller a
      # struct, so `{:ok, _}` alone proves nothing about what was committed.
      assert {:ok, %Organization{}} = Ash.get(Organization, id, authorize?: false)
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
      Application.put_env(:kiln_cms, :tenant_strict_host, false)

      {:ok, _lv, html} = live(on_host(conn, org("gap-panel")), ~p"/editor/system")

      assert html =~ "Host matching is off"
      assert html =~ "TENANT_STRICT_HOST=true"
    end

    test "stays quiet once the flag is on", %{conn: conn} do
      Application.put_env(:kiln_cms, :tenant_strict_host, true)

      {:ok, _lv, html} = live(on_host(conn, org("gap-panel-strict")), ~p"/editor/system")

      # Proves the page rendered rather than 404ing, so the refute below is about
      # the notice and not about an empty body.
      assert html =~ "This instance"
      refute html =~ "Host matching is off"
    end
  end
end
