defmodule KilnCMS.Backups.Run.Changes.Cancel do
  @moduledoc """
  The guard and side effects of `KilnCMS.Backups.Run`'s `:cancel` action
  (#2218, D4/D5): stop a running in-app backup.

  Inside the action's transaction (a `before_action` hook), after taking the
  backup lock's advisory lock (`KilnCMS.Backups.Chain.locked_row/0`):

    * when the lock holds this run's chain, its step jobs are canceled
      (`Oban.cancel_all_jobs/2`: an executing one is killed when the
      transaction commits, and `KilnCMS.ExternalCommand`'s watchers kill the
      `pg_dump`, `tar` or `rclone` it started) and the lock is released, which
      starts the queued request if there is one. A chain past the point of no
      return (`phase: :finishing`) is refused: it is about to succeed.
    * when it does not (a `running` row whose chain is gone), the row is just
      marked canceled, which makes it resumable.

  Either way nothing on disk is touched: `manifest.json` keeps whatever the
  last finished backup wrote, and the work directory stays so Resume picks up
  from the files already written. A step killed mid-write finds the run no
  longer `running` and the lock moved on (its advance is superseded). Its Run
  writes get a `StaleRecord` error before and after a Resume: they are
  filtered to `running` and to its own chain (`Changes.OwnChain`, #2538), and
  its `state.json` write to its lease (its rename into place is
  `Chain.fenced_rename/3`, #2818).

  The run's log and error say "Canceled by a platform admin", and so does the
  server log line: the run log is not scrubbed on account erasure (#3029). Who
  canceled is in the audited `backup_canceled` instance event, with the step
  it was on in its metadata (`changeset.context[:backup_step]`).

  A resume that holds the lock but has not re-opened its run yet is not what
  this action is for. While its start snoozes for the server with the run's
  files, the lock holds a chain the run is not on and no stamp yet: marking a
  stale `running` row canceled would leave the resume to re-open it after the
  settle window. So this action is refused then (#3028, "cancel the resume
  instead", on `Run.Changes.CancelResume.waiting?/2`), and `Run`'s
  `:cancel_resume` (`Run.Changes.CancelResume`, #2816), which the Backups page
  offers instead, stops it.

  Nor is a re-send of the run to the destinations it missed (#2949): while
  one holds the lock this action is refused ("cancel the re-send instead"),
  and `Run`'s `:cancel_resend` (`Run.Changes.CancelResend`) stops it.
  """
  use Ash.Resource.Change

  alias KilnCMS.Backups.{Chain, Steps}
  alias KilnCMS.Backups.Run.Changes.CancelResume

  require Logger

  # Never the actor's email: the run log outlives an account's erasure (#3029).
  @canceled "Canceled by a platform admin"

  @impl true
  def change(changeset, _opts, _context) do
    run = changeset.data

    if run.origin != :app do
      Ash.Changeset.add_error(changeset,
        field: :status,
        message: "can't be canceled: only an in-app backup can"
      )
    else
      entry = %{
        at: DateTime.utc_now(),
        level: :warn,
        step: "cancel",
        message: @canceled
      }

      changeset
      |> Ash.Changeset.force_change_attribute(:log, (run.log || []) ++ [entry])
      |> Ash.Changeset.force_change_attribute(:error, @canceled)
      |> Ash.Changeset.before_action(&stop_chain/1)
      |> Ash.Changeset.after_transaction(&announce/2)
    end
  end

  # In the action's transaction: the advisory lock first, so no step can begin,
  # advance or release between the decision and the commit.
  defp stop_chain(changeset) do
    run = changeset.data
    row = Chain.locked_row()

    cond do
      resending?(row, run) ->
        Ash.Changeset.add_error(changeset, field: :status, message: resending())

      CancelResume.waiting?(row, run) ->
        Ash.Changeset.add_error(changeset, field: :status, message: resume_waiting())

      not holds?(row, run) ->
        Ash.Changeset.set_context(changeset, %{backup_step: nil, backup_chain: nil})

      row.phase == :finishing ->
        Ash.Changeset.add_error(changeset,
          field: :status,
          message: "too late to cancel: the backup is finishing"
        )

      true ->
        :ok = Chain.cancel_chain_jobs(row.chain_id)

        case Chain.release_in_txn(row) do
          {:ok, promoted} ->
            Ash.Changeset.set_context(changeset, %{
              backup_step: step_label(row),
              backup_chain: row.chain_id,
              backup_promoted: promoted
            })

          {:error, reason} ->
            Ash.Changeset.add_error(changeset,
              field: :status,
              message: "couldn't start the queued backup: %{reason}",
              vars: [reason: inspect(reason)]
            )
        end
    end
  end

  @doc """
  The refusal while the lock holds a re-send of the run (#2949, critic
  change 9): that one is stopped by `Run`'s `:cancel_resend`, which the
  Backups page offers instead.
  """
  @spec resending() :: String.t()
  def resending, do: "is being re-sent off-site: cancel the re-send instead"

  @doc """
  The refusal while the lock holds a resume of the run that has not re-opened
  it yet (#3028): marking the run canceled would not stop it, `Run`'s
  `:cancel_resume` does.
  """
  @spec resume_waiting() :: String.t()
  def resume_waiting,
    do: "a resume of this backup is waiting to start; cancel the resume instead"

  # A re-send of this run's stamp holds the lock (#2949). The run is
  # `succeeded`, so this action's filter would refuse it anyway, but only
  # after `stop_chain/1` had canceled the re-send's jobs inside the
  # transaction that the refusal then rolls back: refused here first.
  defp resending?(%{chain_id: chain, step: :resend, stamp: stamp}, %{stamp: stamp})
       when is_binary(chain),
       do: true

  defp resending?(_row, _run), do: false

  # The lock works on this run: its chain, or (a resume or retry whose Run
  # write lagged) its stamp.
  defp holds?(%{chain_id: nil}, _run), do: false

  defp holds?(row, run),
    do: (run.chain_id != nil and row.chain_id == run.chain_id) or row.stamp == run.stamp

  defp step_label(%{step: nil}), do: nil
  defp step_label(%{step: :archive, part: part}) when is_integer(part), do: "archive part #{part}"
  defp step_label(%{step: step}), do: to_string(step)

  defp announce(changeset, {:ok, run} = result) do
    step = changeset.context[:backup_step]

    Logger.warning(
      "Backup #{run.stamp} canceled by a platform admin" <>
        if(step, do: " during #{step}", else: "")
    )

    case changeset.context[:backup_chain] do
      nil -> :ok
      chain -> Steps.settled(%{chain: chain, stamp: run.stamp}, {:error, :canceled})
    end

    result
  end

  defp announce(_changeset, result), do: result
end
