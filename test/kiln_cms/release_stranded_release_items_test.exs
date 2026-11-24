defmodule KilnCMS.ReleaseStrandedReleaseItemsTest do
  @moduledoc """
  The stranded release item sweep as a release runs it (#3072,
  `bin/kiln_cms rpc 'KilnCMS.Release.cancel_stranded_release_items()'`):
  output through `IO.puts/1`, each cancelled item logged, and a refusal under
  `eval`. The sweep itself is tested in
  `KilnCMS.CMS.StrandedReleaseItemSweepTest`.
  """
  # async: false — the suite logs at `:warning` and the sweep logs each
  # cancelled item at info, so the log assertions lower the global level for
  # their capture.
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentRelease
  alias KilnCMS.CMS.ReleaseItem
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

  defp status(item, site),
    do: CMS.get_release_item!(item.id, authorize?: false, tenant: site.id).status

  setup do
    site = org("release-stranded")
    n = System.unique_integer([:positive])

    page =
      CMS.create_page!(%{title: "Stranded #{n}", slug: "stranded-#{n}"},
        authorize?: false,
        tenant: site.id
      )

    release =
      Ash.Seed.seed!(ContentRelease, %{name: "Shipped #{n}", org_id: site.id, state: :published})

    item =
      Ash.Seed.seed!(ReleaseItem, %{
        release_id: release.id,
        org_id: site.id,
        content_type: "page",
        content_id: page.id,
        action: :publish,
        status: :pending
      })

    {:ok, site: site, release: release, item: item}
  end

  test "on the serving node it cancels, prints each item and logs it",
       %{site: site, release: release, item: item} do
    log =
      capture_info(fn ->
        output =
          capture_io(fn ->
            assert %{cancelled: 1, failed: 0} =
                     Release.run_stranded_release_item_cancel([org_id: site.id], true)
          end)

        assert output =~
                 "Cancelled item #{item.id} (publish page #{item.content_id}) " <>
                   "of published release #{release.id} in org #{site.id}"

        assert output =~ "Stranded release items: 1 cancelled, 0 failed"
      end)

    assert log =~ "stranded release item sweep cancelled item #{item.id}"
    assert status(item, site) == :cancelled
  end

  test "a dry run prints what it would cancel and cancels nothing",
       %{site: site, item: item} do
    log =
      capture_info(fn ->
        output =
          capture_io(fn ->
            assert %{cancelled: 1} =
                     Release.run_stranded_release_item_cancel(
                       [org_id: site.id, dry_run: true],
                       true
                     )
          end)

        assert output =~ "Would cancel item #{item.id}"
      end)

    assert log =~ "would cancel item #{item.id}"
    assert status(item, site) == :pending
  end

  test "under eval it refuses, and cancels nothing", %{site: site, item: item} do
    output =
      capture_io(fn ->
        assert {:error, message} =
                 Release.run_stranded_release_item_cancel([org_id: site.id], false)

        assert message =~ "bin/kiln_cms rpc"
      end)

    assert output =~ "has not started it"
    assert status(item, site) == :pending
  end
end
