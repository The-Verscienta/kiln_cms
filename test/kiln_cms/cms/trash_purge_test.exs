defmodule KilnCMS.CMS.TrashPurgeTest do
  @moduledoc """
  The `:purge` action hard-deletes trashed content (bypassing AshArchival), and
  the nightly AshOban `purge_trashed` trigger purges anything that has sat in
  the trash for 30+ days.
  """
  # Oban runs in :manual mode; `schedule_and_run_triggers/2` drains the queue
  # inline in this process (see scheduled_publishing_test.exs).
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page

  defp trashed_page(archived_at) do
    Ash.Seed.seed!(Page, %{
      title: "Trashed",
      slug: "purge-#{System.unique_integer([:positive])}",
      state: :draft,
      archived_at: archived_at
    })
  end

  test "purge hard-deletes a trashed page" do
    page = trashed_page(DateTime.utc_now())

    assert :ok = CMS.purge_page(page, authorize?: false)
    refute Enum.any?(CMS.list_trashed_pages!(authorize?: false), &(&1.id == page.id))
  end

  test "the nightly trigger purges 30+ day-old trash but keeps recent items" do
    old = trashed_page(DateTime.add(DateTime.utc_now(), -31, :day))
    recent = trashed_page(DateTime.add(DateTime.utc_now(), -5, :day))

    AshOban.schedule_and_run_triggers(KilnCMS.CMS.Page,
      drain_queues?: true,
      with_recursion: true,
      with_scheduled: true
    )

    trashed_ids = Enum.map(CMS.list_trashed_pages!(authorize?: false), & &1.id)
    refute old.id in trashed_ids
    assert recent.id in trashed_ids
  end
end
