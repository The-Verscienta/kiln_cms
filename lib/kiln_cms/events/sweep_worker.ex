defmodule KilnCMS.Events.SweepWorker do
  @moduledoc """
  Runs the occurrence sweep on a schedule (#766).

  Scheduled from `KilnCMS.Application` (`KILN_OCCURRENCE_SWEEP_CRON`), hourly by
  default. `KilnCMS.Events.Sweep` has the argument for what it visits; this is
  only the schedule around it.

  **Hourly, and the period is the feature's staleness window.** An event that
  finished is listed as still upcoming until the next run, so a daily schedule
  would leave last night's gig at the top of "what's on" all morning. It is also
  cheap enough to run hourly precisely because the working set is "rows that
  went by since the last run" rather than the archive.

  Safe to leave enabled everywhere: a site with no event-shaped content does one
  indexed probe per content type, matches nothing, and stops.

  Queued on `:default` and `max_attempts: 1`, for the reasons
  `KilnCMS.Links.SweepWorker` gives: it is pure database work that must not hold
  a slot in a queue it feeds, and a failed run is better replaced by the next
  one against fresher data than replayed against stale input. The sweep is
  idempotent, so nothing is lost by waiting an hour.

  Takes an optional `"org_id"` so one site can be swept on demand — the shape a
  backfill (`mix kiln.sweep_occurrences`) and a test both want.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  alias KilnCMS.Events.Sweep

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"org_id" => org_id}}) when is_binary(org_id) do
    Sweep.run_org(org_id)
    :ok
  end

  def perform(%Oban.Job{}) do
    Sweep.run()
    :ok
  end
end
