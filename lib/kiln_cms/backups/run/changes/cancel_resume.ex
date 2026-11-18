defmodule KilnCMS.Backups.Run.Changes.CancelResume do
  @moduledoc """
  The guard and side effects of `KilnCMS.Backups.Run`'s `:cancel_resume`
  action (#2816): a platform admin cancels a resume of this run that holds the
  backup lock but has not re-opened the run yet. Its start step may wait up to
  about an hour for the server with the run's files (`StepWorker`'s pinned
  affinity) or a few minutes after a Cancel (`Steps`' settle wait), and all
  that time new and scheduled backups queue behind it.

  Inside the action's transaction (a `before_action` hook), after taking the
  backup lock's advisory lock (`KilnCMS.Backups.Chain.locked_row/0`), the lock
  must hold a resume of this run's stamp at its `start` step under a chain
  that is not the run's own (the start has not re-opened it). Anything else is
  refused with an error on `status`. Then the chain's step jobs are canceled
  and the lock released, which starts the queued request if there is one, as
  `Run.Changes.Cancel` does.

  The run keeps its status (a failed or canceled run stays resumable, and a
  canceled one keeps its `finished_at`, so the Cancel's settle window still
  counts from it). The one exception is a stale `running` run, which the
  resume was about to re-open: it is failed, as `Run.Changes.ResumeRefused`
  fails one. Either way the run says so (`Run.Changes.ResumeNote`), without
  naming who: the instance security log (`backup_canceled`, `"resume" =>
  true`) does.

  The UPDATE's WHERE pins the run as it was loaded: an in-app run, its
  status, its `chain_id`, and for a `running` one still stale. A start that
  re-opened the run first (the race the action can lose) makes it match
  nothing: the `StaleRecord` error rolls the whole action back, job cancel and
  release included, and the resume carries on. A start that comes second
  finds its lease gone, or its own pinned re-open refused
  (`Run.Changes.Resume`), and stops quietly.
  """
  use Ash.Resource.Change

  require Ash.Expr

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Chain, Steps}
  alias KilnCMS.Backups.Run.Changes.ResumeNote

  require Logger

  @note "Resume canceled by a platform admin before it started"

  @doc "What the run's error and log say about a resume canceled before it started."
  @spec note() :: String.t()
  def note, do: @note

  @impl true
  def change(changeset, _opts, _context) do
    run = changeset.data
    now = DateTime.utc_now()

    cond do
      run.origin != :app ->
        refuse(changeset, "can't be canceled: only an in-app backup's resume can")

      run.status in [:failed, :canceled] ->
        changeset
        |> Ash.Changeset.filter(Ash.Expr.expr(origin == :app and status == ^run.status))
        |> own_chain(run)
        |> ResumeNote.put(@note, :warn, run.error, now)
        |> hooks()

      run.status == :running ->
        fail_stale(changeset, run, now)

      true ->
        refuse(changeset, not_waiting())
    end
  end

  # A stale `running` run, as `ResumeRefused` fails one: still stale in the
  # WHERE, so a run that came back to life is never touched.
  defp fail_stale(changeset, run, now) do
    %{stale: stale} = Backups.resume_cutoffs(now)

    changeset
    |> Ash.Changeset.filter(
      Ash.Expr.expr(
        origin == :app and status == :running and started_at < ^stale and
          updated_at < ^stale
      )
    )
    |> own_chain(run)
    |> Ash.Changeset.force_change_attribute(:status, :failed)
    |> Ash.Changeset.force_change_attribute(:finished_at, now)
    |> ResumeNote.put(@note, :warn, run.error || ResumeNote.interrupted(), now)
    |> hooks()
  end

  defp not_waiting, do: "has no resume waiting to start"

  defp refuse(changeset, message),
    do: Ash.Changeset.add_error(changeset, field: :status, message: message)

  # The run's `chain_id` as loaded: a resume that re-opened the run moved it to
  # its own chain. A nil one requires a nil `chain_id`, as `OwnChain`.
  defp own_chain(changeset, %{chain_id: nil}),
    do: Ash.Changeset.filter(changeset, Ash.Expr.expr(is_nil(chain_id)))

  defp own_chain(changeset, %{chain_id: id}),
    do: Ash.Changeset.filter(changeset, Ash.Expr.expr(chain_id == ^id))

  defp hooks(changeset) do
    changeset
    |> Ash.Changeset.before_action(&stop_resume/1)
    |> Ash.Changeset.after_transaction(&announce/2)
  end

  # In the action's transaction: the advisory lock first, so the start can't
  # check its lease, and no request or step can move the lock, between the
  # decision and the commit.
  defp stop_resume(changeset) do
    run = changeset.data
    row = Chain.locked_row()

    cond do
      waiting?(row, run) ->
        :ok = Chain.cancel_chain_jobs(row.chain_id)

        case Chain.release_in_txn(row) do
          {:ok, promoted} ->
            Ash.Changeset.set_context(changeset, %{
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

      started?(row, run) ->
        refuse(changeset, started())

      true ->
        refuse(changeset, not_waiting())
    end
  end

  @doc """
  The refusal when the resume re-opened the run before this read it: it is a
  running backup now, which `:cancel` stops.
  """
  @spec started() :: String.t()
  def started, do: "has no resume waiting to start: the resume has started"

  @doc """
  Whether the backup lock `row` (`Chain.locked_row/0`) holds a resume of
  `run` that has not re-opened it: a resume of its stamp at the `start` step,
  under a chain that is not the run's. `Run.Changes.Cancel` refuses on it too
  (#3028), so a plain Cancel never leaves such a resume to re-open the run.
  """
  @spec waiting?(map(), map()) :: boolean()
  def waiting?(%{chain_id: chain, step: :start, resume_stamp: stamp}, %{stamp: stamp} = run)
      when is_binary(chain) and is_binary(stamp),
      do: run.chain_id != chain

  def waiting?(_row, _run), do: false

  # The lock holds the chain the run was re-opened under: a resume of it (or
  # a retry) that has started.
  defp started?(%{chain_id: chain, resume_stamp: stamp}, %{stamp: stamp, chain_id: chain})
       when is_binary(chain) and is_binary(stamp),
       do: true

  defp started?(_row, _run), do: false

  defp announce(changeset, {:ok, run} = result) do
    Logger.warning("Backup resume of #{run.stamp} canceled before it started")

    case changeset.context[:backup_chain] do
      nil -> :ok
      chain -> Steps.settled(%{chain: chain, stamp: run.stamp}, {:error, :canceled})
    end

    result
  end

  defp announce(_changeset, result), do: result
end
