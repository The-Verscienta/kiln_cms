defmodule KilnCMS.CMS.StrandedReleaseItemSweepTest do
  @moduledoc """
  The sweep that cancels release items left `:pending` on releases that can
  no longer ship them (#3072, `KilnCMS.CMS.StrandedReleaseItemSweep`): which
  releases it touches and which it leaves alone, that it never rewrites an
  item that is no longer pending, per site, how it fails, and that a second
  run changes nothing.

  Each test works in sites of its own and passes `org_id:` where it can, so
  rows another test committed are not in its counts.
  """
  # async: false — the suite logs at `:warning` and the sweep logs each
  # cancelled item at info, so the log assertions lower the global level for
  # their capture.
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  import ExUnit.CaptureLog
  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentRelease
  alias KilnCMS.CMS.ReleaseItem
  alias KilnCMS.CMS.StrandedReleaseItemSweep

  setup do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "stranded-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    {:ok, admin: admin, site: org("stranded")}
  end

  defp n, do: System.unique_integer([:positive])

  defp page!(site) do
    CMS.create_page!(%{title: "Stranded #{n()}", slug: "stranded-#{n()}"},
      authorize?: false,
      tenant: site.id
    )
  end

  # A release seeded straight into `state`: the sweep reads the stored state,
  # and driving a release to `:rolled_back` or `:archived` through the
  # workers adds nothing these tests look at.
  defp release!(site, state),
    do: Ash.Seed.seed!(ContentRelease, %{name: "Release #{n()}", org_id: site.id, state: state})

  defp item!(site, release, status \\ :pending) do
    Ash.Seed.seed!(ReleaseItem, %{
      release_id: release.id,
      org_id: site.id,
      content_type: "page",
      content_id: page!(site).id,
      action: :publish,
      status: status
    })
  end

  defp status(item, site),
    do: CMS.get_release_item!(item.id, authorize?: false, tenant: site.id).status

  defp capture_info(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log([level: :info], fun)
    after
      Logger.configure(level: previous)
    end
  end

  defp swept(opts) do
    log = capture_info(fn -> send(self(), {:result, StrandedReleaseItemSweep.run(opts)}) end)
    assert_received {:result, result}
    {result, log}
  end

  test "an item stranded on a published release is cancelled, and its record can join another",
       %{admin: admin, site: site} do
    published = release!(site, :published)
    item = item!(site, published)

    {result, _log} = swept(org_id: site.id)

    assert %{cancelled: 1, failed: 0, items: [described]} = result

    assert described == %{
             org_id: site.id,
             release_id: published.id,
             release_state: :published,
             item_id: item.id,
             content_type: "page",
             content_id: item.content_id,
             action: :publish
           }

    assert status(item, site) == :cancelled

    {:ok, next} = CMS.create_release(%{name: "Next"}, actor: admin, tenant: site.id)

    assert {:ok, _} =
             CMS.add_release_item(
               %{release_id: next.id, content_type: "page", content_id: item.content_id},
               actor: admin,
               tenant: site.id
             )
  end

  test "items stranded on rolled-back and archived releases are cancelled", %{site: site} do
    rolled_back = item!(site, release!(site, :rolled_back))
    archived = item!(site, release!(site, :archived))

    {result, _log} = swept(org_id: site.id)

    assert %{cancelled: 2, failed: 0} = result
    assert status(rolled_back, site) == :cancelled
    assert status(archived, site) == :cancelled
  end

  test "pending items on a release that can still ship them are left alone", %{site: site} do
    # `:open` and `:scheduled` compose; `:failed` is retried with its items;
    # `:publishing` and `:rolling_back` are claims a worker owns.
    kept =
      for state <- [:open, :scheduled, :failed, :publishing, :rolling_back],
          do: item!(site, release!(site, state))

    {result, _log} = swept(org_id: site.id)

    assert %{cancelled: 0, failed: 0, items: []} = result
    assert Enum.map(kept, &status(&1, site)) == List.duplicate(:pending, 5)
  end

  test "items that already shipped or were undone keep their status", %{site: site} do
    published = release!(site, :published)
    others = for status <- [:applied, :skipped, :rolled_back], do: item!(site, published, status)
    stranded = item!(site, published)

    {result, _log} = swept(org_id: site.id)

    assert %{cancelled: 1, items: [%{item_id: item_id}]} = result
    assert item_id == stranded.id
    assert Enum.map(others, &status(&1, site)) == [:applied, :skipped, :rolled_back]
  end

  test "a second run changes nothing and logs nothing", %{site: site} do
    item = item!(site, release!(site, :published))
    {%{cancelled: 1}, _log} = swept(org_id: site.id)

    {result, log} = swept(org_id: site.id)

    assert result == %{cancelled: 0, failed: 0, items: [], dry_run?: false}
    assert status(item, site) == :cancelled
    refute log =~ "stranded release item sweep"
  end

  test "it sweeps every site, or the one it is given", %{site: site} do
    other = org("stranded-other")
    here = item!(site, release!(site, :published))
    there = item!(other, release!(other, :published))

    {_result, _log} = swept(org_id: site.id)
    assert status(here, site) == :cancelled
    assert status(there, other) == :pending

    # Without `org_id:`, across every site. Other tests' rows may be in the
    # result, so only these are asserted on.
    {result, _log} = swept([])
    assert there.id in Enum.map(result.items, & &1.item_id)
    refute here.id in Enum.map(result.items, & &1.item_id)
    assert status(there, other) == :cancelled
  end

  test "a dry run lists the items and cancels nothing", %{site: site} do
    item = item!(site, release!(site, :published))

    {result, log} = swept(org_id: site.id, dry_run: true)

    assert %{cancelled: 1, dry_run?: true, items: [%{item_id: item_id}]} = result
    assert item_id == item.id
    assert log =~ "would cancel item #{item.id}"
    assert status(item, site) == :pending
  end

  test "the summary says what a dry run would cancel, not that it cancelled", %{site: site} do
    item!(site, release!(site, :published))

    {dry, _log} = swept(org_id: site.id, dry_run: true)
    assert StrandedReleaseItemSweep.summary(dry) == "would cancel 1, 0 failed"

    {real, _log} = swept(org_id: site.id)
    assert StrandedReleaseItemSweep.summary(real) == "1 cancelled, 0 failed"
  end

  test "an org_id that is not a UUID is refused up front" do
    assert_raise ArgumentError, ~s(org_id is not a UUID: "acme"), fn ->
      StrandedReleaseItemSweep.run(org_id: "acme")
    end
  end

  test "an item applied between the read and the cancel is not rewritten", %{site: site} do
    item = item!(site, release!(site, :published))

    {result, _log} =
      swept(
        org_id: site.id,
        around_cancel: fn found, cancel ->
          Ash.Seed.update!(found, %{status: :applied})
          cancel.()
        end
      )

    # Neither cancelled nor a failure: the item is not this sweep's any more.
    assert %{cancelled: 0, failed: 0, items: []} = result
    assert status(item, site) == :applied
  end

  test "a release whose items cannot be read fails, and nothing is cancelled", %{site: site} do
    item = item!(site, release!(site, :published))

    {result, log} =
      CMS.Housekeeping.with_actor(nil, fn -> swept(org_id: site.id) end)

    assert %{cancelled: 0, failed: 1} = result
    assert log =~ "could not cancel the items of release"
    assert status(item, site) == :pending
  end

  test "a release whose item cannot be cancelled fails, and the sweep goes on", %{site: site} do
    # Releases are swept in id order within a site: the first one fails.
    [first, second] =
      [release!(site, :published), release!(site, :published)] |> Enum.sort_by(& &1.id)

    refused = item!(site, first)
    freed = item!(site, second)

    {result, log} =
      swept(
        org_id: site.id,
        around_cancel: fn found, cancel ->
          if found.release_id == first.id,
            do: CMS.Bookkeeping.with_actor(nil, cancel),
            else: cancel.()
        end
      )

    assert %{cancelled: 1, failed: 1, items: [%{item_id: item_id}]} = result
    assert item_id == freed.id
    assert log =~ "could not cancel the items of release #{first.id} in org #{site.id}"
    assert status(refused, site) == :pending
    assert status(freed, site) == :cancelled
  end

  test "items cancelled before one that fails stay cancelled and are reported", %{site: site} do
    published = release!(site, :published)
    # Read in the order they were added.
    done = item!(site, published)
    refused = item!(site, published)

    {result, log} =
      swept(
        org_id: site.id,
        around_cancel: fn found, cancel ->
          if found.id == refused.id,
            do: CMS.Bookkeeping.with_actor(nil, cancel),
            else: cancel.()
        end
      )

    assert %{cancelled: 1, failed: 1, items: [%{item_id: item_id}]} = result
    assert item_id == done.id
    assert log =~ "stranded release item sweep cancelled item #{done.id}"
    assert log =~ "could not cancel the items of release #{published.id}"
    assert status(done, site) == :cancelled
    assert status(refused, site) == :pending
  end

  test "each cancelled item is logged with its site, release, state and record", %{site: site} do
    published = release!(site, :published)
    item = item!(site, published)

    {_result, log} = swept(org_id: site.id)

    assert log =~
             "stranded release item sweep cancelled item #{item.id} " <>
               "(publish page #{item.content_id}) of published release #{published.id} " <>
               "in org #{site.id}"

    assert log =~ "add the record to a release again if it should still go live"
  end

  describe "the job" do
    test "runs the sweep", %{site: site} do
      item = item!(site, release!(site, :published))

      capture_log(fn -> assert :ok = perform_job(StrandedReleaseItemSweep, %{}) end)
      assert status(item, site) == :cancelled
    end

    test "fails when a release failed, so Oban retries it", %{site: site} do
      item!(site, release!(site, :published))

      capture_log(fn ->
        CMS.Housekeeping.with_actor(nil, fn ->
          assert {:error, message} = perform_job(StrandedReleaseItemSweep, %{})
          assert message =~ "failed for"
        end)
      end)
    end

    test "enqueue/0 queues one job however often a node boots" do
      assert :ok = StrandedReleaseItemSweep.enqueue()
      assert :ok = StrandedReleaseItemSweep.enqueue()

      assert [_one] = all_enqueued(worker: StrandedReleaseItemSweep)
    end

    test "the test build does not enqueue it on boot" do
      # A boot-time enqueue commits outside every sandbox (see config/test.exs).
      assert Application.get_env(:kiln_cms, :stranded_release_item_sweep_on_boot) == false
    end
  end
end
