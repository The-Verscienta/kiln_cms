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
  longer `running` (its Run writes get a `StaleRecord` error) and the lock
  moved on (its advance is superseded).

  The run is logged as canceled by the actor, with the step it was on in the
  audit event's metadata (`changeset.context[:backup_step]`).
  """
  use Ash.Resource.Change

  import Ecto.Query

  alias KilnCMS.Backups.{Chain, Steps}

  require Logger

  @impl true
  def change(changeset, _opts, context) do
    run = changeset.data

    if run.origin != :app do
      Ash.Changeset.add_error(changeset,
        field: :status,
        message: "can't be canceled: only an in-app backup can"
      )
    else
      by = actor_label(context.actor)

      entry = %{
        at: DateTime.utc_now(),
        level: :warn,
        step: "cancel",
        message: "Canceled by #{by}"
      }

      changeset
      |> Ash.Changeset.force_change_attribute(:log, (run.log || []) ++ [entry])
      |> Ash.Changeset.force_change_attribute(:error, "Canceled by a platform admin")
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
      not holds?(row, run) ->
        Ash.Changeset.set_context(changeset, %{backup_step: nil, backup_chain: nil})

      row.phase == :finishing ->
        Ash.Changeset.add_error(changeset,
          field: :status,
          message: "too late to cancel: the backup is finishing"
        )

      true ->
        cancel_jobs(row.chain_id)

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

  # The lock works on this run: its chain, or (a resume or retry whose Run
  # write lagged) its stamp.
  defp holds?(%{chain_id: nil}, _run), do: false

  defp holds?(row, run),
    do: (run.chain_id != nil and row.chain_id == run.chain_id) or row.stamp == run.stamp

  defp cancel_jobs(chain) do
    query =
      from(j in Oban.Job,
        where: j.queue == "backup_steps" and fragment("?->>'chain' = ?", j.args, ^chain)
      )

    {:ok, _canceled} = Oban.cancel_all_jobs(query)
    :ok
  end

  defp step_label(%{step: nil}), do: nil
  defp step_label(%{step: :archive, part: part}) when is_integer(part), do: "archive part #{part}"
  defp step_label(%{step: step}), do: to_string(step)

  defp announce(changeset, {:ok, run} = result) do
    step = changeset.context[:backup_step]

    Logger.warning(
      "Backup #{run.stamp} canceled by #{actor_label(changeset.context[:private][:actor])}" <>
        if(step, do: " during #{step}", else: "")
    )

    case changeset.context[:backup_chain] do
      nil -> :ok
      chain -> Steps.settled(%{chain: chain, stamp: run.stamp}, {:error, :canceled})
    end

    result
  end

  defp announce(_changeset, result), do: result

  defp actor_label(%{email: email}) when not is_nil(email), do: to_string(email)
  defp actor_label(_actor), do: "a platform admin"
end
