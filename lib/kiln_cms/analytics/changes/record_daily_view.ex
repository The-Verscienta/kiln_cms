defmodule KilnCMS.Analytics.Changes.RecordDailyView do
  @moduledoc """
  After a content view is recorded, (1) emit a `[:kiln_cms, :analytics, :view]`
  telemetry event so external sinks (Prometheus, etc.) can observe view traffic,
  and (2) increment the day bucket in `KilnCMS.Analytics.ContentViewDaily` for
  the 7d/30d dashboard trend.

  Both are best-effort: analytics must never break or slow content delivery, so
  a failure here is swallowed and the original view record is still returned.
  """
  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      :telemetry.execute(
        [:kiln_cms, :analytics, :view],
        %{count: 1},
        %{content_type: record.content_type, content_id: record.content_id}
      )

      record_daily(record)
      {:ok, record}
    end)
  end

  defp record_daily(record) do
    KilnCMS.Analytics.record_daily_view(
      record.content_type,
      record.content_id,
      Date.utc_today(),
      authorize?: false
    )
  rescue
    error ->
      Logger.warning("daily view bucket failed: #{Exception.message(error)}")
      :ok
  end
end
