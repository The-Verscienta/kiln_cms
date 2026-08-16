defmodule KilnCMS.CMS.Workers.HealthSweepWorker do
  @moduledoc """
  Runs the content-freshness sweep on a schedule (`docs/content-lifecycles.md`).

  Scheduled from `KilnCMS.Application` (`KILN_HEALTH_SWEEP_CRON`), daily by
  default. `KilnCMS.CMS.HealthSweep` has the argument for what it visits and
  why; this is only the schedule around it.

  **Daily is the right period, unlike the every-minute expiry cron.** Expiry is
  a deadline someone set to the minute — content must come down when they said.
  Freshness is a cadence measured in months, and a reminder that arrived at
  09:00 instead of 09:01 is the same reminder. Running it more often would just
  multiply the events without moving any of them meaningfully earlier.

  Safe to leave enabled everywhere: a site with no review cadences matches
  nothing (one indexed probe per content type) and stops.

  Queued on `:default` with `max_attempts: 1`, for the reasons
  `KilnCMS.Events.SweepWorker` gives — it is database work that must not hold a
  slot in a queue it feeds, and a failed run is better replaced by tomorrow's
  against fresher data than replayed against stale input. Nothing is lost by
  waiting: the sweep is a reminder that repeats.

  Takes an optional `"org_id"` so one site can be swept on demand, which is the
  shape both a manual nudge and a test want.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  alias KilnCMS.CMS.HealthSweep

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"org_id" => org_id}}) when is_binary(org_id) do
    HealthSweep.run_org(org_id)
    :ok
  end

  def perform(%Oban.Job{}) do
    HealthSweep.run()
    :ok
  end
end
