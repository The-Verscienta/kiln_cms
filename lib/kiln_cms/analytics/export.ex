defmodule KilnCMS.Analytics.Export do
  @moduledoc """
  Shared row-shaping and streaming for the analytics export (#618): the
  browser controller (`KilnCMSWeb.AnalyticsExportController`) and
  `mix kiln.analytics.export` both page through `ContentViewDay.:in_range`
  (since #620, `ReferrerDay.:in_range` too; since #622, `FunnelReport.report/5`
  per funnel) and resolve titles the same way, so the consumers can't drift
  on what a row looks like — only on how each writes it (chunked HTTP
  response vs a device).

  View, referrer and funnel-step rows are three different grains (one per
  content item per day; one per content item per day per source; one per
  funnel step over the whole requested window) sharing one export, mirroring
  `KilnCMSWeb.GovernanceController`'s `kind`-tagged CSV precedent: one
  fixed-width header, a `kind` column naming the row, irrelevant columns
  left blank per kind. `csv_row/3`/`json_row/3` dispatch on the row's own
  shape (a view row has `:views`; a referrer row has `:source`/`:hits`; a
  funnel-step row has `:funnel_slug`) rather than taking an explicit kind
  argument, so an existing caller passing a `ContentViewDay` row is
  unaffected.
  """

  alias KilnCMS.Analytics
  alias KilnCMS.Analytics.ContentViewDay
  alias KilnCMS.Analytics.FunnelReport
  alias KilnCMS.Analytics.ReferrerDay
  alias KilnCMS.Analytics.Titles

  # Rows fetched and titles resolved per batch — bounds memory for a wide
  # window without a round trip per row.
  @batch_size 500

  # Referrer breakdowns per title-resolution batch (#777). A breakdown is at
  # most one row per category, so this is the same ~500-row ceiling
  # `@batch_size` sets for view rows, and the same number of title queries.
  @groups_per_batch 100

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
    |> Stream.map(fn rows -> {:view, rows, Titles.resolve(rows, org, actor)} end)
  end

  @doc """
  Streams `ReferrerDay.:in_range` as **whole breakdowns**, one per
  `(day, content item)`, with each category's exported value already decided.

  Empty (no query issued) when referrer attribution is disabled: mirrors the
  dashboard, which hides the breakdown entirely rather than showing an empty
  one, and there is genuinely nothing to page through — a disabled deployment
  never wrote a row.

  ## Why a group and not a row (#777)

  #620 suppressed a low count per row, which the dashboard later learned is not
  enough: every classified arrival writes one referrer hit alongside its view,
  so an item's categories sum to the exact `views` this same export prints on
  the item's own view row. One `"< n"` beside four exact numbers is not hidden
  at all — it is `total` minus the other four. The export was worse than the
  pre-fix dashboard, because its grain is per *day*: an item with a single
  referrer row that day has that row's count equal to the day's views outright,
  with no subtraction needed.

  So the decision is made over a whole breakdown, by the same
  `Analytics.suppress_referrer_group/1` the dashboard uses, and every category
  is emitted — **including ones with no hits**, which is what makes a
  complementary partner available at all.

  That brought the export up to the dashboard's behaviour, and at the time it
  did **not** close #777 — the algorithm then in place did not prevent
  arithmetic recovery while the exact view total is published beside the
  breakdown. What it bought was one decision to fix rather than two
  implementations to fix separately, and #1073 then fixed it: the partner is now
  the largest of the others rather than the smallest, and a breakdown that
  cannot be made ambiguous is hidden whole, zeros included. See the warning on
  `Analytics.suppress_referrer_group/1` for what that replaced.

  So #777 is closed, and closed **here** rather than only in the algorithm:
  `test/kiln_cms/analytics/export_recovery_test.exs` brute-forces an actual
  exported file — the exact `views` off the view row, every referrer cell off
  the referrer rows — and asserts no suppressed count is uniquely determined.
  It reproduces the four breakdowns #1073 found exactly recoverable, and all
  four go red against the pre-#1073 algorithm. That the *function* is sound is a
  separate claim, tested separately; this one is about the file, which is what
  #777 was filed about and what a recipient actually holds.

  ## Why this is still a stream

  `ReferrerDay.:in_range` sorts `(day, content_type, content_id, id)`, so a
  group is contiguous and `chunk_by/2` holds at most one item's categories at a
  time. Groups are then batched for title resolution exactly as rows were, so
  this costs the same query count and the same bounded memory as before — the
  design constraint #618 set, and the reason #620 deferred this rather than
  buffering the window.
  """
  @spec stream_referrer_rows(Date.t(), Date.t(), term(), term()) :: Enumerable.t()
  def stream_referrer_rows(from, to, org, actor) do
    if Analytics.referrers_enabled?() do
      query = Ash.Query.for_read(ReferrerDay, :in_range, %{from: from, to: to})

      query
      |> Ash.stream!(actor: actor, tenant: org, batch_size: @batch_size)
      |> Stream.chunk_by(&group_key/1)
      |> Stream.map(&decide_group/1)
      |> Stream.chunk_every(@groups_per_batch)
      |> Stream.map(fn groups ->
        rows = List.flatten(groups)
        {:referrer, rows, Titles.resolve(rows, org, actor)}
      end)
    else
      []
    end
  end

  defp group_key(row), do: {row.day, row.content_type, row.content_id}

  # One breakdown's rows, expanded to every category and stamped with what may
  # be shown. The stamped `:display` is what `csv_row/3` and `json_row/3` write
  # — they must never re-derive it from `:hits`, which is the whole point.
  defp decide_group([first | _rest] = rows) do
    totals = Map.new(rows, &{&1.source, &1.hits})

    totals
    |> Analytics.suppress_referrer_group()
    |> Enum.map(fn {source, hits, display} ->
      %{
        day: first.day,
        content_type: first.content_type,
        content_id: first.content_id,
        source: source,
        hits: hits,
        display: display
      }
    end)
  end

  @doc """
  Streams one row per funnel (#622), each carrying its full step report from
  `FunnelReport.report/5` — targeted per-funnel reads, not a page through a
  bucket table, so this is a single eager batch rather than `@batch_size`
  pages: the number of funnels an org defines is small by construction (an
  admin authors each one), unlike the potentially-thousands of daily
  buckets `stream_rows/4` pages through. Empty when the org has no *active*
  funnels — an inactive funnel is excluded the same way the dashboard would
  hide it, not exported as a stale row.
  """
  @spec stream_funnel_rows(Date.t(), Date.t(), term(), term()) :: Enumerable.t()
  def stream_funnel_rows(from, to, org, actor) do
    funnels =
      Analytics.list_funnels!(
        actor: actor,
        tenant: org,
        query: [filter: [active: true], sort: [inserted_at: :asc]]
      )

    case funnels do
      [] ->
        []

      funnels ->
        rows =
          Enum.flat_map(funnels, fn funnel ->
            funnel
            |> FunnelReport.report(from, to, org, actor)
            |> Enum.map(&Map.put(&1, :funnel_slug, funnel.slug))
          end)

        [{:funnel_step, rows, %{}}]
    end
  end

  @doc """
  One CSV row's fields, for a row of the named `kind`.

  The kind is passed in rather than inferred from the row's shape (#778). The
  streams above already know it — they read one table each — and inferring it
  back out meant matching on which keys happened to be present: `%{views: _}`
  for a view bucket, `%{source: _}` for a referrer one. That is an implicit
  contract dialyzer cannot check (the spec had to widen to `map()` to admit all
  three), and it silently mis-dispatches: a `KilnCMS.Analytics.ContentView` row
  — the all-time counter, which has `:views` and no `:day` — matched the view
  clause and raised a `KeyError` naming a field rather than the mistake.
  """
  @spec csv_row(:view | :referrer | :funnel_step, map(), map(), term()) :: [term()]
  def csv_row(:view, %{views: views} = row, titles, org) do
    [
      "view",
      Date.to_iso8601(row.day),
      row.content_type,
      row.content_id,
      Titles.title_for(row, titles, org),
      views,
      nil,
      nil,
      nil,
      nil
    ]
  end

  # `display` was decided over the whole breakdown by `stream_referrer_rows/4`
  # and is written as-is. Calling `suppress_low_count/1` on `hits` here instead
  # would reinstate exactly the per-row decision #777 is about.
  def csv_row(:referrer, %{source: source, display: display} = row, titles, org) do
    [
      "referrer",
      Date.to_iso8601(row.day),
      row.content_type,
      row.content_id,
      Titles.title_for(row, titles, org),
      nil,
      source,
      display,
      nil,
      nil
    ]
  end

  def csv_row(:funnel_step, %{funnel_slug: funnel_slug} = row, _titles, _org) do
    [
      "funnel_step",
      nil,
      row.step.content_type,
      row.step.content_id,
      row.title,
      row.display,
      nil,
      nil,
      funnel_slug,
      row.ratio
    ]
  end

  @doc "One JSON row (a plain map), for a row of the named `kind` — see `csv_row/4`."
  @spec json_row(:view | :referrer | :funnel_step, map(), map(), term()) :: map()
  def json_row(:view, %{views: views} = row, titles, org) do
    %{
      kind: "view",
      day: row.day,
      content_type: row.content_type,
      content_id: row.content_id,
      title: Titles.title_for(row, titles, org),
      views: views
    }
  end

  def json_row(:referrer, %{source: source, display: display} = row, titles, org) do
    %{
      kind: "referrer",
      day: row.day,
      content_type: row.content_type,
      content_id: row.content_id,
      title: Titles.title_for(row, titles, org),
      source: source,
      hits: display
    }
  end

  def json_row(:funnel_step, %{funnel_slug: funnel_slug} = row, _titles, _org) do
    %{
      kind: "funnel_step",
      funnel_slug: funnel_slug,
      content_type: row.step.content_type,
      content_id: row.step.content_id,
      title: row.title,
      views: row.display,
      ratio: row.ratio
    }
  end

  @doc """
  The fixed CSV header for `csv_row/4`'s field order (view, referrer and
  funnel-step rows share it — `funnel_slug`/`ratio` are blank outside the
  `funnel_step` kind, and `day`/`source`/`hits` are blank within it).
  """
  @spec csv_header() :: [String.t()]
  def csv_header,
    do: ~w(kind day content_type content_id title views source hits funnel_slug ratio)
end
