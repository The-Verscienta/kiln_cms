defmodule KilnCMS.Security.PruneWorker do
  @moduledoc """
  Deletes security events past each org's retention window (#2241).

  Scheduled from `KilnCMS.Application` (`KILN_SECURITY_LOG_PRUNE_CRON`), daily
  by default. For every org it resolves `KilnCMS.Security.retention_days/1`
  (the org's `KilnCMS.CMS.SiteSecurityLog` row, else 365; `0` keeps forever)
  and calls `KilnCMS.Security.prune/1`. An org whose window is `0`, or whose
  setting could not be read, is skipped: nothing is deleted on a window nobody
  could confirm.

  Queued on `:default` with `max_attempts: 1`: the prune is idempotent, and
  tomorrow's run replaces a failed one. A failure raises (it is not swallowed
  into `:ok`), so it shows up in the job's error and telemetry.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger

  alias KilnCMS.Security

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    deleted =
      Enum.reduce(KilnCMS.Accounts.list_org_ids(), 0, fn org_id, total ->
        case Security.retention_days(org_id) do
          0 ->
            total

          days ->
            {:ok, count} = Security.prune(org_id: org_id, retention_days: days)
            total + count
        end
      end)

    if deleted > 0, do: Logger.info("security log: pruned #{deleted} events past retention")
    :ok
  end
end
