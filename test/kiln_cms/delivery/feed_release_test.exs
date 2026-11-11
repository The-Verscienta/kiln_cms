defmodule KilnCMS.Delivery.FeedReleaseTest do
  @moduledoc """
  #2275 (A1): a release's items publish inside the release's transaction, and
  their feed events — with the exposure read and write the anonymous view
  makes — wait for its commit (`KilnCMS.AfterCommit`). A release that commits
  still commits with those writes involved; one that rolls back tells the
  feed nothing.
  """
  # async: false — a go-live drains Oban, as `KilnCMS.CMS.ReleasesTest` does.
  use KilnCMS.DataCase, async: false

  @moduletag :capture_log

  alias KilnCMS.CMS
  alias KilnCMS.Delivery.Feed
  alias KilnCMS.Delivery.Feed.Event

  setup do
    org = KilnCMS.Accounts.default_org_id()
    :ok = Feed.subscribe(org)

    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "feed-release-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    # Where each feed event was handed off: inside a transaction or not.
    test_pid = self()
    handler = "feed-release-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      Feed.telemetry_event(),
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:handed_off, metadata.id, KilnCMS.Repo.in_transaction?()})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    %{org: org, admin: admin}
  end

  defp page(admin, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    CMS.create_page!(
      Map.merge(%{title: "Release page #{n}", slug: "feed-release-#{n}"}, attrs),
      actor: admin
    )
  end

  defp release_of(admin, pages) do
    {:ok, release} = CMS.create_release(%{name: "Feed release"}, actor: admin)

    for page <- pages do
      {:ok, _item} =
        CMS.add_release_item(
          %{release_id: release.id, content_type: "page", content_id: page.id, action: :publish},
          actor: admin
        )
    end

    release
  end

  defp go_live(release, admin) do
    {:ok, claimed} = CMS.start_release(release, %{}, actor: admin)
    KilnCMS.DataCase.drain_oban()
    CMS.get_release!(claimed.id, authorize?: false)
  end

  defp events_for(id, org) do
    :ok = Feed.sync(org)

    receive do
      {:kiln_feed, %Event{id: ^id} = event} -> [event | events_for(id, org)]
    after
      0 -> []
    end
  end

  test "a release's feed events are handed off after its commit, with the exposure recorded",
       %{org: org, admin: admin} do
    one = page(admin)
    two = page(admin)

    released = go_live(release_of(admin, [one, two]), admin)
    assert released.state == :published

    for page <- [one, two] do
      id = page.id
      assert_received {:handed_off, ^id, false}
      refute_received {:handed_off, ^id, true}
      assert [%Event{kind: :published, anonymous: :show}] = events_for(page.id, org)

      assert [_exposure] =
               KilnCMS.Firing.sync_exposures_for!([page.id],
                 actor: KilnCMS.SystemActor.new(:feed),
                 tenant: org
               )
    end
  end

  test "a release that rolls back hands the feed nothing", %{org: org, admin: admin} do
    good = page(admin)
    # An archived item cannot be published: the whole release rolls back.
    bad = page(admin) |> Ash.Seed.update!(%{state: :archived})

    failed = go_live(release_of(admin, [good, bad]), admin)
    assert failed.state == :failed

    good_id = good.id
    assert events_for(good_id, org) == []
    refute_received {:handed_off, ^good_id, _in_transaction?}

    assert [] =
             KilnCMS.Firing.sync_exposures_for!([good.id],
               actor: KilnCMS.SystemActor.new(:feed),
               tenant: org
             )
  end
end
