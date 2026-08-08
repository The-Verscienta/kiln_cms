defmodule KilnCMS.Events.Sweep do
  @moduledoc """
  Re-computes `next_occurrence_at` for rows whose occurrence has gone by (#766).

  The other half of `KilnCMS.Events.Index`, which has the argument for why the
  value is stored at all. A recurring event's next occurrence changes **without
  the record ever being written** — nobody edits a weekly gig on a Tuesday
  night — so a materialized sort key needs something to advance it. This is that
  something.

  ## What it visits, and why that set is small

  Only rows where `next_occurrence_at < ` the day anchor
  (`KilnCMS.Events.Index.anchor/1`). Everything else is already correct:

    * a value **in the future** is right by construction — "the next occurrence
      at or after T" does not move until T reaches it;
    * a `nil` is terminal, because the materialization horizon is a decade
      rather than a rolling window (again, `Events.Index` has the argument). A
      `nil` meaning "nothing within 400 days" would have made this sweep a scan
      of the entire past archive, every run, forever.

  So the working set is "events that finished since the last run", which for an
  hourly schedule is a handful of rows on a busy site and none on most.

  ## It drains rather than paginating

  Each pass reads a batch of stale rows and advances every one of them past the
  anchor (or to `nil`), so the *same* query returns the next batch — no offset
  to skip past rows the previous pass just fixed. `@max_passes` is a runaway
  guard, not a page cap: a row that keeps coming back is a bug, and the log line
  says so rather than the job spinning.

  ## The write is `:set_next_occurrence`, never `:update`

  A schedule-driven write over rows nobody touched must not cut a history
  version, emit an `updated` webhook, re-fire artifacts or bump `lock_version` —
  the last of which would turn an open editor's next save into a `StaleRecord`
  because a gig ended. The action, its exclusion from PaperTrail, and its entry
  in `KilnCMS.CMS.Changes.AnchorVersion`'s versionless list are all that.

  Drafts are swept alongside published rows: the value has to be right at the
  moment something is published, not an hour after.
  """

  require Logger

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Events.Index

  @batch 200
  @max_passes 50

  @doc """
  Sweep every organization. Returns the number of rows advanced.
  """
  @spec run(keyword()) :: non_neg_integer()
  def run(opts \\ []) do
    KilnCMS.Accounts.list_org_ids()
    |> Enum.map(&run_org(&1, opts))
    |> Enum.sum()
  end

  @doc """
  Sweep one organization's event-shaped types. Returns the number of rows
  advanced.

  `:now` pins the clock (tests); `:batch` sizes each pass.
  """
  @spec run_org(Ash.UUID.t(), keyword()) :: non_neg_integer()
  def run_org(org_id, opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    anchor = Index.anchor(now)
    batch = Keyword.get(opts, :batch, @batch)

    # EVERY type, not `Events.calendar_types/1`. A type that is no longer
    # event-shaped is precisely the one holding rows nothing else will ever
    # correct: deleting a `datetime_range` field drops the type out of
    # `calendar_types/1`, and its rows would then keep a stale sort key
    # indefinitely — visible in the index of whatever type still has one, since
    # the window filter is on the column, not on the type's shape.
    # `Index.next_occurrence_at/3` answers `nil` for a document with no
    # schedule, which is exactly the correction those rows need.
    #
    # The cost of asking a non-event type is one index probe returning nothing:
    # the column is NULL on every row it has, and the index is partial on NOT
    # NULL, so there is no scan to do.
    org_id
    |> ContentTypes.all_for_org()
    |> Enum.map(&sweep_type(&1, org_id, anchor, batch))
    |> Enum.sum()
  end

  defp sweep_type(descriptor, org_id, anchor, batch) do
    Enum.reduce_while(1..@max_passes, 0, fn pass, advanced ->
      case stale(descriptor, org_id, anchor, batch) do
        [] ->
          {:halt, advanced}

        records ->
          written = Enum.count(records, &advance(&1, org_id, anchor))
          continue(pass, records, written, advanced, descriptor, org_id)
      end
    end)
  end

  # A full batch means there is probably more; a short one means we are done.
  # A pass that wrote NOTHING is the runaway case — the same rows will come back
  # next pass — so it stops immediately and says which type, rather than burning
  # `@max_passes` reads on them.
  defp continue(pass, records, written, advanced, descriptor, org_id) do
    cond do
      written == 0 ->
        Logger.warning(
          "occurrence sweep: #{length(records)} stale #{descriptor.type} rows in #{org_id} " <>
            "could not be advanced; leaving them for the next run"
        )

        {:halt, advanced}

      pass == @max_passes ->
        Logger.warning(
          "occurrence sweep: hit the #{@max_passes}-pass cap on #{descriptor.type} in " <>
            "#{org_id}; the remainder is left for the next run"
        )

        {:halt, advanced + written}

      true ->
        {:cont, advanced + written}
    end
  end

  # `authorize?: false`, because this is a system job that must see drafts and
  # audience-gated events too — a value that is only correct for public rows is
  # wrong the moment one is published.
  defp stale(descriptor, org_id, anchor, batch) do
    ContentTypes.list!(descriptor,
      authorize?: false,
      tenant: org_id,
      query: [
        filter: [next_occurrence_at: [less_than: anchor]],
        # Oldest first, so a long backlog is worked through in a defensible
        # order rather than whichever rows Postgres happened to return.
        sort: [next_occurrence_at: :asc],
        limit: batch,
        select: select_fields(descriptor)
      ]
    )
  end

  # Every attribute the write path reads, and nothing else — without a `select:`
  # each row drags its whole `blocks` union tree and its embedding vector into
  # memory, which is the spike this sweep exists to keep off the request path
  # rather than move into a background job.
  #
  # The list is not arbitrary: `custom_fields` (+ `type_definition_id` on the
  # dynamic tier) is the schedule; `slug`, `locale`, `state` and `org_id` are
  # what `Changes.BustContentCache` reads in its `after_action`. An attribute
  # left out of a `select:` arrives as `%Ash.NotLoaded{}`, which is truthy and
  # pattern-matches `%{state: state}` perfectly happily — so omitting `state`
  # would not raise, it would silently stop busting.
  defp select_fields(descriptor) do
    [:id, :org_id, :slug, :locale, :state, :custom_fields, :next_occurrence_at] ++
      if(descriptor.source == :dynamic, do: [:type_definition_id], else: [])
  end

  defp advance(record, org_id, anchor) do
    next = Index.next_occurrence_at(record, org_id, anchor)

    record
    |> Ash.Changeset.for_update(:set_next_occurrence, %{next_occurrence_at: next},
      authorize?: false,
      tenant: org_id
    )
    |> Ash.update()
    |> case do
      {:ok, _record} ->
        true

      {:error, reason} ->
        # One unwritable row must not abandon the batch: the rest of the site's
        # listing is still wrong until they are advanced, and the next run picks
        # this one up again.
        Logger.warning("occurrence sweep: #{record.id} not advanced: #{inspect(reason)}")
        false
    end
  end
end
