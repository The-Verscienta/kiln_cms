defmodule KilnCMS.Backups.Uploads do
  @moduledoc """
  Resumable uploads to backup destinations (#2223): the core's side of
  `Kiln.BackupDestination.Resume`, around each `put/3` the off-site step
  makes, and the sweep that aborts what was left behind.

    * `handle/3`, before a put: the options the adapter gets. Always
      `:deadline`; `:resume` too when the destination is a stored one whose
      adapter is resumable (`KilnCMS.Backups.Destination.resumable?/1`). An
      open upload of the same file there is claimed and its checkpoint handed
      back; one of a file that has since changed is abandoned and aborted,
      and the upload starts over;
    * `settle/3`, after it: what the outcome means for the recorded upload
      (`KilnCMS.Backups.Upload`). Arrived: completed. Already on the
      destination: completed, or, when an upload was under way, aborted. A
      permanent failure: abandoned and aborted. Anything else (a timeout, a
      transient error): kept open, with the error, for the next attempt;
    * `sweep/4`, after a destination is reached: aborts the uploads recorded
      there that were abandoned or left untouched for four days, and deletes
      closed rows a month old.

  An upload is recorded lazily, on the adapter's first `save`, so a put that
  never saves leaves no row. Ownership is the step's Oban job id and attempt
  (`owner/1`), compared as integers by the `Upload` actions themselves: a
  step that lost its lease gets `{:error, :superseded}` from `save` and never
  overwrites the progress of the step that took over.

  Only uploads this installation recorded are ever aborted: nothing here
  lists a store's own pending uploads. A row records the backup directory
  whose step opened it (`dir_id`): a step of another directory neither
  takes it over nor abandons it (its put is sent whole, recording nothing),
  and a sweep on a node with another directory leaves it, so a database
  restored on another server never resumes or aborts the original server's
  uploads. A row from before `dir_id` was recorded is any directory's.
  """

  alias Kiln.BackupDestination.{Config, Resume}
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Chain, Destination, DirId, Upload}

  require Logger

  # A checkpoint is the adapter's own small state, never a file's content.
  @max_checkpoint_bytes 8 * 1024

  # An open upload untouched this long is the sweep's to abort: longer than
  # any backup's retries, reclaims and the work-directory sweep (3 days).
  @idle_days 4

  # Closed rows, and a deleted destination's, are kept this long.
  @purge_days 30

  # At most this many aborts per sweep, each bounded by the step's deadline.
  @sweep_batch 50

  # The sweep stops starting aborts this close to the deadline.
  @sweep_margin_ms :timer.seconds(30)

  # The bound on each of the sweep's aborts (#2950), and the step's deadline
  # when that comes first: one hung abort costs the sweep, not the step.
  @abort_call_ms :timer.seconds(60)

  @typedoc "The step an upload is owned by: its Oban job id and attempt."
  @type owner :: %{job_id: integer(), attempt: non_neg_integer()}

  @typedoc """
  Where a put goes, as the off-site step knows it: the destination's
  `KilnCMS.Backups.Destination.target_key/2` (`nil` for the env destination, which never
  resumes), the step's `owner/1`, its deadline, the backup's stamp and the
  `.kiln-dir-id` of the backup directory the step runs in (`nil` when
  unknown).
  """
  @type target :: %{
          required(:key) => String.t() | nil,
          required(:owner) => owner(),
          required(:deadline) => integer(),
          required(:stamp) => String.t() | nil,
          optional(:dir_id) => String.t() | nil
        }

  @typedoc "What `settle/3` needs to know about a put `handle/3` prepared."
  @type info :: %{
          required(:resumable?) => boolean(),
          optional(atom()) => term()
        }

  @doc """
  The owner a step's lease stands for: its job id, and its attempt, with a
  step run by hand (attempt `nil` or 0) counted as attempt 0.
  """
  @spec owner(%{job_id: integer(), attempt: integer() | nil}) :: owner()
  def owner(%{job_id: job_id, attempt: attempt}) when is_integer(attempt) and attempt > 0,
    do: %{job_id: job_id, attempt: attempt}

  def owner(%{job_id: job_id}), do: %{job_id: job_id, attempt: 0}

  @doc "The most a checkpoint may take, JSON-encoded, in bytes."
  @spec max_checkpoint_bytes() :: pos_integer()
  def max_checkpoint_bytes, do: @max_checkpoint_bytes

  ## Before a put

  @doc """
  The options `put/3` gets for `put` (a `t:Kiln.BackupDestination.file/0`)
  on `config`, and what `settle/3` needs afterwards:

    * `{:ok, opts, info}` — `opts` always has `:deadline`, and `:resume` when
      the upload is resumable;
    * `{:error, :superseded}` — the file's open upload there belongs to a
      newer step: this one has lost its lease and must not send.
  """
  @spec handle(Config.t(), map(), target()) ::
          {:ok, keyword(), info()} | {:error, :superseded}
  def handle(%Config{id: id} = config, put, %{key: key, deadline: deadline} = target)
      when is_binary(key) and is_binary(id) do
    if Destination.resumable?(config) do
      resumable(config, put, target)
    else
      if Destination.supports?(config, [:resume]) do
        Logger.debug(
          "Backup destination #{config.kind} declares :resume without abort_upload/3; " <>
            "its uploads are not resumed"
        )
      end

      {:ok, [deadline: deadline], %{resumable?: false}}
    end
  end

  def handle(_config, _put, %{deadline: deadline}),
    do: {:ok, [deadline: deadline], %{resumable?: false}}

  defp resumable(config, put, target) do
    info = %{
      resumable?: true,
      key: target.key,
      owner: target.owner,
      deadline: target.deadline,
      destination_id: config.id,
      stamp: target.stamp,
      dir_id: target[:dir_id],
      put: Map.take(put, [:subdir, :name, :bytes, :sha256]),
      resumed?: false,
      resumed_from_bytes: 0
    }

    case open_row(info) do
      {:ok, nil} ->
        {:ok, opts(info, nil), info}

      {:ok, row} ->
        if this_directory?(row, info.dir_id),
          do: take_over(config, row, info),
          else: another_directory(row, info)

      {:error, error} ->
        # Can't tell what is recorded: send whole, as before #2223, and
        # record nothing.
        Logger.warning(
          "Backup off-site: couldn't read the resumable uploads (#{short(error)}); " <>
            "#{put.name} is sent whole"
        )

        {:ok, [deadline: target.deadline], %{resumable?: false}}
    end
  end

  # Another backup directory's open upload of this file (see the
  # moduledoc): left as it is, and this put sent whole, recording nothing,
  # since `:unique_open` allows one open row per file.
  defp another_directory(row, info) do
    Logger.warning(
      "Backup off-site: #{row.name} has an unfinished upload started from another backup " <>
        "directory; it is left as it is, and the file is sent whole"
    )

    {:ok, [deadline: info.deadline], %{resumable?: false}}
  end

  # A row is this directory's when it records this directory, or none (a row
  # from before `dir_id` was recorded).
  defp this_directory?(%Upload{dir_id: nil}, _dir_id), do: true
  defp this_directory?(%Upload{dir_id: dir_id}, dir_id) when is_binary(dir_id), do: true
  defp this_directory?(_row, _dir_id), do: false

  defp take_over(config, row, info) do
    case claim(row, info.owner) do
      {:ok, row} ->
        if row.bytes == info.put.bytes and row.sha256 == info.put.sha256 do
          info = %{
            info
            | resumed?: row.checkpoint != nil,
              resumed_from_bytes: if(row.checkpoint, do: row.bytes_done, else: 0)
          }

          {:ok, opts(info, row), info}
        else
          changed(config, row, info)
        end

      {:error, :superseded} ->
        {:error, :superseded}

      {:error, error} ->
        Logger.warning(
          "Backup off-site: couldn't take over the upload of #{row.name} (#{short(error)}); " <>
            "it is sent whole"
        )

        {:ok, [deadline: info.deadline], %{resumable?: false}}
    end
  end

  # The file changed since that upload started: what it sent is of another
  # file. Abandoned first, so a failed abort is the sweep's, then the upload
  # starts over. If it can't be abandoned, the row would still be open with
  # the old file's metadata, and a fresh upload's progress would land in it:
  # this put is sent whole and records nothing instead.
  defp changed(config, row, info) do
    case give_up(config, row, info, :open, "the file changed; the upload started over") do
      :ok ->
        {:ok, opts(info, nil), info}

      {:error, :superseded} ->
        {:error, :superseded}

      {:error, error} ->
        Logger.warning(
          "Backup off-site: couldn't abandon the upload of #{row.name}, whose file changed " <>
            "(#{short(error)}); it is sent whole"
        )

        {:ok, [deadline: info.deadline], %{resumable?: false}}
    end
  end

  defp opts(info, row) do
    resume = %Resume{
      checkpoint: row && row.checkpoint,
      attempt: (row && row.attempts) || 1,
      save: saver(info, row && row.id)
    }

    [deadline: info.deadline, resume: resume]
  end

  # The `save` an adapter gets. It runs in the adapter's process and holds
  # only the row's id, the owner and the file's metadata: no config, no
  # secret. The first save of a fresh upload records it.
  defp saver(info, row_id) do
    fields = Map.take(info, [:key, :owner, :destination_id, :stamp, :dir_id, :put])
    fn checkpoint -> save(fields, row_id, checkpoint) end
  end

  @doc false
  # `Resume.save`: validate, then write as the owner.
  @spec save(map(), Ecto.UUID.t() | nil, term()) :: :ok | {:error, term()}
  def save(fields, row_id, checkpoint) do
    with {:ok, checkpoint} <- valid_checkpoint(checkpoint) do
      case row_id || cached_row_id(fields) do
        nil -> open(fields, checkpoint)
        id -> write_checkpoint(fields, id, checkpoint)
      end
    end
  end

  defp valid_checkpoint(checkpoint) when is_map(checkpoint) do
    case Jason.encode(checkpoint) do
      {:ok, json} when byte_size(json) <= @max_checkpoint_bytes ->
        {:ok, Jason.decode!(json)}

      {:ok, _json} ->
        {:error, "the upload checkpoint is larger than #{@max_checkpoint_bytes} bytes"}

      {:error, _error} ->
        {:error, "the upload checkpoint can't be stored as JSON"}
    end
  end

  defp valid_checkpoint(_other), do: {:error, "the upload checkpoint must be a map"}

  defp bytes_done(%{"bytes_done" => done}) when is_integer(done) and done >= 0, do: done
  defp bytes_done(_checkpoint), do: 0

  # A row this process opened earlier in the same put.
  defp cached_row_id(fields), do: Process.get(cache_key(fields))

  defp cache_key(%{key: key, owner: owner, put: put}),
    do: {__MODULE__, key, put.subdir, put.name, owner.job_id, owner.attempt}

  defp open(fields, checkpoint) do
    attrs = %{
      destination_key: fields.key,
      destination_id: fields.destination_id,
      subdir: fields.put.subdir,
      name: fields.put.name,
      stamp: fields.stamp,
      bytes: fields.put.bytes,
      sha256: fields.put.sha256,
      checkpoint: checkpoint,
      bytes_done: bytes_done(checkpoint),
      owner_job_id: fields.owner.job_id,
      owner_attempt: fields.owner.attempt,
      dir_id: fields[:dir_id]
    }

    case Backups.open_backup_upload(attrs, actor: Backups.system()) do
      {:ok, row} ->
        Process.put(cache_key(fields), row.id)
        :ok

      {:error, error} ->
        # Another step opened this file's upload first (`:unique_open`). An
        # older step's row is this one's to take over, as `handle/3` would
        # have; a newer step's (or another attempt's) owns it, and this one
        # stops. Any other failure is said as itself.
        case open_row(fields) do
          {:ok, %Upload{} = row} -> open_taken(fields, row, checkpoint)
          _none_or_unreadable -> {:error, "couldn't record the upload (#{short(error)})"}
        end
    end
  end

  # Another backup directory's row is never taken (see the moduledoc).
  defp open_taken(fields, row, checkpoint) do
    if this_directory?(row, fields[:dir_id]),
      do: open_taken_here(fields, row, checkpoint),
      else: {:error, "another backup directory's upload of #{row.name} is still open"}
  end

  defp open_taken_here(fields, row, checkpoint) do
    cond do
      owned_by?(row, fields.owner) ->
        Process.put(cache_key(fields), row.id)
        write_checkpoint(fields, row.id, checkpoint)

      not older?(row, fields.owner) ->
        {:error, :superseded}

      row.bytes != fields.put.bytes or row.sha256 != fields.put.sha256 ->
        # An older step's upload of another version of the file: the next
        # attempt abandons it (`handle/3`); this one stops.
        {:error, "an earlier upload of a different version of #{row.name} is still open"}

      true ->
        case claim(row, fields.owner) do
          {:ok, row} ->
            Process.put(cache_key(fields), row.id)
            write_checkpoint(fields, row.id, checkpoint)

          {:error, :superseded} = superseded ->
            superseded

          {:error, error} ->
            {:error, "couldn't take over the upload (#{short(error)})"}
        end
    end
  end

  defp owned_by?(row, owner),
    do: row.owner_job_id == owner.job_id and row.owner_attempt == owner.attempt

  # The row's owner is an older step than `owner`: an earlier job, or an
  # earlier attempt of the same one.
  defp older?(row, owner) do
    row.owner_job_id < owner.job_id or
      (row.owner_job_id == owner.job_id and row.owner_attempt < owner.attempt)
  end

  defp write_checkpoint(fields, id, checkpoint) do
    result =
      Backups.save_backup_upload_checkpoint(
        %Upload{id: id},
        %{
          job_id: fields.owner.job_id,
          attempt: fields.owner.attempt,
          checkpoint: checkpoint,
          bytes_done: bytes_done(checkpoint)
        },
        actor: Backups.system()
      )

    case result do
      {:ok, _row} -> :ok
      {:error, error} -> stale_or(error, "couldn't record the upload's progress")
    end
  end

  ## After a put

  @doc """
  Settles the recorded upload of a put `handle/3` prepared, by its `result`
  (`KilnCMS.Backups.Destination.call/4`'s answer). Returns `:ok`; a failure
  to record is logged, never the put's outcome.
  """
  @spec settle(Config.t(), info(), term()) :: :ok
  def settle(_config, %{resumable?: false}, _result), do: :ok
  def settle(_config, _info, {:error, :superseded}), do: :ok

  def settle(config, info, result) do
    case owned_row(info) do
      nil -> :ok
      row -> settle_row(config, info, row, result)
    end
  end

  defp settle_row(_config, info, row, :ok), do: complete(row, info)

  defp settle_row(_config, info, %Upload{checkpoint: nil} = row, {:ok, :already_present}),
    do: complete(row, info)

  # Already there, with an upload of it under way: that upload is not needed.
  defp settle_row(config, info, row, {:ok, :already_present}) do
    _ = give_up(config, row, info, :open, "the file was already on the destination")
    :ok
  end

  defp settle_row(config, info, row, {:error, {:permanent, message}}) do
    _ = give_up(config, row, info, :open, message)
    :ok
  end

  defp settle_row(_config, info, row, {:error, reason}) do
    Backups.note_backup_upload_error(
      row,
      %{
        job_id: info.owner.job_id,
        attempt: info.owner.attempt,
        last_error: cut(Destination.format_reason(reason))
      },
      actor: Backups.system()
    )
    |> logged("note the error of", row)
  end

  defp settle_row(_config, _info, _row, _other), do: :ok

  # The open row of this put's file, if this step owns it.
  defp owned_row(info) do
    case open_row(info) do
      {:ok, %Upload{owner_job_id: job, owner_attempt: attempt} = row}
      when job == info.owner.job_id and attempt == info.owner.attempt ->
        row

      _other_owner_none_or_unreadable ->
        nil
    end
  end

  defp complete(row, info) do
    row
    |> Backups.complete_backup_upload(info.owner.job_id, info.owner.attempt,
      actor: Backups.system()
    )
    |> logged("complete", row)
  end

  # Abandon (so a failed abort is left to the sweep), then abort; aborted
  # once the store says so. `:ok` once abandoned, whatever the abort did;
  # `{:error, :superseded}` when the row was no longer this step's, else the
  # error that kept it from being abandoned.
  defp give_up(config, row, info, from, why) do
    abandoned =
      Backups.abandon_backup_upload(
        row,
        %{
          expected_status: from,
          job_id: info.owner.job_id,
          attempt: info.owner.attempt,
          last_error: cut(why)
        },
        actor: Backups.system()
      )

    case abandoned do
      {:ok, row} ->
        case abort(config, row, info.deadline) do
          :ok -> mark_aborted(row) |> logged("mark aborted", row)
          {:error, _reason} -> :ok
        end

      {:error, error} = failed ->
        logged(failed, "abandon", row)
        if stale?(error), do: {:error, :superseded}, else: {:error, error}
    end
  end

  defp abort(config, row, deadline) do
    upload = %{subdir: row.subdir, name: row.name, checkpoint: row.checkpoint}

    case Destination.call(config, :abort_upload, [upload, [deadline: deadline]],
           deadline: deadline
         ) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning(
          "Backup off-site: couldn't abort the upload of #{row.name} on #{config.key} " <>
            "(#{Destination.format_reason(reason)}); the upload sweep tries again"
        )

        error

      _other ->
        {:error, :unexpected}
    end
  end

  # From the status (and owner) read: a row someone else moved on is left.
  defp mark_aborted(row) do
    Backups.mark_backup_upload_aborted(
      row,
      %{expected_status: row.status, job_id: row.owner_job_id, attempt: row.owner_attempt},
      actor: Backups.system()
    )
  end

  defp logged({:ok, _row}, _what, _row_before), do: :ok

  defp logged({:error, error}, what, row) do
    unless stale?(error) do
      Logger.warning(
        "Backup off-site: couldn't #{what} the upload of #{row.name} (#{short(error)})"
      )
    end

    :ok
  end

  ## The sweep

  @doc """
  After `config`'s destination was reached, whatever its `prune`: aborts the
  uploads recorded under `key` (`KilnCMS.Backups.Destination.target_key/2`) that were
  abandoned, or left open and untouched for #{@idle_days} days, at most
  #{@sweep_batch} per pass and none past `deadline`, each abort bounded by
  #{div(@abort_call_ms, 1000)} seconds as well (#2950). Each is marked aborted
  once the store says it is gone; one that can't be aborted is kept
  abandoned for the next pass. The upload of the backup the lock holds is
  never touched, nor one another backup directory opened: only a row whose
  `dir_id` is this node's `.kiln-dir-id` (`opts[:dir]`'s, `BACKUP_DIR` by
  default), or that records none, is swept.

  Then, on every destination, deletes closed rows (and a deleted
  destination's) older than #{@purge_days} days, in one statement.

  `opts[:now]` replaces the clock and `opts[:abort_call_ms]` the bound on
  each abort (tests). Returns what it did, also as the
  `[:kiln_cms, :backups, :upload, :swept]` event.
  """
  @spec sweep(Config.t(), String.t() | nil, integer(), keyword()) :: %{
          aborted: non_neg_integer(),
          failed: non_neg_integer()
        }
  def sweep(%Config{} = config, key, deadline, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    {aborted, failed} =
      if is_binary(key) and Destination.resumable?(config),
        do: abort_owed(config, key, {deadline, abort_call_ms(opts)}, now, current_dir_id(opts)),
        else: {0, 0}

    purge(now)
    result = %{aborted: aborted, failed: failed}

    :telemetry.execute([:kiln_cms, :backups, :upload, :swept], result, %{
      destination: config.key
    })

    result
  end

  defp abort_call_ms(opts), do: Keyword.get(opts, :abort_call_ms, @abort_call_ms)

  # This node's backup-directory id; nil when it can't be read, so only rows
  # that record no directory are swept.
  defp current_dir_id(opts) do
    case DirId.current(Keyword.get_lazy(opts, :dir, &Backups.dir/0)) do
      {:ok, id} -> id
      {:error, _reason} -> nil
    end
  end

  defp abort_owed(config, key, bounds, now, dir_id) do
    idle_before = DateTime.add(now, -@idle_days * 86_400, :second)

    with {:ok, held} <- Chain.fetch_held_stamp(),
         {:ok, rows} <-
           Backups.list_owed_backup_uploads(key, idle_before, %{dir_id: dir_id},
             actor: Backups.system(),
             authorize_with: :error
           ) do
      rows
      |> Enum.reject(&(held != nil and &1.stamp == held))
      |> Enum.reduce_while({0, 0}, &sweep_next(config, &1, bounds, &2))
    else
      {:error, error} ->
        Logger.warning(
          "Backup off-site: the upload sweep on #{config.key} was skipped (#{short(error)})"
        )

        {0, 0}
    end
  end

  # One row, unless the deadline is near.
  defp sweep_next(config, row, {deadline, _per_call} = bounds, {aborted, failed} = counts) do
    if System.monotonic_time(:millisecond) > deadline - @sweep_margin_ms do
      {:halt, counts}
    else
      case sweep_one(config, row, bounds) do
        :aborted -> {:cont, {aborted + 1, failed}}
        :failed -> {:cont, {aborted, failed + 1}}
        :skipped -> {:cont, counts}
      end
    end
  end

  defp sweep_one(config, row, {deadline, per_call_ms}) do
    case abort(config, row, Destination.call_deadline(deadline, per_call_ms)) do
      :ok ->
        case mark_aborted(row) do
          {:ok, _row} -> :aborted
          {:error, _stale_or_failed} -> :skipped
        end

      {:error, reason} ->
        # Kept (or made) abandoned, with why, for the next pass.
        _ =
          Backups.abandon_backup_upload(
            row,
            %{
              expected_status: row.status,
              job_id: row.owner_job_id,
              attempt: row.owner_attempt,
              last_error: cut(Destination.format_reason(reason))
            },
            actor: Backups.system()
          )

        :failed
    end
  end

  defp purge(now) do
    before = DateTime.add(now, -@purge_days * 86_400, :second)

    case Backups.purge_backup_uploads(before,
           actor: Backups.system(),
           bulk_options: [return_errors?: true]
         ) do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{errors: errors} ->
        Logger.warning(
          "Backup off-site: couldn't purge old resumable uploads (#{short(List.first(errors))})"
        )

        :ok
    end
  end

  ## Helpers

  defp open_row(%{key: key, put: put}) do
    Backups.get_open_backup_upload(key, put.subdir, put.name,
      actor: Backups.system(),
      authorize_with: :error
    )
  end

  defp claim(row, owner) do
    case Backups.claim_backup_upload(row, owner.job_id, owner.attempt, actor: Backups.system()) do
      {:ok, row} -> {:ok, row}
      {:error, error} -> stale_or(error, error)
    end
  end

  defp stale_or(error, otherwise) do
    cond do
      stale?(error) -> {:error, :superseded}
      is_binary(otherwise) -> {:error, otherwise <> " (#{short(error)})"}
      true -> {:error, otherwise}
    end
  end

  # A compare-and-swap write that matched no row: someone else moved it on.
  defp stale?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

  defp stale?(_error), do: false

  # The error's module only: an Ash error's message inspects the query.
  defp short(%{__struct__: module}), do: inspect(module)
  defp short(other), do: inspect(other)

  defp cut(text) when is_binary(text), do: String.slice(text, 0, 500)
  defp cut(_other), do: nil
end
