defmodule KilnCMS.Analytics.Export do
  @moduledoc """
  Shared row-shaping and streaming for the analytics export (#618): the
  browser controller (`KilnCMSWeb.AnalyticsExportController`) and
  `mix kiln.analytics.export` both page through `ContentViewDay.:in_range`
  (and, since #620, `ReferrerDay.:in_range`) and resolve titles the same way,
  so the two consumers can't drift on what a row looks like — only on how
  each writes it (chunked HTTP response vs a device). #622's funnel sheet
  extends the row shape here once, not in each caller.

  View rows and referrer rows are two different grains (one per content item
  per day; one per content item per day per source) sharing one export,
  mirroring `KilnCMSWeb.GovernanceController`'s `kind`-tagged CSV precedent:
  one fixed-width header, a `kind` column naming the row, irrelevant columns
  left blank per kind. `csv_row/3`/`json_row/3` dispatch on the row's own
  shape (a view row has `:views`; a referrer row has `:source`/`:hits`)
  rather than taking an explicit kind argument, so an existing caller passing
  a `ContentViewDay` row is unaffected.
  """

  alias KilnCMS.Analytics
  alias KilnCMS.Analytics.ContentViewDay
  alias KilnCMS.Analytics.ReferrerDay
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
  Streams `ContentViewDay.:in_range` in `@batch_size` pages, resolving titles
  once per batch under `actor`'s own read policies (never `authorize?:
  false`) — a lazy `Stream` of `{rows, titles}`, so nothing runs until the
  caller reduces over it.
  """
  @spec stream_rows(Date.t(), Date.t(), term(), term()) :: Enumerable.t()
  def stream_rows(from, to, org, actor) do
    query = Ash.Query.for_read(ContentViewDay, :in_range, %{from: from, to: to})

    query
    |> Ash.stream!(actor: actor, tenant: org, batch_size: @batch_size)
    |> Stream.chunk_every(@batch_size)
    |> Stream.map(fn rows -> {rows, Titles.resolve(rows, org, actor)} end)
  end

  @doc """
  Streams `ReferrerDay.:in_range` the same way `stream_rows/4` streams
  `ContentViewDay` — same batching, same title resolution. Empty (no query
  issued) when referrer attribution is disabled: mirrors the dashboard, which
  hides the breakdown entirely rather than showing an empty one, and there is
  genuinely nothing to page through — a disabled deployment never wrote a row.
  """
  @spec stream_referrer_rows(Date.t(), Date.t(), term(), term()) :: Enumerable.t()
  def stream_referrer_rows(from, to, org, actor) do
    if Analytics.referrers_enabled?() do
      query = Ash.Query.for_read(ReferrerDay, :in_range, %{from: from, to: to})

      query
      |> Ash.stream!(actor: actor, tenant: org, batch_size: @batch_size)
      |> Stream.chunk_every(@batch_size)
      |> Stream.map(fn rows -> {rows, Titles.resolve(rows, org, actor)} end)
    else
      []
    end
  end

  @doc "One CSV row's fields — a view bucket or a referrer bucket, kind-tagged."
  @spec csv_row(map(), map(), term()) :: [term()]
  def csv_row(%{views: views} = row, titles, org) do
    [
      "view",
      Date.to_iso8601(row.day),
      row.content_type,
      row.content_id,
      Titles.title_for(row, titles, org),
      views,
      nil,
      nil
    ]
  end

  def csv_row(%{source: source, hits: hits} = row, titles, org) do
    [
      "referrer",
      Date.to_iso8601(row.day),
      row.content_type,
      row.content_id,
      Titles.title_for(row, titles, org),
      nil,
      source,
      Analytics.suppress_low_count(hits)
    ]
  end

  @doc "One JSON row (a plain map) — a view bucket or a referrer bucket, kind-tagged."
  @spec json_row(map(), map(), term()) :: map()
  def json_row(%{views: views} = row, titles, org) do
    %{
      kind: "view",
      day: row.day,
      content_type: row.content_type,
      content_id: row.content_id,
      title: Titles.title_for(row, titles, org),
      views: views
    }
  end

  def json_row(%{source: source, hits: hits} = row, titles, org) do
    %{
      kind: "referrer",
      day: row.day,
      content_type: row.content_type,
      content_id: row.content_id,
      title: Titles.title_for(row, titles, org),
      source: source,
      hits: Analytics.suppress_low_count(hits)
    }
  end

  @doc "The fixed CSV header for `csv_row/3`'s field order (view and referrer rows share it)."
  @spec csv_header() :: [String.t()]
  def csv_header, do: ~w(kind day content_type content_id title views source hits)
end
