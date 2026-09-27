defmodule KilnCMSWeb.StrictHostGapTest do
  @moduledoc """
  The three places a deployment is told about host matching on a multi-org
  install: boot, the second org's create, and `/editor/system` (#660).

  Two different things to say since #1662:

    * **The gap** (`gap?/1`) — routing is lenient while more than one org
      exists, so an unrecognized `Host` is served the default org. Since #1662
      that only happens on a node whose verdict has not caught up with the
      second org yet (`KilnCMSWeb.Tenant.OrgCount` recounts within 30 seconds,
      #1654); `/editor/system` shows it.
    * **`false` is ignored** (`false_ignored?/1`) — `TENANT_STRICT_HOST=false`
      with two or more orgs. Until 0.12 that *was* the gap; now routing refuses
      those hosts anyway, and the operator is told, as an error, that their
      setting is being overridden.

  The predicates live in one place and three callers ask them.

  `async: false` — every test here writes `:multitenancy_enabled`,
  `:tenant_strict_host` or the org-count verdict, which are VM-global.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import KilnCMS.OrgFixtures

  alias KilnCMS.Accounts.Organization
  alias KilnCMSWeb.Tenant
  alias KilnCMSWeb.Tenant.OrgCount

  setup do
    strict = Application.get_env(:kiln_cms, :tenant_strict_host)
    multi = Application.get_env(:kiln_cms, :multitenancy_enabled)
    tracking = Application.get_env(:kiln_cms, :tenant_org_tracking)
    verdict = OrgCount.verdict()

    on_exit(fn ->
      restore(:tenant_strict_host, strict)
      restore(:multitenancy_enabled, multi)
      restore(:tenant_org_tracking, tracking)
      OrgCount.put(verdict)
    end)

    # Every test says which verdict it is on, rather than inheriting one.
    OrgCount.put(:single)
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

    # #1662: a `:multi` verdict refuses unknown hosts under `false` too, so the
    # leak this predicate describes is closed there — `false_ignored?/1` is what
    # that deployment hears instead.
    test "false on a :multi verdict is not a gap" do
      OrgCount.put(:multi)

      refute Tenant.gap?(2)
      refute Tenant.gap?(50)
    end

    test "strict host on beats any count" do
      Application.put_env(:kiln_cms, :tenant_strict_host, true)

      refute Tenant.gap?(2)
      refute Tenant.gap?(50)
    end

    # A non-boolean is auto (#1547), which is what an unset flag means. Auto
    # routes strictly once the verdict is `:multi`, so there is no gap — and
    # while the verdict still says `:single` (a node that has not heard about
    # the second org yet) routing is lenient and the gap is real.
    test "a non-boolean flag counts as auto, because that is what routing does" do
      Application.put_env(:kiln_cms, :tenant_strict_host, :yes)

      OrgCount.put(:multi)
      refute Tenant.gap?(2)

      OrgCount.put(:single)
      assert Tenant.gap?(2)
    end
  end

  # Same unit-level reason as `gap?/1`: the `0`/`1` side is unreachable through
  # the database, so the threshold is pinned here.
  describe "false_ignored?/1" do
    setup do
      Application.put_env(:kiln_cms, :tenant_strict_host, false)
      :ok
    end

    test "an empty or single-org install keeps its false" do
      refute Tenant.false_ignored?(0)
      refute Tenant.false_ignored?(1)
    end

    test "two or more overrides it" do
      assert Tenant.false_ignored?(2)
      assert Tenant.false_ignored?(50)
    end

    test "a count that could not be read is not evidence of anything" do
      refute Tenant.false_ignored?(:unknown)
    end

    # Asks the SETTING, not the verdict: the operator set false, and it is
    # being overridden whether or not this node's verdict has caught up.
    test "whatever the verdict says" do
      for verdict <- [:single, :multi, :unknown] do
        OrgCount.put(verdict)
        assert Tenant.false_ignored?(2), "verdict #{verdict}"
      end
    end

    test "is only about an explicit false" do
      Application.put_env(:kiln_cms, :tenant_strict_host, true)
      refute Tenant.false_ignored?(2)

      Application.delete_env(:kiln_cms, :tenant_strict_host)
      refute Tenant.false_ignored?(2)
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

  describe "strict_host_false_ignored?/0" do
    test "reads the live count" do
      Application.put_env(:kiln_cms, :tenant_strict_host, false)
      refute Tenant.strict_host_false_ignored?()

      org("ignored-second")

      assert Tenant.strict_host_false_ignored?()
    end

    # Not gated on `:multitenancy_enabled`, for the reason the gap is not.
    test "the create kill switch does not silence it" do
      Application.put_env(:kiln_cms, :multitenancy_enabled, false)
      Application.put_env(:kiln_cms, :tenant_strict_host, false)
      org("ignored-killswitch")

      assert Tenant.strict_host_false_ignored?()
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

    test "logs an error: the flag is no longer honoured, and what an unmatched host gets" do
      Application.put_env(:kiln_cms, :tenant_strict_host, false)
      Application.put_env(:kiln_cms, :tenant_org_tracking, true)
      assert Tenant.org_count() == 1, "another test leaked an org through the action"

      log = capture_log(fn -> assert {:ok, _org} = create_org("gap-create") end)

      assert log =~ "[error]"
      assert log =~ "the second on this deployment"
      assert log =~ "TENANT_STRICT_HOST=false"
      assert log =~ "no longer honours"
      assert log =~ "REFUSED"
      # And it is true: the create moved the verdict, so routing is strict.
      assert Tenant.strict_host?()
    end

    # The crossing only. Saying it again on every create would give a SaaS a
    # permanent error per provisioning event. The standing state is what
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

    test "says nothing when the flag is unset" do
      Application.delete_env(:kiln_cms, :tenant_strict_host)

      log = capture_log(fn -> assert {:ok, _org} = create_org("gap-create-auto") end)

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

    test "says TENANT_STRICT_HOST=false is being ignored", %{conn: conn} do
      Application.put_env(:kiln_cms, :tenant_strict_host, false)
      org = org("gap-panel-ignored")
      OrgCount.put(:multi)

      {:ok, _lv, html} = live(on_host(conn, org), ~p"/editor/system")

      assert html =~ "TENANT_STRICT_HOST=false is being ignored"
      assert html =~ "no longer honours TENANT_STRICT_HOST=false"
      # Routing is strict, so there is no gap to report alongside it.
      refute html =~ "Host matching is off"
    end

    # A node whose verdict has not caught up with the second org (#1654).
    test "shows the gap while this node has not noticed the second org", %{conn: conn} do
      Application.delete_env(:kiln_cms, :tenant_strict_host)
      org = org("gap-panel-lag")
      OrgCount.put(:single)

      {:ok, _lv, html} = live(on_host(conn, org), ~p"/editor/system")

      assert html =~ "Host matching is off"
      assert html =~ "within 30 seconds"
      refute html =~ "is being ignored"
    end

    test "stays quiet once the flag is on", %{conn: conn} do
      Application.put_env(:kiln_cms, :tenant_strict_host, true)

      {:ok, _lv, html} = live(on_host(conn, org("gap-panel-strict")), ~p"/editor/system")

      # Proves the page rendered rather than 404ing, so the refute below is about
      # the notice and not about an empty body.
      assert html =~ "This instance"
      refute html =~ "Host matching is off"
      refute html =~ "is being ignored"
    end
  end
end
