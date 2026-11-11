defmodule KilnCMS.Security.PruneWorker do
  @moduledoc """
  Deletes security events past each org's retention window (#2241).

  Scheduled from `KilnCMS.Application` (`KILN_SECURITY_LOG_PRUNE_CRON`), daily
  by default. For every org it resolves `KilnCMS.Security.retention_days/1`
  (the org's `KilnCMS.CMS.SiteSecurityLog` row, else 365; `0` keeps forever)
  and calls `KilnCMS.Security.prune/1`. An org whose window is `0`, or whose
  setting could not be read, is skipped: nothing is deleted on a window nobody
  could confirm. The instance log (#2541) is pruned too, on
  `KilnCMS.Security.instance_retention_days/0`. Every log is attempted even
  when one fails; the job then raises, naming the failed ones.

  Queued on `:default` with `max_attempts: 1`: the prune is idempotent, and
  tomorrow's run replaces a failed one. A failure raises (it is not swallowed
  into `:ok`), so it shows up in the job's error and telemetry.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger

  alias KilnCMS.Security

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    # Every log is pruned even when one fails (#2541): a failing site must not
    # keep the instance log's IPs past their window, nor the other way round.
    # A failure is logged and the job raises at the end, so it still shows.
    parts = [:instance | KilnCMS.Accounts.list_org_ids()]

    {deleted, failed} =
      Enum.reduce(parts, {0, []}, fn part, {total, failed} ->
        case prune_part(part) do
          {:ok, count} -> {total + count, failed}
          :error -> {total, [part | failed]}
        end
      end)

    if deleted > 0, do: Logger.info("security log: pruned #{deleted} events past retention")

    unless failed == [] do
      raise "security log prune failed for #{inspect(Enum.reverse(failed))}"
    end

    :ok
  end

  defp prune_part(part) do
    case window(part) do
      0 -> {:ok, 0}
      days when part == :instance -> Security.prune_instance(retention_days: days)
      days -> Security.prune(org_id: part, retention_days: days)
    end
  rescue
    error ->
      Logger.error("security log prune failed for #{inspect(part)}: #{inspect(error)}")
      :error
  end

  defp window(:instance), do: Security.instance_retention_days()
  defp window(org_id), do: Security.retention_days(org_id)
end
