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
  alias KilnCMS.Security.Posture.Report

  setup do
    Kiln.Updates.put_cache({:ok, :current})
    on_exit(&Kiln.Updates.clear_cache/0)
    %{site: org("pfrep")}
  end

  defp run(actor, opts), do: Security.run_posture(%{}, Keyword.put(opts, :actor, actor))

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
end
