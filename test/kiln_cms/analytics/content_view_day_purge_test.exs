defmodule KilnCMS.Analytics.ContentViewDayPurgeTest do
  @moduledoc """
  The nightly AshOban `:purge_expired` retention trigger deletes daily view
  buckets first recorded before the retention window, and keeps recent ones
  (#45).
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Analytics.ContentViewDay

  # Retention is driven by `inserted_at`, not `day`: `ago/2` returns a datetime
  # that a `:date` column can't be compared against, and `inserted_at` is
  # stamped once on the day's first view and never rewritten by the upsert.
  defp bucket(inserted_at) do
    Ash.Seed.seed!(ContentViewDay, %{
      content_type: "page",
      content_id: Ash.UUID.generate(),
      day: DateTime.to_date(inserted_at),
      views: 1,
      inserted_at: inserted_at,
      updated_at: inserted_at
    })
  end

  defp stored_ids do
    ContentViewDay |> Ash.read!(authorize?: false) |> Enum.map(& &1.id)
  end

  test "purges buckets older than the retention window, keeps recent ones" do
    days = ContentViewDay.retention_days()
    old = bucket(DateTime.add(DateTime.utc_now(), -(days + 1), :day))
    recent = bucket(DateTime.add(DateTime.utc_now(), -1, :day))

    AshOban.schedule_and_run_triggers(ContentViewDay,
      drain_queues?: true,
      with_recursion: true,
      with_scheduled: true
    )

    ids = stored_ids()
    refute old.id in ids
    assert recent.id in ids
  end
end
