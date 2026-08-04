defmodule KilnCMS.Analytics.Export do
  @moduledoc """
  Shared row-shaping and streaming for the analytics export (#618): the
  browser controller (`KilnCMSWeb.AnalyticsExportController`) and
  `mix kiln.analytics.export` both page through `ContentViewDay.:in_range`
  and resolve titles the same way, so the two consumers can't drift on what a
  row looks like — only on how each writes it (chunked HTTP response vs a
  device). Later phases (#620's referrer columns, #622's funnel sheet) extend
  the row shape here once, not in each caller.
  """

  alias KilnCMS.Analytics.ContentViewDay
  alias KilnCMS.Analytics.Titles

  # Rows fetched and titles resolved per batch — bounds memory for a wide
  # window without a round trip per row.
  @batch_size 500

  @doc "The bucket retention window — the cap both callers enforce on a requested span."
  @spec max_days() :: pos_integer()
  def max_days, do: ContentViewDay.retention_days()

  @doc """
  Validates a requested `from`/`to` span: `from` must not be after `to`, and
  the span must not exceed `max_days/0` — an export can't request an
  unbounded scan of the retention window.
  """
  @spec validate_range(Date.t(), Date.t()) :: :ok | {:error, :from_after_to | :range_too_large}
  def validate_range(from, to) do
    cond do
      Date.compare(from, to) == :gt -> {:error, :from_after_to}
      Date.diff(to, from) + 1 > max_days() -> {:error, :range_too_large}
      true -> :ok
    end
  end

  @doc """
  Streams `:in_range` in `@batch_size` pages, resolving titles once per batch
  under `actor`'s own read policies (never `authorize?: false`) — a lazy
  `Stream` of `{rows, titles}`, so nothing runs until the caller reduces over
  it.
  """
  @spec stream_rows(Date.t(), Date.t(), term(), term()) :: Enumerable.t()
  def stream_rows(from, to, org, actor) do
    query = Ash.Query.for_read(ContentViewDay, :in_range, %{from: from, to: to})

    query
    |> Ash.stream!(actor: actor, tenant: org, batch_size: @batch_size)
    |> Stream.chunk_every(@batch_size)
    |> Stream.map(fn rows -> {rows, Titles.resolve(rows, org, actor)} end)
  end

  @doc "One CSV row's fields for a view bucket."
  @spec csv_row(map(), map(), term()) :: [term()]
  def csv_row(row, titles, org) do
    [
      Date.to_iso8601(row.day),
      row.content_type,
      row.content_id,
      Titles.title_for(row, titles, org),
      row.views
    ]
  end

  @doc "One JSON row (a plain map) for a view bucket."
  @spec json_row(map(), map(), term()) :: map()
  def json_row(row, titles, org) do
    %{
      day: row.day,
      content_type: row.content_type,
      content_id: row.content_id,
      title: Titles.title_for(row, titles, org),
      views: row.views
    }
  end

  @doc "The CSV header row for `csv_row/3`'s field order."
  @spec csv_header() :: [String.t()]
  def csv_header, do: ~w(day content_type content_id title views)
end
