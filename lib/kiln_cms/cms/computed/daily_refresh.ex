defmodule KilnCMS.CMS.Computed.DailyRefresh do
  @moduledoc """
  Moves **time-dependent** computed fields to the new day: re-derives and
  re-fires the published records of every type with a `today()` formula
  (`KilnCMS.CMS.Computed.time_dependent?/1`).

  A formula is evaluated on write and again on fire, each time on a pinned
  date (`KilnCMS.CMS.Computed.Context`, "Pinning today"), so a record and its
  artifact always agree on the day they were derived. What nothing else does
  is notice that the day has *changed*: a countdown nobody edits would keep
  saying "3 days" forever. This is that something.

  ## When it runs

  `KilnCMS.CMS.FieldDefinition`'s `:refresh_time_dependent` scheduled action
  ticks hourly, and `tick/1` does the work only on the first tick after the
  **site's** midnight (`due?/1`: the date in
  `KilnCMS.Events.default_time_zone/0` differs from an hour ago). A plain
  daily cron is UTC, so on a site in `America/Los_Angeles` it would refresh at
  17:00 local and leave the morning's values a day behind. A missed tick (no
  node up that hour) is a day's delay, not a lost day — the next one refreshes
  against its own date, and any edit or publish in between derives its own.

  ## What it writes

  For each org, the computed definitions whose formula calls `today()`, the
  types they belong to, and those types' **published** records, in keyset
  batches. Each record goes through the content resource's internal
  `:refresh_computed` action as the `:computed_fields` system actor, with the
  day pinned in the changeset context — and only when its computed values
  actually move on that day: the changeset is built first and submitted only
  if `custom_fields` changes, so a yearly "age" writes once a year, not every
  night. The action's own fire carries the same date. See that action's
  comment in `KilnCMS.CMS.Content` for why it is versioned but keeps
  `updated_at` and the lock.

  Drafts are not visited: their stored value is re-derived on the next save,
  and on publish (`:publish`/`:publish_scheduled` run the computed refresh
  on the publish day).
  """

  require Logger

  alias KilnCMS.CMS.Computed
  alias KilnCMS.CMS.ContentTypes

  @batch 100

  @doc """
  The scheduled entry point. With `today:` it refreshes against that date
  unconditionally (a manual run, a test); without it, only when `due?/1` says
  the site's day has just changed. Returns the number of records written.

  `now:` pins the clock for the due check.
  """
  @spec tick(keyword()) :: non_neg_integer()
  def tick(opts \\ []) do
    case Keyword.get(opts, :today) do
      %Date{} = today ->
        run(Keyword.put(opts, :today, today))

      nil ->
        now = Keyword.get(opts, :now) || DateTime.utc_now()
        if due?(now), do: run(Keyword.put(opts, :today, Computed.Context.today(now))), else: 0
    end
  end

  @doc """
  Whether `now` is the first hourly tick of a new site day: the site's date
  now differs from its date an hour earlier. True on exactly one tick per day,
  whatever the zone's offset or DST shift.
  """
  @spec due?(DateTime.t()) :: boolean()
  def due?(now),
    do: Computed.Context.today(now) != Computed.Context.today(DateTime.add(now, -3600))

  @doc """
  Refresh every organization against `today:` (the site's current date when
  omitted). Returns the number of records written.
  """
  @spec run(keyword()) :: non_neg_integer()
  def run(opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :today, &Computed.Context.today/0)

    KilnCMS.Accounts.list_org_ids()
    |> Enum.map(&run_org(&1, opts))
    |> Enum.sum()
  end

  @doc """
  Refresh one organization. `:today` is the date to derive on (default: the
  site's current date); `:batch` sizes each read.
  """
  @spec run_org(Ash.UUID.t(), keyword()) :: non_neg_integer()
  def run_org(org_id, opts \\ []) do
    today = Keyword.get_lazy(opts, :today, &Computed.Context.today/0)
    batch = Keyword.get(opts, :batch, @batch)

    org_id
    |> time_dependent_types()
    |> Enum.map(&refresh_type(&1, org_id, today, batch))
    |> Enum.sum()
  end

  @doc """
  The content types in `org_id` with at least one time-dependent computed
  field, as `KilnCMS.CMS.ContentTypes` descriptors.
  """
  @spec time_dependent_types(Ash.UUID.t()) :: [map()]
  def time_dependent_types(org_id) do
    definitions =
      KilnCMS.CMS.list_field_definitions!(
        actor: system(),
        # A refused read must not look like "no time-dependent fields": that
        # would silently freeze every countdown on the site.
        authorize_with: :error,
        tenant: org_id,
        query: [filter: [field_type: :computed]]
      )
      |> Enum.filter(&Computed.time_dependent?(&1.compute))

    compiled = definitions |> Enum.map(& &1.content_type) |> Enum.reject(&is_nil/1)
    dynamic = definitions |> Enum.map(& &1.type_definition_id) |> Enum.reject(&is_nil/1)

    org_id
    |> ContentTypes.all_for_org()
    |> Enum.filter(fn
      %{source: :dynamic, definition: %{id: id}} -> id in dynamic
      %{type: type} -> type in compiled
    end)
  end

  defp refresh_type(descriptor, org_id, today, batch) do
    Stream.unfold(:start, fn
      :done ->
        nil

      cursor ->
        case page(descriptor, org_id, cursor, batch) do
          [] -> nil
          records when length(records) < batch -> {records, :done}
          records -> {records, List.last(records).id}
        end
    end)
    |> Stream.flat_map(& &1)
    |> Enum.count(&(refresh(&1, org_id, today) == :written))
  end

  # Read without a policy check, as `KilnCMS.Firing.Sweep` and
  # `KilnCMS.Events.Sweep` do: a system grant on the content READ policy would
  # hand every system caller every document on the site. The WRITE goes
  # through the policies, as the `:computed_fields` actor.
  defp page(descriptor, org_id, cursor, batch) do
    filter =
      case cursor do
        :start -> [state: :published]
        last_id -> [state: :published, id: [greater_than: last_id]]
      end

    ContentTypes.list!(descriptor,
      # authorize?: false — one tenant, published rows of one type only, and it
      # must see audience-gated and passphrase-locked records too.
      authorize?: false,
      tenant: org_id,
      query: [filter: filter, sort: [id: :asc], limit: batch]
    )
  end

  @doc """
  Re-derive one record's computed fields on `today`. Writes (and so re-fires)
  only when a value moves: `:written`, `:unchanged`, or `{:error, reason}` —
  a stale read (an editor saved since) is an error the next run simply
  doesn't meet, because that save derived its own value.
  """
  @spec refresh(struct(), Ash.UUID.t(), Date.t()) :: :written | :unchanged | {:error, term()}
  def refresh(record, org_id, %Date{} = today) do
    changeset =
      Ash.Changeset.for_update(record, :refresh_computed, %{},
        actor: system(),
        tenant: org_id,
        context: Computed.Context.pinned_context(today)
      )

    if Ash.Changeset.changing_attribute?(changeset, :custom_fields) do
      case Ash.update(changeset) do
        {:ok, _record} ->
          :written

        {:error, reason} ->
          Logger.warning(
            "computed daily refresh: #{inspect(record.id)} not refreshed: " <>
              Exception.message(Ash.Error.to_error_class(reason))
          )

          {:error, reason}
      end
    else
      :unchanged
    end
  end

  defp system, do: KilnCMS.SystemActor.new(:computed_fields)
end
