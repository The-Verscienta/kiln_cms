defmodule KilnCMS.Security.PostureReportTest do
  @moduledoc """
  `KilnCMS.Security.PostureReport` (#2252): who may run the report, on which
  site, and which checks each caller gets. The site is the action's tenant,
  never an argument.

  `async: false`: the platform admin's report runs the release check, whose
  answer is seeded into `Kiln.Updates`' node-wide cache.
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.PostureFixtures

  alias KilnCMS.Security
  alias KilnCMS.Security.Errors.PostureBusy
  alias KilnCMS.Security.Posture
  alias KilnCMS.Security.Posture.Report

  # A config check that tells the test each time it runs.
  defmodule Counting do
    use Kiln.Security.Check
    def listener, do: :posture_report_test_runs
    def id, do: "test.counting"
    def title, do: "Counting"
    def scope, do: :site

    def run(context) do
      if pid = Process.whereis(listener()), do: send(pid, {:ran, context.org_id})
      pass("ok")
    end
  end

  setup do
    Kiln.Updates.put_cache({:ok, :current})
    on_exit(&Kiln.Updates.clear_cache/0)
    %{site: org("pfrep")}
  end

  defp run(actor, opts), do: Security.run_posture(%{}, Keyword.put(opts, :actor, actor))

  defp snapshot(actor, opts),
    do: Security.posture_snapshot(%{}, Keyword.put(opts, :actor, actor))

  # An actor as `ApiKeyAuth` hands it over for a `:draft_write` key.
  defp with_draft_write_key(user) do
    user
    |> Ash.Resource.put_metadata(:using_api_key?, true)
    |> Ash.Resource.put_metadata(:api_key, %KilnCMS.Accounts.ApiKey{access: :draft_write})
  end

  defp hold_slots(site) do
    test = self()

    holders =
      for _ <- 1..Posture.max_per_org() do
        spawn(fn ->
          Registry.register(Posture.slots(), site.id, nil)
          send(test, :held)
          Process.sleep(:infinity)
        end)
      end

    for _ <- holders, do: assert_receive(:held)
    on_exit(fn -> Enum.each(holders, &Process.exit(&1, :kill)) end)
    holders
  end

  defp scopes(%Report{entries: entries}), do: entries |> Enum.map(& &1.scope) |> Enum.uniq()

  describe "is refused to" do
    test "no actor", %{site: site} do
      assert {:error, %Ash.Error.Forbidden{}} = run(nil, tenant: site)
    end

    for role <- [:viewer, :editor] do
      test "a #{role} of the site", %{site: site} do
        actor = user(:viewer) |> member!(site, unquote(role))
        assert {:error, %Ash.Error.Forbidden{}} = run(actor, tenant: site)
      end
    end

    test "an admin of another site", %{site: site} do
      outsider = user(:viewer) |> member!(org("pfrep-other"), :admin)
      assert {:error, %Ash.Error.Forbidden{}} = run(outsider, tenant: site)
    end

    test "an admin whose registration is still pending", %{site: site} do
      pending = user(:viewer) |> member!(site, :admin, status: :pending)
      assert {:error, %Ash.Error.Forbidden{}} = run(pending, tenant: site)
    end

    test "a site's admin who names no tenant: the default site is not theirs", %{site: site} do
      admin = user(:viewer) |> member!(site, :admin)
      assert {:error, %Ash.Error.Forbidden{}} = run(admin, [])
    end
  end

  test "a site admin gets the site's checks only, about their own site", %{site: site} do
    admin = user(:viewer) |> member!(site, :admin)

    assert {:ok, %Report{} = report} = run(admin, tenant: site)
    assert report.org_id == site.id
    assert report.scopes == [:site]
    assert scopes(report) == [:site]
    assert Enum.any?(report.entries, &(&1.id == "core.second_factor"))
    refute Enum.any?(report.entries, &(&1.id == "core.transport"))
    # Which plugins are installed, and what is wrong with them, is about the
    # whole deployment (#2244).
    refute Enum.any?(report.entries, &(&1.id == "core.plugin_health"))
    # So is whether a security notice covers the running core (#2522).
    refute Enum.any?(report.entries, &(&1.id == "core.security_notices"))

    # The dependency fixture's site check runs beside the core's.
    assert %{status: :pass, source: {:plugin, "kiln_dep_fixture"}} =
             Enum.find(report.entries, &(&1.id == "dep_fixture.build_env"))
  end

  test "the tenant may be the org's id", %{site: site} do
    admin = user(:viewer) |> member!(site, :admin)
    assert {:ok, %Report{org_id: org_id}} = run(admin, tenant: site.id)
    assert org_id == site.id
  end

  test "a platform admin also gets the deployment's checks", %{site: site} do
    operator = user(:admin)

    assert {:ok, %Report{} = report} = run(operator, tenant: site)
    assert report.scopes == [:site, :deployment]
    assert Enum.sort(scopes(report)) == [:deployment, :site]
    assert %{status: :pass} = Enum.find(report.entries, &(&1.id == "core.release"))
    # Plugin checks are off in this suite (`config/test.exs`), so it asks nothing.
    assert %{status: :n_a} = Enum.find(report.entries, &(&1.id == "core.plugin_health"))
    # The security notices feed is off in this suite too, so neither does this.
    assert %{status: :n_a} = Enum.find(report.entries, &(&1.id == "core.security_notices"))
    # Every core check produced an answer: none crashed or overran.
    refute Enum.any?(report.entries, &(&1.status == :error))
  end

  describe "per-site concurrency" do
    test "beyond the cap the action answers busy; another site is unaffected", %{site: site} do
      test = self()

      holders =
        for _ <- 1..KilnCMS.Security.Posture.max_per_org() do
          spawn(fn ->
            Registry.register(KilnCMS.Security.Posture.slots(), site.id, nil)
            send(test, :held)
            Process.sleep(:infinity)
          end)
        end

      for _ <- holders, do: assert_receive(:held)
      on_exit(fn -> Enum.each(holders, &Process.exit(&1, :kill)) end)

      admin = user(:viewer) |> member!(site, :admin)
      assert {:error, error} = run(admin, tenant: site)

      assert Enum.any?(
               Ash.Error.to_error_class(error).errors,
               &match?(%KilnCMS.Security.Errors.PostureBusy{}, &1)
             )

      other = org("pfrep-free")
      other_admin = user(:viewer) |> member!(other, :admin)
      assert {:ok, %Report{}} = run(other_admin, tenant: other)
    end

    test "a slot is given back when the report ends, even by raising" do
      org_id = Ecto.UUID.generate()

      assert {:ok, :done} = KilnCMS.Security.Posture.with_slot(org_id, fn -> :done end)
      assert catch_error(KilnCMS.Security.Posture.with_slot(org_id, fn -> raise "x" end))
      assert Registry.lookup(KilnCMS.Security.Posture.slots(), org_id) == []
    end
  end

  test "the reader's locale is handed to the checks", %{site: site} do
    admin = user(:viewer) |> member!(site, :admin)

    assert {:ok, report} = Security.run_posture(%{locale: "fr"}, actor: admin, tenant: site)
    check = Enum.find(report.entries, &(&1.id == "core.idle_timeout"))
    assert check.title == "Déconnexion après inactivité"
  end

  describe ":snapshot" do
    test "is refused to everyone :run refuses", %{site: site} do
      viewer = user(:viewer) |> member!(site, :viewer)
      editor = user(:viewer) |> member!(site, :editor)
      outsider = user(:viewer) |> member!(org("pfrep-snap-other"), :admin)
      pending = user(:viewer) |> member!(site, :admin, status: :pending)

      for actor <- [nil, viewer, editor, outsider, pending] do
        assert {:error, %Ash.Error.Forbidden{}} = snapshot(actor, tenant: site)
      end

      admin = user(:viewer) |> member!(site, :admin)
      assert {:error, %Ash.Error.Forbidden{}} = snapshot(admin, [])
    end

    test "a site admin gets the site's checks, a platform admin the deployment's too", %{
      site: site
    } do
      admin = user(:viewer) |> member!(site, :admin)
      assert {:ok, %Report{org_id: org_id} = report} = snapshot(admin, tenant: site)
      assert org_id == site.id
      assert report.scopes == [:site]
      assert scopes(report) == [:site]

      assert {:ok, %Report{} = full} = snapshot(user(:admin), tenant: site)
      assert full.scopes == [:site, :deployment]
      assert Enum.sort(scopes(full)) == [:deployment, :site]
    end

    test "carries no details where :run does", %{site: site} do
      # Two admins without a second factor: `core.second_factor` lists them.
      admin = user(:viewer) |> member!(site, :admin)
      _other = user(:viewer) |> member!(site, :admin)

      assert {:ok, ran} = run(admin, tenant: site)

      assert %{result: %{details: [_ | _]}} =
               Enum.find(ran.entries, &(&1.id == "core.second_factor"))

      assert {:ok, snap} = snapshot(admin, tenant: site)
      assert Enum.all?(snap.entries, &(is_nil(&1.result) or &1.result.details == []))
      assert %{status: status} = Enum.find(snap.entries, &(&1.id == "core.second_factor"))
      assert status == Enum.find(ran.entries, &(&1.id == "core.second_factor")).status
    end

    test "answers busy when the site's slots are full, and does not cache it", %{site: site} do
      admin = user(:viewer) |> member!(site, :admin)
      holders = hold_slots(site)

      assert {:error, error} = snapshot(admin, tenant: site)
      assert PostureBusy.in?(error)

      Enum.each(holders, &Process.exit(&1, :kill))

      KilnCMS.Test.Eventually.eventually(fn ->
        Registry.lookup(Posture.slots(), site.id) == []
      end)

      assert {:ok, %Report{}} = snapshot(admin, tenant: site)
    end
  end

  describe "a :draft_write key" do
    test "is refused on both actions, even when its owner is a site admin", %{site: site} do
      admin = user(:viewer) |> member!(site, :admin) |> with_draft_write_key()

      assert {:error, %Ash.Error.Forbidden{}} = run(admin, tenant: site)
      assert {:error, %Ash.Error.Forbidden{}} = snapshot(admin, tenant: site)
    end

    test "is refused even to a platform admin", %{site: site} do
      operator = with_draft_write_key(user(:admin))

      assert {:error, %Ash.Error.Forbidden{}} = run(operator, tenant: site)
      assert {:error, %Ash.Error.Forbidden{}} = snapshot(operator, tenant: site)
    end
  end

  test "the page's :run is never cached, the snapshot is", %{site: site} do
    Process.register(self(), Counting.listener())
    original = Application.get_env(:kiln_cms, KilnCMS.Security.Posture, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Security.Posture, original) end)
    Application.put_env(:kiln_cms, KilnCMS.Security.Posture, checks: [Counting])

    admin = user(:viewer) |> member!(site, :admin)
    site_id = site.id

    assert {:ok, _} = run(admin, tenant: site)
    assert {:ok, _} = run(admin, tenant: site)
    assert_received {:ran, ^site_id}
    assert_received {:ran, ^site_id}

    assert {:ok, _} = snapshot(admin, tenant: site)
    assert {:ok, _} = snapshot(admin, tenant: site)
    assert_received {:ran, ^site_id}
    refute_received {:ran, _}
  end

  describe "Posture.scopes_for/1" do
    defp in_an_hour, do: DateTime.add(DateTime.utc_now(), 3600, :second)
    defp an_hour_ago, do: DateTime.add(DateTime.utc_now(), -3600, :second)

    test "a platform admin gets both scopes" do
      assert Posture.scopes_for(user(:admin)) == [:site, :deployment]
    end

    test "a live elevation grant to admin counts, an expired one does not" do
      live = %{role: :viewer, granted_role: :admin, granted_role_expires_at: in_an_hour()}
      expired = %{role: :viewer, granted_role: :admin, granted_role_expires_at: an_hour_ago()}

      assert Posture.scopes_for(live) == [:site, :deployment]
      assert Posture.scopes_for(expired) == [:site]
    end

    test "a site admin by membership alone gets the site's only", %{site: site} do
      assert Posture.scopes_for(user(:viewer) |> member!(site, :admin)) == [:site]
      assert Posture.scopes_for(nil) == [:site]
    end
  end

  describe "PostureBusy.in?/1" do
    test "finds the busy error in a class, and nothing else" do
      busy = PostureBusy.exception([])

      assert PostureBusy.in?(busy)
      assert PostureBusy.in?(Ash.Error.to_error_class(busy))
      refute PostureBusy.in?(Ash.Error.Forbidden.exception([]))
      refute PostureBusy.in?(Ash.Error.to_error_class(RuntimeError.exception("x")))
    end
  end

  describe "the snapshot cache key" do
    test "is the same in either scope order, and differs per site" do
      a = Ecto.UUID.generate()
      b = Ecto.UUID.generate()

      assert KilnCMS.Cache.security_posture_key(a, [:site, :deployment]) ==
               KilnCMS.Cache.security_posture_key(a, [:deployment, :site])

      refute KilnCMS.Cache.security_posture_key(a, [:site]) ==
               KilnCMS.Cache.security_posture_key(b, [:site])

      refute KilnCMS.Cache.security_posture_key(a, [:site]) ==
               KilnCMS.Cache.security_posture_key(a, [:site, :deployment])
    end
  end

  test "neither action is on the JSON:API, GraphQL or MCP surface" do
    content_domains = Application.fetch_env!(:kiln_cms, :content_domains)
    refute KilnCMS.Security in content_domains

    extensions = Spark.extensions(KilnCMS.Security) ++ Spark.extensions(Security.PostureReport)

    for extension <- [
          AshJsonApi.Domain,
          AshGraphql.Domain,
          AshJsonApi.Resource,
          AshGraphql.Resource,
          AshAi
        ] do
      refute extension in extensions, "#{inspect(extension)} exposes the posture"
    end

    tools = Application.fetch_env!(:kiln_cms, :mcp_tools)
    refute Enum.any?(tools, &(&1 |> Atom.to_string() |> String.contains?("posture")))
  end
end
