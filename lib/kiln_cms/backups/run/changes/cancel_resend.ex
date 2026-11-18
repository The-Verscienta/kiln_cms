defmodule KilnCMS.Backups.Run.Changes.CancelResend do
  @moduledoc """
  The guard and side effects of `KilnCMS.Backups.Run`'s `:cancel_resend`
  action (#2949): a platform admin stops a running re-send of this run to the
  destinations it missed.

  Inside the action's transaction (a `before_action` hook), after taking the
  backup lock's advisory lock (`KilnCMS.Backups.Chain.locked_row/0`), the lock
  must hold a re-send (step `:resend`) of this run's stamp that is not past
  the point of no return: a re-send marks itself `phase: :finishing` before
  its last Run write, and from there a Cancel is refused, as a backup's is.
  Anything else is refused with an error on `status`. Then the re-send's step
  jobs are canceled (an executing one is killed once the transaction
  commits) and the lock released, which starts the queued backup if there is
  one, as `Run.Changes.Cancel` does.

  The run keeps its status: a re-send never changes it. It gains a log line
  that says a platform admin canceled the re-send, **without naming who**
  (#3029); the instance security log (`backup_canceled`, `"resend" => true`)
  does. Its `chain_id` is cleared, so a step that outlives the Cancel on a
  node that missed it has its Run writes refused (`Run.Changes.OwnChain`).
  What the re-send already sent stays recorded: it records each destination
  as it settles. The line's time is the settle window a new re-send of the
  run waits out (`KilnCMS.Backups.Resend.eligible/2`).

  The UPDATE's WHERE pins the run's `chain_id` as loaded, and its status to
  `succeeded`: a re-send that began after the page read the run (it moved
  the run to its chain) makes it match nothing, and the whole action rolls
  back, job cancel and release included.
  """
  use Ash.Resource.Change

  require Ash.Expr

  alias KilnCMS.Backups.{Chain, Resend, Steps}

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    run = changeset.data

    if run.origin == :app do
      entry = %{
        at: DateTime.utc_now(),
        level: :warn,
        step: "resend",
        message: Resend.canceled_note()
      }

      changeset
      |> own_chain(run)
      |> Ash.Changeset.filter(Ash.Expr.expr(status == :succeeded))
      |> Ash.Changeset.force_change_attribute(:log, (run.log || []) ++ [entry])
      |> Ash.Changeset.force_change_attribute(:chain_id, nil)
      |> Ash.Changeset.before_action(&stop_resend/1)
      |> Ash.Changeset.after_transaction(&announce/2)
    else
      refuse(changeset, "can't be canceled: only an in-app backup's re-send can")
    end
  end

  @doc "The refusal when no re-send of the run holds the lock."
  @spec not_resending() :: String.t()
  def not_resending, do: "has no re-send running"

  @doc "The refusal once the re-send is past the point of no return."
  @spec finishing() :: String.t()
  def finishing, do: "too late to cancel: the re-send is finishing"

  defp own_chain(changeset, %{chain_id: nil}),
    do: Ash.Changeset.filter(changeset, Ash.Expr.expr(is_nil(chain_id)))

  defp own_chain(changeset, %{chain_id: id}),
    do: Ash.Changeset.filter(changeset, Ash.Expr.expr(chain_id == ^id))

  defp refuse(changeset, message),
    do: Ash.Changeset.add_error(changeset, field: :status, message: message)

  # In the action's transaction: the advisory lock first, so no step can
  # begin, advance, mark itself finishing or release between the decision
  # and the commit.
  defp stop_resend(changeset) do
    run = changeset.data
    row = Chain.locked_row()

    cond do
      not resending?(row, run) ->
        refuse(changeset, not_resending())

      row.phase == :finishing ->
        refuse(changeset, finishing())

      true ->
        :ok = Chain.cancel_chain_jobs(row.chain_id)

        case Chain.release_in_txn(row) do
          {:ok, promoted} ->
            Ash.Changeset.set_context(changeset, %{
              backup_step: "resend part #{row.part}",
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

  defp resending?(%{chain_id: chain, step: :resend, stamp: stamp}, %{stamp: stamp})
       when is_binary(chain) and is_binary(stamp),
       do: true

  defp resending?(_row, _run), do: false

  # The server log doesn't name who either (#3029): the security event does.
  defp announce(changeset, {:ok, run} = result) do
    Logger.warning(
      "Backup re-send of #{run.stamp} canceled by a platform admin" <>
        case changeset.context[:backup_step] do
          nil -> ""
          step -> " during #{step}"
        end
    )

    case changeset.context[:backup_chain] do
      nil ->
        :ok

      chain ->
        Steps.resend_stopped_event(%{chain: chain, stamp: run.stamp}, :canceled, run)
        Steps.settled(%{chain: chain, stamp: run.stamp}, {:error, :canceled})
    end

    result
  end

  defp announce(_changeset, result), do: result
end
