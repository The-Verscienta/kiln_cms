defmodule KilnCMS.Backups.Notices do
  @moduledoc """
  Writes the backup problems an operator must hear about (#2487, #2931) as
  `KilnCMS.Backups.Notice` rows, for `KilnCMS.Backups.status/0` to read.

    * `retention/3`, from the prune and off-site steps: a pass that was
      skipped or stopped part-way reports its place; a clean pass over the
      same place clears it.
    * `held_deleted/2`, from retention's hold sync: backups a schedule keeps
      that were deleted outside the app.

  ## Never in the way of a backup

  A notice is what a backup *says*, never what it *does*: every function here
  returns `:ok` whatever happens, and a write that fails is logged ("Backup
  notice not recorded: …") and counted (`[:kiln_cms, :backups, :notice,
  :failed]`), and the report is lost. The log line and telemetry the caller
  already emitted for the problem itself still stand.

  Each write goes through `KilnCMS.AfterCommit.run/1`: at once when no
  transaction is open (the prune and finish steps run outside one), or after
  COMMIT inside `KilnCMS.AfterCommit.deferring/1` (the marker sync, under the
  backup lock's transaction, ADR 0045), so a failed statement here can never
  abort a transaction it does not own. Reads and writes are
  `KilnCMS.Backups.system/0`'s; the read uses `authorize_with: :error`.

  ## Scopes

  A local directory is `"local:<dir id>"` when it has a `.kiln-dir-id`
  (`KilnCMS.Backups.DirId.current/1`), else `"local"`: directories without an
  id share that one row, since nothing else tells them apart. A stored
  destination is `"dest:<id>"`, its key.

  A clean local pass clears both `"local:<dir id>"` and `"local"`, so a
  notice written while the id couldn't be read doesn't outlive the problem.
  A local retention notice therefore clears only on the next in-app backup
  whose retention runs cleanly in that directory: nothing else looks at it.
  """

  require Ash.Query
  require Logger

  alias KilnCMS.{AfterCommit, Backups}
  alias KilnCMS.Backups.{DirId, Retention}
  alias KilnCMS.Backups.Notice.Changes.Normalize

  # How long a held-deleted notice shows, and how long a later detection in
  # the same scope merges into it: as long as `Backups.status/0` looks back
  # for cron evidence.
  @held_deleted_days 8

  @typedoc "Where retention ran: a local backup directory, or a stored destination."
  @type scope :: {:local, Path.t()} | {:destination, String.t(), String.t() | nil}

  @typedoc "How the pass went."
  @type result :: :ok | {:skipped, term()} | {:stopped, term(), non_neg_integer()}

  @typedoc "A held backup found deleted: its stamp and kind."
  @type unit :: %{stamp: String.t(), kind: :db | :media}

  @doc "How many days a held-deleted notice is shown and merged into."
  @spec held_deleted_days() :: pos_integer()
  def held_deleted_days, do: @held_deleted_days

  @doc """
  Record how retention went over `scope`: `:ok` clears the scope's retention
  notice; `{:skipped, reason}` and `{:stopped, reason, deleted}` report it,
  with `reason` as `KilnCMS.Backups.Retention.describe/1` words it.

  Options: `:stamp`, the backup whose prune it was. Always `:ok`.
  """
  @spec retention(scope(), result(), keyword()) :: :ok
  def retention(scope, result, opts \\ []) do
    AfterCommit.run(fn -> guarded(:retention, fn -> write_retention(scope, result, opts) end) end)
  end

  @doc """
  Record that `units` held by a schedule's keep rule in the backup directory
  `dir` were deleted outside the app. Nothing for `[]`.

  The notice lists the first ten as `"<kind>:<stamp>"` and counts them all
  in `total`. A notice of the same scope from the last
  #{@held_deleted_days} days is merged into rather than replaced: its units
  come first, a unit already listed is not listed or counted twice, and `at`
  moves to now. When that notice can't be read, this detection replaces it
  (the newest is the one to show). Always `:ok`.
  """
  @spec held_deleted(Path.t(), [unit()]) :: :ok
  def held_deleted(_dir, []), do: :ok

  def held_deleted(dir, units) when is_list(units) do
    AfterCommit.run(fn -> guarded(:held_deleted, fn -> write_held_deleted(dir, units) end) end)
  end

  @doc """
  The notice scope of a local backup directory or a stored destination, as
  `{scope, dir_id}`.
  """
  @spec scope_key(scope()) :: {String.t(), String.t() | nil}
  def scope_key({:local, dir}) do
    case DirId.current(dir) do
      {:ok, id} -> {"local:" <> id, id}
      {:error, _none_or_malformed} -> {"local", nil}
    end
  end

  def scope_key({:destination, key, _label}), do: {key, nil}

  defp write_retention(scope, :ok, _opts) do
    scope |> clear_keys() |> Enum.reduce_while(:ok, &clear_retention/2)
  end

  defp write_retention(scope, {:skipped, reason}, opts),
    do: report_retention(scope, :skipped, reason, nil, opts)

  defp write_retention(scope, {:stopped, reason, deleted}, opts),
    do: report_retention(scope, :stopped, reason, deleted, opts)

  defp report_retention(scope, outcome, reason, deleted, opts) do
    {key, dir_id} = scope_key(scope)

    report(%{
      kind: :retention,
      scope: key,
      dir_id: dir_id,
      label: label(scope),
      outcome: outcome,
      reason: Retention.describe(reason),
      deleted: deleted,
      stamp: opts[:stamp],
      units: [],
      total: nil,
      at: DateTime.utc_now()
    })
  end

  # A clean local pass also clears `"local"`: a notice written there while the
  # directory's id couldn't be read would otherwise outlive the problem.
  defp clear_keys({:local, _dir} = scope) do
    case scope_key(scope) do
      {"local", nil} -> ["local"]
      {key, _dir_id} -> [key, "local"]
    end
  end

  defp clear_keys(scope), do: [scope |> scope_key() |> elem(0)]

  defp clear_retention(key, :ok) do
    case Backups.clear_backup_notices(:retention, key,
           actor: Backups.system(),
           bulk_options: [return_errors?: true]
         ) do
      %Ash.BulkResult{status: :success} -> {:cont, :ok}
      %Ash.BulkResult{errors: errors} -> {:halt, {:error, errors}}
    end
  end

  defp label({:destination, _key, label}), do: label
  defp label({:local, _dir}), do: nil

  defp write_held_deleted(dir, units) do
    {key, dir_id} = scope_key({:local, dir})
    now = DateTime.utc_now()
    found = units |> Enum.map(&"#{&1.kind}:#{&1.stamp}") |> Enum.uniq()
    {listed, total} = merge(earlier_held_deleted(key, now), found)

    report(%{
      kind: :held_deleted,
      scope: key,
      dir_id: dir_id,
      label: nil,
      outcome: nil,
      reason: nil,
      deleted: nil,
      stamp: nil,
      units: listed,
      total: total,
      at: now
    })
  end

  # The scope's held-deleted notice, when it is recent enough to merge into.
  defp earlier_held_deleted(key, now) do
    since = DateTime.add(now, -@held_deleted_days * 86_400, :second)

    query =
      KilnCMS.Backups.Notice
      |> Ash.Query.filter(kind == :held_deleted and scope == ^key and at >= ^since)

    case Backups.list_backup_notices(
           query: query,
           actor: Backups.system(),
           authorize_with: :error
         ) do
      {:ok, [notice | _]} ->
        notice

      {:ok, []} ->
        nil

      {:error, error} ->
        Logger.warning(
          "Backup notice of a held backup deleted outside the app replaces the earlier " <>
            "one: it could not be read (#{inspect(error.__struct__)})"
        )

        nil
    end
  end

  defp merge(nil, found), do: {Enum.take(found, Normalize.max_units()), length(found)}

  defp merge(earlier, found) do
    new = found -- earlier.units

    {Enum.take(earlier.units ++ new, Normalize.max_units()),
     (earlier.total || length(earlier.units)) + length(new)}
  end

  defp report(attrs) do
    case Backups.report_backup_notice(attrs, actor: Backups.system()) do
      {:ok, _notice} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  # This runs from a backup step and from the marker sync: whatever a write
  # does, a raise or an exit included (a lost database connection), it must
  # not reach them, so this is the boundary that stops it.
  defp guarded(kind, fun) do
    case fun.() do
      :ok -> :ok
      {:error, error} -> failed(kind, error)
    end
  rescue
    error -> failed(kind, error)
  catch
    :exit, reason -> failed(kind, {:exit, reason})
  end

  defp failed(kind, error) do
    Logger.warning("Backup notice not recorded (#{kind}): #{describe_error(error)}")
    :telemetry.execute([:kiln_cms, :backups, :notice, :failed], %{count: 1}, %{kind: kind})
    :ok
  end

  defp describe_error(%{__exception__: true} = error), do: inspect(error.__struct__)

  defp describe_error([%{__exception__: true} | _] = errors),
    do: Enum.map_join(errors, ", ", &inspect(&1.__struct__))

  defp describe_error(other), do: inspect(other, limit: 5, printable_limit: 200)
end
