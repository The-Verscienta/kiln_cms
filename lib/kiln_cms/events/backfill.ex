defmodule KilnCMS.Events.Backfill do
  @moduledoc """
  Computes `next_occurrence_at` for content that already existed when #766
  landed.

  The migration adds the column; it cannot fill it, because the value is the
  output of `KilnCMS.Events.Occurrences` rather than a function of other
  columns. And `KilnCMS.Events.Sweep` will not fill it either — deliberately.
  The sweep visits rows whose value has **passed**, and a `NULL` has not passed
  anything, so an existing site's "what's on" index stays empty until every
  event happens to be re-saved. This is the one-off pass that closes that gap.

  Run it once per deployment after upgrading (`mix kiln.occurrences.backfill`).
  Safe to re-run, and safe to interrupt: it is idempotent, and the second run
  over already-correct rows writes nothing at all.

  ## It writes only the rows that change

  The whole point of a backfill is that it touches the archive. Writing every
  row would bump `updated_at` on all of them — reordering the `updated_at`
  sorted feeds and the sitemap — and fire `Changes.BustContentCache` once per
  row, each drop taking the site's sitemap, `llms.txt` and feed caches with it.
  `KilnCMS.Events.Index.refresh/3` compares first and skips the no-ops, which is
  what makes this runnable against a live site rather than a maintenance window.

  ## It pages by id, not by offset

  Unlike the sweep, this pass cannot drain: a row it has just corrected still
  matches "every row", so re-running the same query would return it forever.
  Paging is an explicit `id > cursor` keyset — stable while the pass is writing,
  and it does not make Postgres re-walk every skipped row the way a growing
  `OFFSET` does.

  ## Which types it visits

  Event-shaped types only, by default (`KilnCMS.Events.calendar_types/1`) —
  those are the only ones that can produce a non-nil value, and scanning every
  content table to write nothing to the pages and posts is the expense this
  bound avoids.

  `all_types: true` widens it to every type, which matters in exactly one case:
  a type that **lost** its `datetime_range` field while holding future-dated
  values. Those rows are stale, invisible to the sweep (their value has not
  passed) and invisible to the default pass (their type is no longer
  event-shaped), so nothing else will ever correct them.
  """

  require Logger

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Events
  alias KilnCMS.Events.Index

  @batch 500

  @typedoc "What one pass did."
  @type result :: %{scanned: non_neg_integer(), written: non_neg_integer()}

  @doc """
  Backfill every organization. See `run_org/2` for options.
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    KilnCMS.Accounts.list_org_ids()
    |> Enum.map(&run_org(&1, opts))
    |> Enum.reduce(%{scanned: 0, written: 0}, &tally/2)
  end

  @doc """
  Backfill one organization.

  Options:

    * `:all_types` — visit every content type, not only event-shaped ones. See
      the moduledoc for the one case that needs it.
    * `:batch` — rows per page (default #{@batch}).
    * `:now` — pin the clock (tests).
    * `:on_type` — `fn descriptor, result -> :ok end`, called after each type,
      so a CLI can report progress on a long pass.
  """
  @spec run_org(Ash.UUID.t(), keyword()) :: result()
  def run_org(org_id, opts \\ []) do
    anchor = opts |> Keyword.get(:now, DateTime.utc_now()) |> Index.anchor()
    batch = Keyword.get(opts, :batch, @batch)
    on_type = Keyword.get(opts, :on_type, fn _descriptor, _result -> :ok end)

    org_id
    |> types(Keyword.get(opts, :all_types, false))
    |> Enum.map(fn descriptor ->
      result = backfill_type(descriptor, org_id, anchor, batch)
      on_type.(descriptor, result)
      result
    end)
    |> Enum.reduce(%{scanned: 0, written: 0}, &tally/2)
  end

  defp types(org_id, true), do: ContentTypes.all_for_org(org_id)
  defp types(org_id, false), do: Events.calendar_types(org_id)

  defp tally(result, acc),
    do: %{scanned: acc.scanned + result.scanned, written: acc.written + result.written}

  # `Stream.unfold` rather than a recursive function so the paging condition is
  # stated once: a short page is the last page, and there is no separate "are we
  # done" flag to get out of step with the cursor.
  defp backfill_type(descriptor, org_id, anchor, batch) do
    nil
    |> Stream.unfold(fn
      :done ->
        nil

      cursor ->
        case page(descriptor, org_id, cursor, batch) do
          [] -> nil
          rows when length(rows) < batch -> {rows, :done}
          rows -> {rows, List.last(rows).id}
        end
    end)
    |> Enum.reduce(%{scanned: 0, written: 0}, fn rows, acc ->
      %{
        scanned: acc.scanned + length(rows),
        written: acc.written + Enum.count(rows, &refresh(&1, org_id, anchor))
      }
    end)
  end

  # `authorize?: false` for the reason `Index.refresh/3` gives: drafts and gated
  # events need a correct value too, or it is wrong the moment one is published.
  defp page(descriptor, org_id, cursor, batch) do
    ContentTypes.list!(descriptor,
      authorize?: false,
      tenant: org_id,
      query: [
        filter: cursor_filter(cursor),
        sort: [id: :asc],
        limit: batch,
        select: Index.refresh_fields(descriptor)
      ]
    )
  end

  defp cursor_filter(nil), do: []
  defp cursor_filter(cursor), do: [id: [greater_than: cursor]]

  defp refresh(record, org_id, anchor) do
    case Index.refresh(record, org_id, anchor) do
      :written ->
        true

      :unchanged ->
        false

      # A backfill runs against a live site, so one unwritable row must not
      # abandon the pass — but unlike the sweep there is no next scheduled run
      # to pick it up, so it is logged loudly enough to act on.
      {:error, reason} ->
        Logger.warning(
          "occurrence backfill: #{record.id} not written: #{inspect(reason)}; re-run to retry"
        )

        false
    end
  end
end
