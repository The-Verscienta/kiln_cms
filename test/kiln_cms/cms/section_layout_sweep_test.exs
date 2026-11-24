defmodule KilnCMS.CMS.SectionLayoutSweepTest do
  @moduledoc """
  The sweep that deletes the section layouts older releases left with no
  field in them (#3060, `KilnCMS.CMS.SectionLayoutSweep`): what it deletes
  and keeps, per owner and per site, how it fails, and that a second run
  changes nothing.

  Each test works in sites of its own and passes `org_id:` where it can, so
  rows another test committed are not in its counts.
  """
  # Async, so its names are its own: rows sharing a unique key with another
  # file's, inserted in another order, deadlock in Postgres.
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  import ExUnit.CaptureLog
  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.SectionLayoutFixtures, only: [orphan_layout!: 1]

  alias KilnCMS.CMS
  alias KilnCMS.CMS.SectionLayoutSweep
  alias KilnCMS.NewerReleaseRows

  setup do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "sweep-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    {:ok, admin: admin, site: org("sweep")}
  end

  defp field!(admin, site, attrs) do
    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :page,
          name: "sweep_#{System.unique_integer([:positive])}",
          label: "Sweep"
        },
        attrs
      ),
      actor: admin,
      tenant: site
    )
  end

  defp layout!(admin, site, attrs) do
    CMS.create_field_section!(Map.merge(%{content_type: :page, display: :tab}, attrs),
      actor: admin,
      tenant: site
    )
  end

  defp orphan!(site, attrs), do: orphan_layout!(Map.put(attrs, :org_id, site.id))

  defp names(site, owner \\ {:compiled, :page}) do
    opts = [authorize?: false, tenant: site]

    case owner do
      {:compiled, type} -> CMS.field_sections_for!(type, opts)
      {:dynamic, id} -> CMS.field_sections_for_definition!(id, opts)
    end
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  defp sweep(opts),
    do: capture_log(fn -> send(self(), {:result, SectionLayoutSweep.run(opts)}) end)

  defp swept(opts) do
    log = sweep(opts)
    assert_received {:result, result}
    {result, log}
  end

  test "deletes a layout no field carries, and keeps the carried ones", %{
    admin: admin,
    site: site
  } do
    field!(admin, site, %{section: "Sweep Kept"})
    layout!(admin, site, %{name: "Sweep Kept"})
    orphan!(site, %{name: "Sweep Gone", display: :fieldset, initially: :auto})

    {result, _log} = swept(org_id: site.id)

    assert %{pruned: 1, skipped: 0, failed: 0} = result

    assert [%{name: "Sweep Gone", owner: {:compiled, :page}, display: :fieldset}] =
             result.layouts

    assert names(site) == ["Sweep Kept"]
  end

  test "a second run changes nothing", %{admin: admin, site: site} do
    field!(admin, site, %{section: "Sweep Kept"})
    layout!(admin, site, %{name: "Sweep Kept"})
    orphan!(site, %{name: "Sweep Gone"})

    assert {%{pruned: 1}, _log} = swept(org_id: site.id)
    assert {%{pruned: 0, skipped: 0, failed: 0, layouts: []}, _log} = swept(org_id: site.id)
    assert names(site) == ["Sweep Kept"]
  end

  test "a field of a type this release does not register still carries its section",
       %{site: site} do
    NewerReleaseRows.field_definition!(%{org_id: site.id, section: "Sweep Newer"})
    orphan!(site, %{name: "Sweep Newer"})

    assert {%{pruned: 0, failed: 0}, _log} = swept(org_id: site.id)
    assert names(site) == ["Sweep Newer"]
  end

  test "a dynamic type's layout nothing carries goes; its carried sibling stays",
       %{admin: admin, site: site} do
    type =
      CMS.create_type_definition!(%{name: "sweep_recipe", label: "Recipe"},
        actor: admin,
        tenant: site
      )

    field!(admin, site, %{content_type: nil, type_definition_id: type.id, section: "Sweep Steps"})

    layout!(admin, site, %{content_type: nil, type_definition_id: type.id, name: "Sweep Steps"})
    orphan!(site, %{type_definition_id: type.id, name: "Sweep Old"})

    assert {%{pruned: 1, layouts: [%{owner: {:dynamic, id}, name: "Sweep Old"}]}, _log} =
             swept(org_id: site.id)

    assert id == type.id
    assert names(site, {:dynamic, type.id}) == ["Sweep Steps"]
  end

  test "every site is swept, each against its own fields", %{admin: admin, site: site} do
    other = org("sweep-other")
    # The same name: carried here, left with nothing there.
    field!(admin, site, %{section: "Sweep Shared"})
    layout!(admin, site, %{name: "Sweep Shared"})
    orphan!(other, %{name: "Sweep Shared"})

    {result, _log} = swept([])

    assert %{org_id: other_id, name: "Sweep Shared"} =
             Enum.find(result.layouts, &(&1.name == "Sweep Shared"))

    assert other_id == other.id
    assert names(site) == ["Sweep Shared"]
    assert names(other) == []
  end

  test "a removed plugin's type keeps its layouts, counted as skipped", %{site: site} do
    id = NewerReleaseRows.field_section!(%{org_id: site.id, name: "Sweep Plugin"})

    assert {%{pruned: 0, skipped: 1, failed: 0}, _log} = swept(org_id: site.id)

    assert %{num_rows: 1} =
             KilnCMS.Repo.query!("SELECT 1 FROM field_sections WHERE id = $1", [
               Ecto.UUID.dump!(id)
             ])
  end

  test "an owner that cannot be read fails alone, and the others are still swept",
       %{admin: admin, site: site} do
    # :page's layouts hold a row this release cannot load; :post's do not.
    unloadable = orphan!(site, %{name: "Sweep Broken"})

    KilnCMS.Repo.query!("UPDATE field_sections SET display = $1 WHERE id = $2", [
      "zz_display_from_a_newer_release_3060",
      Ecto.UUID.dump!(unloadable.id)
    ])

    orphan!(site, %{name: "Sweep Page Gone"})
    orphan!(site, %{content_type: :post, name: "Sweep Post Gone"})
    field!(admin, site, %{content_type: :post, section: "Sweep Post"})

    {result, log} = swept(org_id: site.id)

    assert %{pruned: 1, failed: 1, layouts: [%{name: "Sweep Post Gone"}]} = result
    assert log =~ "section layout sweep could not prune {:compiled, :page}"
    assert names(site, {:compiled, :post}) == []

    %{rows: rows} =
      KilnCMS.Repo.query!(
        "SELECT name FROM field_sections WHERE org_id = $1 AND content_type = 'page' ORDER BY name",
        [Ecto.UUID.dump!(site.id)]
      )

    assert rows == [["Sweep Broken"], ["Sweep Page Gone"]]
  end

  test "a field filed under the section after the sweep's read keeps its layout",
       %{admin: admin, site: site} do
    orphan!(site, %{name: "Sweep Late"})
    orphan!(site, %{name: "Sweep Gone"})

    # Between the read that found both and their deletes, an admin files a
    # field under one of them.
    late = fn
      %{name: "Sweep Late"} -> field!(admin, site, %{section: "Sweep Late"})
      _layout -> :ok
    end

    {result, _log} = swept(org_id: site.id, before_prune: late)

    assert %{pruned: 1, failed: 0, layouts: [%{name: "Sweep Gone"}]} = result
    assert names(site) == ["Sweep Late"]
  end

  test "a layout another writer deleted first is neither pruned here nor a failure",
       %{site: site} do
    first = orphan!(site, %{name: "Sweep Raced"})
    orphan!(site, %{name: "Sweep Gone"})

    # Another pruner (the fields admin, a field write) gets there first.
    raced = fn
      %{name: "Sweep Raced"} ->
        :ok = CMS.destroy_field_section(first, authorize?: false, tenant: site)

      _layout ->
        :ok
    end

    {result, _log} = swept(org_id: site.id, before_prune: raced)

    assert %{pruned: 1, failed: 0, layouts: [%{name: "Sweep Gone"}]} = result
    assert names(site) == []
  end

  test "a dry run reports what it would delete, and deletes nothing", %{site: site} do
    orphan!(site, %{name: "Sweep Gone"})

    {result, _log} = swept(org_id: site.id, dry_run: true)

    assert %{pruned: 1, layouts: [%{name: "Sweep Gone"}]} = result
    assert names(site) == ["Sweep Gone"]
  end

  describe "the job" do
    test "runs the sweep", %{site: site} do
      orphan!(site, %{name: "Sweep Gone"})

      capture_log(fn -> assert :ok = perform_job(SectionLayoutSweep, %{}) end)
      assert names(site) == []
    end

    test "fails when an owner failed, so Oban retries it", %{site: site} do
      broken = orphan!(site, %{name: "Sweep Broken"})

      KilnCMS.Repo.query!("UPDATE field_sections SET display = $1 WHERE id = $2", [
        "zz_display_from_a_newer_release_3060",
        Ecto.UUID.dump!(broken.id)
      ])

      capture_log(fn ->
        assert {:error, message} = perform_job(SectionLayoutSweep, %{})
        assert message =~ "failed for 1 owner"
      end)
    end

    test "enqueue/0 queues one job however often a node boots" do
      assert :ok = SectionLayoutSweep.enqueue()
      assert :ok = SectionLayoutSweep.enqueue()

      assert [_one] = all_enqueued(worker: SectionLayoutSweep)
    end

    test "the test build does not enqueue it on boot" do
      # A boot-time enqueue commits outside every sandbox (see config/test.exs).
      assert Application.get_env(:kiln_cms, :section_layout_sweep_on_boot) == false
    end
  end
end
