defmodule KilnCMS.Governance.CheckpointWorker do
  @moduledoc """
  Mints one governance checkpoint per org on a schedule, and retries any earlier
  one the witness sink refused (#666).

  Scheduled from `config :kiln_cms, Oban` — nightly by default
  (`KILN_GOVERNANCE_CHECKPOINT_CRON`). Cadence is the security parameter worth
  understanding before changing it: the checkpoint is what bounds how far a
  chain can be truncated undetected, so the exposure window is exactly one
  interval. Anchors minted since the last checkpoint are not yet witnessed, and
  deleting *those* is still invisible. Hourly costs one signature and a handful
  of rows per org; a regulated deployment should want it.

  `max_attempts: 1`. A failed mint is retried by the next scheduled run against
  fresher data, which is strictly better than replaying a stale one — and a
  retry that succeeded after the schedule already ran would mint a second
  checkpoint covering the same state, spending a sequence number for nothing.
  Publication failures are not job failures: they are recorded on the row and
  retried by the next run's sweep, so a briefly unreachable sink does not cost
  the commitment.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger

  alias KilnCMS.Governance.Checkpoint
  alias KilnCMS.Governance.Witness

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    if Checkpoint.enabled?() do
      Enum.each(org_ids(args), &run_for_org/1)
    end

    :ok
  end

  # A permanently-broken sink must not make every run more expensive than the
  # last. Oldest first, so the backlog drains in order across runs and what is
  # left is always the tail.
  @retry_batch 50

  @doc """
  Run one org's checkpoint now.

  Returns the mint's own outcome rather than a bare `:ok` — `mix
  kiln.audit.checkpoint` prints what this run produced, and swallowing the
  result meant a failed mint printed *yesterday's* checkpoint as though it had
  just been made, and exited 0.
  """
  @spec run_for_org(Ash.UUID.t()) :: {:ok, struct()} | {:error, term()}
  def run_for_org(org_id) do
    republish_pending(org_id)

    case Checkpoint.mint(org_id) do
      {:ok, checkpoint} ->
        {:ok, checkpoint}

      {:error, reason} ->
        Logger.error(
          "Governance checkpoint for org #{org_id} could not be minted: #{inspect(reason)}"
        )

        {:error, reason}
    end
  rescue
    error ->
      Logger.error("Governance checkpoint for org #{org_id} failed: #{inspect(error)}")
      {:error, error}
  end

  # Earlier checkpoints the sink never accepted, published before this run's new
  # one so the sequence reaches the witness in order — an auditor reading the
  # bucket sees a contiguous run rather than a hole that fills in later.
  #
  # Gated on a sink actually existing. With the default `None` adapter nothing
  # is ever published, so `witnessed_at` stays nil on every row forever and this
  # queue is "every checkpoint the org has ever minted" — one more wasted entries
  # read and canonical encode per day, without limit, on the configuration every
  # unconfigured deployment runs.
  defp republish_pending(org_id) do
    if Witness.enabled?() do
      pending = Checkpoint.unwitnessed(org_id)
      {batch, deferred} = Enum.split(pending, @retry_batch)

      Enum.each(batch, &Checkpoint.publish(&1, org_id))

      if deferred != [] do
        Logger.warning(
          "#{length(deferred)} further unwitnessed governance checkpoint(s) for org " <>
            "#{org_id} were not retried this run; the next run continues the backlog."
        )
      end
    end
  rescue
    error ->
      Logger.warning("Republishing pending checkpoints failed: #{inspect(error)}")
      :ok
  end

  defp org_ids(%{"org_id" => org_id}) when is_binary(org_id), do: [org_id]
  defp org_ids(_args), do: KilnCMS.Accounts.list_org_ids()
end
