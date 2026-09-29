defmodule KilnCMS.Media.QuarantineReaperStrictTest do
  @moduledoc """
  The quarantine reaper under the strict (`global?: false`) tenancy build
  (#419), which is the production default and runs only on the strict CI leg.

  The reaper used to scan with a tenant-less read of `MediaItem`'s primary
  action, which strict tenancy refuses: in production it raised every hour and
  never removed a stuck quarantine, while the fail-open main suite passed. It
  now scans through `:quarantine_expired`, a `multitenancy :bypass` read, as
  `KilnCMS.Media.system/0` (#1659).
  """
  use KilnCMS.DataCase, async: true

  import ExUnit.CaptureLog
  import KilnCMS.OrgFixtures

  @moduletag :strict_tenancy

  alias KilnCMS.CMS.MediaItem
  alias KilnCMS.Media.QuarantineReaper

  defp stale_quarantined!(org_id) do
    n = System.unique_integer([:positive])
    old = DateTime.add(DateTime.utc_now(), -(QuarantineReaper.max_age_hours() + 1) * 3600)

    Ash.Seed.seed!(MediaItem, %{
      filename: "clip-#{n}.mp4",
      content_type: "video/mp4",
      storage_key: "strict-q-#{n}.mp4",
      url: "/uploads/strict-q-#{n}.mp4",
      quarantined: true,
      org_id: org_id,
      inserted_at: old
    })
  end

  defp stored?(item) do
    MediaItem
    |> Ash.read!(authorize?: false, tenant: item.org_id)
    |> Enum.any?(&(&1.id == item.id))
  end

  test "the strict build is actually strict for media" do
    refute Ash.Resource.Info.multitenancy_global?(MediaItem)
  end

  test "reaps stale quarantines on every site" do
    here = stale_quarantined!(KilnCMS.Accounts.default_org_id())
    there = stale_quarantined!(org("strict-reaper-#{System.unique_integer([:positive])}").id)

    capture_log(fn -> assert QuarantineReaper.run() >= 2 end)

    refute stored?(here)
    refute stored?(there)
  end
end
