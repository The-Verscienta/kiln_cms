defmodule KilnCMS.Analytics.ContentViewDailyTest do
  @moduledoc """
  Recording a view also increments a per-day bucket (the 7d/30d trend source)
  and emits a `[:kiln_cms, :analytics, :view]` telemetry event (issue #45).
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Analytics

  test "recording views increments today's day bucket for that content" do
    id = Ash.UUID.generate()
    today = Date.utc_today()

    Analytics.record_view!("page", id, authorize?: false)
    Analytics.record_view!("page", id, authorize?: false)

    rows =
      Analytics.views_since!(Date.add(today, -29), authorize?: false)
      |> Enum.filter(&(&1.content_id == id))

    assert [%{content_type: "page", day: ^today, views: 2}] = rows
  end

  test "views_since only returns buckets on or after the cutoff" do
    id = Ash.UUID.generate()
    Analytics.record_view!("post", id, authorize?: false)

    # Today's bucket is in range…
    assert Enum.any?(
             Analytics.views_since!(Date.utc_today(), authorize?: false),
             &(&1.content_id == id)
           )

    # …but not when the cutoff is in the future.
    refute Enum.any?(
             Analytics.views_since!(Date.add(Date.utc_today(), 1), authorize?: false),
             &(&1.content_id == id)
           )
  end

  test "recording a view emits a telemetry event tagged with the content type" do
    ref = make_ref()
    test_pid = self()
    handler = "test-analytics-view-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:kiln_cms, :analytics, :view],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {ref, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    id = Ash.UUID.generate()
    Analytics.record_view!("page", id, authorize?: false)

    assert_received {^ref, %{count: 1}, %{content_type: "page", content_id: ^id}}
  end
end
