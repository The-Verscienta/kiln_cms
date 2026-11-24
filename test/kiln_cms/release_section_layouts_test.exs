defmodule KilnCMS.ReleaseSectionLayoutsTest do
  @moduledoc """
  The section layout sweep as a release runs it (#3060,
  `bin/kiln_cms rpc 'KilnCMS.Release.prune_section_layouts()'`): output
  through `IO.puts/1`, each deleted layout logged, and a refusal under
  `eval`. The sweep itself is tested in `KilnCMS.CMS.SectionLayoutSweepTest`.
  """
  # async: false — the suite logs at `:warning` and the sweep logs each
  # deleted layout at info, so the log assertions lower the global level for
  # their capture.
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.SectionLayoutFixtures, only: [orphan_layout!: 1]

  alias KilnCMS.CMS
  alias KilnCMS.Release

  defp capture_info(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log([level: :info], fun)
    after
      Logger.configure(level: previous)
    end
  end

  defp names(site),
    do: :page |> CMS.field_sections_for!(authorize?: false, tenant: site) |> Enum.map(& &1.name)

  setup do
    site = org("release-sweep")
    orphan_layout!(%{org_id: site.id, name: "Rel Gone", display: :fieldset, initially: :auto})
    {:ok, site: site}
  end

  test "on the serving node it deletes, prints each layout and logs it", %{site: site} do
    log =
      capture_info(fn ->
        output =
          capture_io(fn ->
            assert %{pruned: 1, failed: 0} =
                     Release.run_section_layout_prune([org_id: site.id], true)
          end)

        assert output =~ ~s(Deleted "Rel Gone" of {:compiled, :page} in org #{site.id})
        assert output =~ "Section layouts: 1 pruned, 0 skipped (unknown type), 0 failed"
      end)

    # Logged with what it would take to recreate it.
    assert log =~ ~s(deleted the layout of section "Rel Gone" of {:compiled, :page})
    assert log =~ "in org #{site.id} (display: fieldset, initially: auto)"
    assert names(site) == []
  end

  test "a dry run prints what it would delete and deletes nothing", %{site: site} do
    log =
      capture_info(fn ->
        output =
          capture_io(fn ->
            assert %{pruned: 1} =
                     Release.run_section_layout_prune([org_id: site.id, dry_run: true], true)
          end)

        assert output =~ ~s(Would delete "Rel Gone")
      end)

    assert log =~ ~s(would delete the layout of section "Rel Gone")
    assert names(site) == ["Rel Gone"]
  end

  test "under eval it refuses, and deletes nothing", %{site: site} do
    output =
      capture_io(fn ->
        assert {:error, message} = Release.run_section_layout_prune([org_id: site.id], false)
        assert message =~ "bin/kiln_cms rpc"
      end)

    assert output =~ "has not started it"
    assert names(site) == ["Rel Gone"]
  end
end
