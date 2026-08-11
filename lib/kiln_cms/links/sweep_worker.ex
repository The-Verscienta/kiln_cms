defmodule KilnCMS.Links.SweepWorker do
  @moduledoc """
  Runs the external link sweep on a schedule, per site (#474).

  Scheduled from `KilnCMS.Application` (`KILN_LINK_CHECK_CRON`), nightly by
  default. Safe to leave enabled on every deployment: with no site opted in it
  reads one settings row per org and stops, so the schedule costs nothing until
  somebody asks for outbound checking.

  Queued on `:default` rather than `:link_check`. The sweep is pure database
  work, and putting it in the queue it fills would let a long scan hold a slot
  the checks it just queued are waiting for.

  `max_attempts: 1`. A failed sweep is retried by the next scheduled run against
  fresher data, which beats replaying a stale one — and the scan is idempotent,
  so nothing is lost by waiting a day.

  Takes an optional `"org_id"` so one site can be swept on demand (the report
  page's "Check now"). That form still honours the opt-in: the button is the
  request, not the authorization.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger

  alias KilnCMS.Links.Settings
  alias KilnCMS.Links.Sweep

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    args |> org_ids() |> Enum.each(&sweep/1)
    :ok
  end

  defp org_ids(%{"org_id" => org_id}) when is_binary(org_id), do: [org_id]
  defp org_ids(_args), do: Settings.enabled_org_ids()

  defp sweep(org_id) do
    if Settings.enabled?(org_id) do
      Sweep.run_org(org_id)
    else
      Logger.debug("link check: #{org_id} has outbound checking off, skipping")
    end
  end

  @doc """
  Queue a sweep for one site now.

  Deduplicated for an hour: the button is in a LiveView, and the second click
  should not double the site's outbound traffic.
  """
  @spec enqueue(Ash.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(org_id) do
    %{"org_id" => org_id}
    |> new(unique: [period: 3600, fields: [:args, :worker]])
    |> Oban.insert()
  end
end
