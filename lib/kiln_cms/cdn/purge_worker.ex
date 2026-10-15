defmodule KilnCMS.CDN.PurgeWorker do
  @moduledoc """
  Sends one site's CDN purge (see `KilnCMS.CDN`). Retried with backoff on a
  non-2xx or a transport error; a purge that never lands leaves the cached
  responses to expire on their own `max-age`, which is the state the site was
  in before purging was configured.

  Through `KilnCMS.SafeFetch` although the operator chose the URL: it is the
  one outbound client in the app that pins the address it validated, and a
  purge endpoint is exactly the kind of URL that ends up pointing somewhere
  surprising after a DNS change.

  Its outcome is recorded on the propagation records it covers (#1927,
  `KilnCMS.Propagation.cdn_settled/3`): every record of the site still waiting
  on a purge that was enqueued before this attempt started, so a burst of
  publishes coalesced into one purge stamps each of them. `:acknowledged` on a
  2xx; `:failed` when the last attempt fails, or when the purge URL was unset
  before the job ran.
  """
  use Oban.Worker,
    queue: :webhooks,
    max_attempts: 5,
    # Scheduled-only, and per transaction: see `KilnCMS.CDN` for why neither a
    # running purge nor one committed before a release may absorb the next.
    unique: [keys: [:org_id, :txn], states: :scheduled]

  alias KilnCMS.CDN
  alias KilnCMS.SafeFetch

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"org_id" => org_id}} = job) do
    started_at = job.attempted_at || DateTime.utc_now()

    case CDN.purge_url() do
      # Unset between enqueue and run — nothing to purge against.
      nil ->
        KilnCMS.Propagation.cdn_settled(org_id, started_at, :failed)
        :ok

      url ->
        result = purge(url, org_id)
        record(result, job, org_id, started_at)
        result
    end
  end

  defp record(:ok, _job, org_id, started_at),
    do: KilnCMS.Propagation.cdn_settled(org_id, started_at, :acknowledged)

  defp record({:error, _reason}, job, org_id, started_at) do
    if job.attempt >= job.max_attempts,
      do: KilnCMS.Propagation.cdn_settled(org_id, started_at, :failed)
  end

  defp purge(url, org_id) do
    # The site's key only — never the global `kiln` key, which would purge
    # every other site on the deployment for one site's publish.
    keys = [CDN.site_key(org_id)]

    url
    |> SafeFetch.post(Jason.encode!(%{tags: keys}),
      headers: CDN.purge_headers(keys),
      receive_timeout: 15_000,
      truncate_body: true,
      req_options: CDN.req_options()
    )
    |> case do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, "purge endpoint returned HTTP #{status}"}
      {:error, reason} -> {:error, "purge failed: #{reason}"}
    end
  end
end
