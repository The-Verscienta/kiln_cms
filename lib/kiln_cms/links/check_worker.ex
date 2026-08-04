defmodule KilnCMS.Links.CheckWorker do
  @moduledoc """
  Checks one outbound URL and writes the verdict to every document that cites it
  (#474).

  Queued by `KilnCMS.Links.Sweep`, one job per distinct URL per site.

  ## Retry before flagging

  A single failure is never reported. `:transient` outcomes — a 5xx, a timeout,
  a name that did not resolve — increment a consecutive-failure counter, and
  only the third in a row becomes `:broken`. The web has bad minutes; an author
  should not hear about them, and a checker that reports a five-minute outage at
  a popular host as "forty pages contain a broken link" is one they turn off.

  A `:broken` verdict from the checker itself (404, 410) is not delayed — the
  server answered clearly, and there is nothing to wait for.

  Any `:ok` resets the counter to zero. The counter measures the *current* run of
  failures, not lifetime unreliability.

  ## Snoozing, not sleeping

  `KilnCMS.Links.Throttle` paces requests per remote host. When a host's bucket
  is empty the job **snoozes** for the remaining window rather than sleeping:
  sleeping holds a `:link_check` slot open doing nothing, so one busy domain
  would stall every other domain's checks behind it. Oban raises `max_attempts`
  on a snooze, so pacing never consumes the job's retries.

  ## The opt-in is re-read here, on purpose

  Jobs enqueued while checking was on are still in the queue after someone turns
  it off. The switch means "this deployment does not make these requests", so the
  place it has to be honoured is immediately before the request — not only in the
  sweep that queued the job an hour ago.
  """
  use Oban.Worker,
    queue: :link_check,
    max_attempts: 3,
    # One in-flight job per URL per site. A sweep that overlaps the previous
    # night's leftovers would otherwise ask the same host the same question
    # twice, which is precisely the behaviour the throttle exists to avoid.
    unique: [period: 3600, fields: [:args, :worker]]

  require Ash.Query
  require Logger

  alias KilnCMS.CMS.Changes.DigestUrl
  alias KilnCMS.CMS.ExternalLink
  alias KilnCMS.Links.External
  alias KilnCMS.Links.Settings

  # Consecutive failing checks before a `:transient` outcome is called broken.
  @failures_before_broken 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"org_id" => org_id, "url" => url}}) do
    if Settings.enabled?(org_id) do
      check(org_id, url)
    else
      {:cancel, "outbound link checking is off for this site"}
    end
  end

  def perform(%Oban.Job{args: args}), do: {:cancel, "unusable args: #{inspect(args)}"}

  defp check(org_id, url) do
    case External.throttle(External.host(url)) do
      :ok -> record(org_id, url, External.check(url))
      {:error, {:rate_limited, retry_after_ms}} -> {:snooze, snooze_seconds(retry_after_ms)}
    end
  end

  # Oban snoozes in whole seconds and treats 0 as "immediately", which against a
  # still-empty bucket is a spin. Floor at one second.
  defp snooze_seconds(retry_after_ms), do: max(1, ceil(retry_after_ms / 1_000))

  defp record(org_id, url, result) do
    query = Ash.Query.filter(ExternalLink, url_digest == ^DigestUrl.digest(url))

    case previous_failures(query, org_id) do
      nil ->
        # Every occurrence was pruned between the sweep and this job — the link
        # is no longer published anywhere, so there is nothing to record.
        :ok

      previous ->
        query
        |> Ash.bulk_update(:record_check, verdict(result, previous),
          authorize?: false,
          tenant: org_id,
          strategy: [:stream],
          allow_stream_with: :full_read,
          return_errors?: true
        )
        |> report(org_id, url)
    end
  end

  # The highest count across this URL's occurrences. Rows added by a later sweep
  # start at zero, and taking the maximum keeps a URL that has been failing for a
  # week from restarting its count because one new page linked it yesterday.
  defp previous_failures(query, org_id) do
    query
    |> Ash.Query.sort(failure_count: :desc)
    |> Ash.Query.limit(1)
    |> Ash.Query.select([:failure_count])
    |> Ash.read_one(authorize?: false, tenant: org_id)
    |> case do
      {:ok, %{failure_count: count}} -> count
      {:ok, nil} -> nil
      {:error, _reason} -> nil
    end
  end

  defp verdict(%{outcome: :ok, status: status}, _previous),
    do: %{outcome: :ok, status_code: status, reason: nil, failure_count: 0}

  # A check that declined to judge changes nothing, including the counter: it is
  # neither evidence the link works nor evidence it does not.
  defp verdict(%{outcome: :undetermined} = result, previous),
    do: %{
      outcome: :undetermined,
      status_code: result.status,
      reason: result.reason,
      failure_count: previous
    }

  defp verdict(%{outcome: :broken} = result, previous),
    do: %{
      outcome: :broken,
      status_code: result.status,
      reason: result.reason,
      failure_count: previous + 1
    }

  defp verdict(%{outcome: :transient} = result, previous) do
    count = previous + 1

    if count >= @failures_before_broken do
      %{
        outcome: :broken,
        status_code: result.status,
        reason: "#{result.reason} (#{count} consecutive failed checks)",
        failure_count: count
      }
    else
      %{
        outcome: :transient,
        status_code: result.status,
        reason: result.reason,
        failure_count: count
      }
    end
  end

  defp report(%Ash.BulkResult{status: :success}, _org_id, _url), do: :ok

  # A write that failed leaves the row on its previous verdict, which the next
  # sweep re-queues. Returning an error retries the *check* too, and the whole
  # point of pacing is not to ask twice for a database problem.
  defp report(%Ash.BulkResult{errors: errors}, org_id, url) do
    Logger.warning("link check: could not record #{url} for #{org_id}: #{inspect(errors)}")
    :ok
  end

  @doc "Consecutive failing checks before a transient outcome is called broken."
  @spec failures_before_broken() :: pos_integer()
  def failures_before_broken, do: @failures_before_broken
end
