defmodule KilnCMS.Backups.Lock.Actions.RequestScheduled do
  @moduledoc """
  `KilnCMS.Backups.Lock`'s `:request_scheduled` action (part of #2219): ask
  for the backups the given schedules are due for at `at`, and claim their
  windows in the same transaction as the request.

  The `:backups` system actor's alone (`KilnCMS.Backups.Scheduler`, or a
  release console as `KilnCMS.Backups.system/0`). The person-callable
  `:request` stays closed to the scheduled fields, so no person can forge a
  scheduled run that keep N (#2219, part 3) would count.

  ## What it does

    1. Refuses an `at` more than 60 s ahead of the node clock
       (`:future_at`): windows are claimed for good, and a future `at` would
       claim windows that have not happened.
    2. Reads the schedules (fails closed: `{:schedules, error}`).
    3. Takes each enabled schedule's due window
       (`KilnCMS.Backups.Schedule.Window`). A schedule whose window can't be
       computed is skipped and reported in `invalid`.
    4. Narrows each to the components this deployment has
       (`Backups.expected_components/0`): a database and media schedule with
       no media directory backs up the database (`narrowed`); a media-only
       one has nothing to back up, and its window is refused
       (`"no_media_dir"`).
    5. When backups can't run here (`Backups.availability/0`), refuses every
       due window with the reason: claimed, so nothing asks again until the
       next window.
    6. Asks for **one** backup covering every due schedule, with the claims
       (`Backups.claim_backup_schedule_window/3`) inside the lock
       transaction (`KilnCMS.Backups.Chain.request/1`'s `:claim`). Schedules
       due in the same minute make one backup, not one queued behind another.

  ## Outcomes

    * Started, queued or folded: every due window is claimed with that
      outcome, in the commit that starts, queues or folds the backup.
    * A window already taken (another node, a pause or an edit since the
      read; the claim matches zero rows): everything rolls back, and the
      schedules are read and tried again, at most twice more; then
      `:nothing_due`.
    * Refused for now, `{:queue_busy, _}` (a Resume is queued, #2540), a step
      conflict, any other error, or an exception: nothing is claimed, and the
      window stays due for the next tick. Each schedule is noted as
      `:deferred` once per window (`first?` says whether this call did).
    * Backups unavailable (a race with step 5): refused as in step 5.

  Returns `%{status, chain, claimed, refused, deferred, narrowed, missed,
  invalid}`; see `KilnCMS.Backups.request_scheduled/3`.
  """
  use Ash.Resource.Actions.Implementation

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Chain, Lock, Refused, Schedule}
  alias KilnCMS.Backups.Schedule.Window

  require Ash.Query
  require Logger

  @future_slack_s 60
  @retries 2
  @unavailable [:disabled, :no_database_url, :no_pg_dump, :no_pg_restore]

  @impl true
  def run(input, _opts, _context) do
    ids = Ash.ActionInput.get_argument(input, :schedule_ids)
    at = Ash.ActionInput.get_argument(input, :at)

    with :ok <- check_at(at),
         {:ok, schedules} <- load(ids) do
      {:ok, fire(schedules, at)}
    end
  end

  defp check_at(at) do
    if DateTime.diff(at, DateTime.utc_now(), :second) > @future_slack_s,
      do: refused(:future_at),
      else: :ok
  end

  defp load(ids) do
    query = Schedule |> Ash.Query.filter(id in ^ids) |> Ash.Query.sort(id: :asc)

    case Backups.list_backup_schedules(
           query: query,
           actor: Backups.system(),
           authorize_with: :error
         ) do
      {:ok, schedules} -> {:ok, schedules}
      {:error, error} -> refused({:schedules, error.__struct__})
    end
  end

  defp fire(schedules, at) do
    {due, invalid} = due(schedules, at)

    result = %{
      status: :nothing_due,
      chain: nil,
      claimed: [],
      refused: [],
      deferred: [],
      narrowed: [],
      missed: for({s, w, _c} <- due, missed?(s, w), do: s.id),
      invalid: invalid
    }

    {runnable, media_less} = Enum.split_with(due, fn {_s, _w, components} -> components != [] end)

    result = %{
      result
      | narrowed: for({s, _w, c} <- runnable, c != s.components, do: s.id),
        refused: Enum.map(media_less, fn {s, w, _c} -> refuse(s, w, :no_media_dir) end)
    }

    result = if media_less != [], do: %{result | status: :refused}, else: result

    cond do
      runnable == [] ->
        result

      match?({:error, _}, Backups.availability()) ->
        {:error, reason} = Backups.availability()
        refuse_all(result, runnable, reason)

      true ->
        request(result, runnable, at, @retries)
    end
  end

  # `{[{schedule, window, effective_components}], invalid_ids}`. A paused
  # schedule is never due. A schedule that raises is as invalid as one that
  # can't be computed: one bad row must not stop the others.
  defp due(schedules, at) do
    expected = Backups.expected_components()

    schedules
    |> Enum.filter(& &1.enabled)
    |> Enum.reduce({[], []}, fn s, {due, invalid} ->
      case safe_due(s, at) do
        {:ok, nil} -> {due, invalid}
        {:ok, w} -> {due ++ [{s, w, Enum.filter(s.components, &(&1 in expected))}], invalid}
        {:error, :invalid} -> {due, invalid ++ [s.id]}
      end
    end)
  end

  defp safe_due(s, at) do
    Window.due(s, at)
  rescue
    _error -> {:error, :invalid}
  end

  defp missed?(s, w) do
    Window.missed?(s, w)
  rescue
    _error -> false
  end

  defp request(result, runnable, at, retries) do
    components =
      Enum.filter(Lock.components(), fn c -> Enum.any?(runnable, &(c in elem(&1, 2))) end)

    attrs = %{
      trigger: "schedule",
      components: components,
      scheduled: components,
      schedule_ids: Enum.map(runnable, fn {s, _w, _c} -> s.id end),
      claim: &claim_all(runnable, &1)
    }

    case safe_request(attrs) do
      {:ok, %{status: status, chain: chain}} ->
        %{
          result
          | status: status,
            chain: chain,
            claimed: Enum.map(runnable, fn {s, w, _c} -> {s.id, w} end)
        }

      {:error, :window_taken} when retries > 0 ->
        retry(result, runnable, at, retries)

      {:error, :window_taken} ->
        result

      {:error, reason} when reason in @unavailable ->
        refuse_all(result, runnable, reason)

      {:error, reason} ->
        defer_all(result, runnable, reason)
    end
  end

  # Another node claimed a window (or a schedule was paused or edited) since
  # the read: read the rest again; what is still due is asked for again.
  defp retry(result, runnable, at, retries) do
    ids = Enum.map(runnable, fn {s, _w, _c} -> s.id end)

    with {:ok, schedules} <- load(ids),
         {still_due, _invalid} <- due(schedules, at),
         [_ | _] = runnable <- Enum.filter(still_due, fn {_s, _w, c} -> c != [] end) do
      request(result, runnable, at, retries - 1)
    else
      _nothing_due_or_unreadable -> result
    end
  end

  defp safe_request(attrs) do
    Chain.request(attrs)
  rescue
    error -> {:error, {:crashed, error.__struct__}}
  end

  # Inside the lock transaction, after `Chain.decide/2` succeeded. Stops at
  # the first error and returns it, so `Chain.with_lock/1` rolls the whole
  # transaction back (the decision, its Lock write and its `Oban.insert/2`
  # with it). Never rescue an error here and carry on: a failed statement
  # aborts the PostgreSQL transaction, and every later statement in it fails.
  defp claim_all(runnable, status) do
    Enum.reduce_while(runnable, :ok, fn {s, w, _c}, :ok ->
      case Backups.claim_backup_schedule_window(s, %{window_at: w, outcome: status},
             actor: Backups.system(),
             return_notifications?: true
           ) do
        {:ok, _schedule, _notifications} -> {:cont, :ok}
        {:ok, _schedule} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, claim_error(error)}}
      end
    end)
  end

  defp claim_error(%{errors: errors} = error) do
    if Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)),
      do: :window_taken,
      else: {:claim, error.__struct__}
  end

  defp claim_error(error), do: {:claim, error}

  defp refuse_all(result, runnable, reason) do
    %{
      result
      | status: :refused,
        refused: result.refused ++ Enum.map(runnable, fn {s, w, _c} -> refuse(s, w, reason) end)
    }
  end

  defp defer_all(result, runnable, reason) do
    %{
      result
      | status: :deferred,
        deferred: Enum.map(runnable, fn {s, w, _c} -> defer(s, w, reason) end)
    }
  end

  defp refuse(s, w, reason) do
    first? =
      write(fn ->
        Backups.refuse_backup_schedule_window(s, %{window_at: w, reason: text(reason)},
          actor: Backups.system()
        )
      end)

    {s.id, w, reason, first?}
  end

  defp defer(s, w, reason) do
    first? =
      write(fn ->
        Backups.note_backup_schedule_deferred(s, %{window_at: w, reason: text(reason)},
          actor: Backups.system()
        )
      end)

    {s.id, w, reason, first?}
  end

  # Whether the write landed: zero rows (already noted, or claimed meanwhile)
  # and a failed write are both "not first". Outside any transaction, so one
  # failing does not stop the next.
  defp write(fun) do
    match?({:ok, _}, fun.())
  rescue
    error ->
      Logger.warning("Couldn't record a backup schedule's window: #{Exception.message(error)}")
      false
  end

  @doc false
  # The `last_error` text of a refused or deferred window.
  @spec text(term()) :: String.t()
  def text({:queue_busy, {:resume, stamp}}), do: "queue_busy: a resume of #{stamp} is queued"
  def text({:queue_busy, kind}), do: "queue_busy: #{inspect(kind)}"
  def text(reason) when is_atom(reason), do: Atom.to_string(reason)
  def text(reason), do: inspect(reason)

  defp refused(reason), do: {:error, Refused.exception(reason: reason)}
end
