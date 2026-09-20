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
  def perform(%Oban.Job{args: %{"org_id" => org_id}}) do
    case CDN.purge_url() do
      # Unset between enqueue and run — nothing to purge against.
      nil -> :ok
      url -> purge(url, org_id)
    end
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
