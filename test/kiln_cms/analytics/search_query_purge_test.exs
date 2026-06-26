defmodule KilnCMS.Analytics.SearchQueryPurgeTest do
  @moduledoc """
  The nightly AshOban `:purge_expired` retention trigger deletes search-query
  rows last searched before the retention window, and keeps recent ones (#213).
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Analytics.SearchQuery

  defp query(last_searched_at) do
    Ash.Seed.seed!(SearchQuery, %{
      query: "q-#{System.unique_integer([:positive])}",
      locale: "en",
      count: 1,
      result_count: 0,
      last_searched_at: last_searched_at
    })
  end

  defp stored_ids do
    SearchQuery |> Ash.read!(authorize?: false) |> Enum.map(& &1.id)
  end

  test "purges rows older than the retention window, keeps recent ones" do
    days = SearchQuery.retention_days()
    old = query(DateTime.add(DateTime.utc_now(), -(days + 1), :day))
    recent = query(DateTime.add(DateTime.utc_now(), -1, :day))

    AshOban.schedule_and_run_triggers(SearchQuery,
      drain_queues?: true,
      with_recursion: true,
      with_scheduled: true
    )

    ids = stored_ids()
    refute old.id in ids
    assert recent.id in ids
  end
end
