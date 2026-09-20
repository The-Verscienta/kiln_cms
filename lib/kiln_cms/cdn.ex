defmodule KilnCMS.CDN do
  @moduledoc """
  Optional CDN purge on publish, for the anonymous API responses
  `KilnCMSWeb.Plugs.PublicCache` marks cacheable.

  Every such response — and every public fired-artifact response — carries the
  site's surrogate key (`surrogate_keys/1`) as both
  `Surrogate-Key` (Fastly) and `Cache-Tag` (Cloudflare). When
  `KILN_CDN_PURGE_URL` is set, an editorial event that changes what delivery
  serves enqueues one `KilnCMS.CDN.PurgeWorker` job, which `POST`s that site's
  key to the URL:

      POST <KILN_CDN_PURGE_URL>
      content-type: application/json
      surrogate-key: kiln-org-<org id>
      authorization: Bearer <KILN_CDN_PURGE_TOKEN>      # when a token is set

      {"tags": ["kiln-org-<org id>"]}

  The body is Cloudflare's purge-by-tag shape and the header is Fastly's
  purge-by-key shape, so either API can be the URL directly; anything else puts
  a small relay in between. `KILN_CDN_PURGE_TOKEN_HEADER` names the header the
  token goes in (`fastly-key` for Fastly); left at `authorization`, the token is
  sent as a `Bearer` credential.

  Unset, nothing is enqueued and the cached responses simply age out on their
  `max-age`.

  ## Why the whole site

  A JSON:API list or a GraphQL query can contain any number of documents, and
  nothing between the query and the response records which. Purging the site's
  key is the one invalidation that is right for every cached response: a
  publish can change any list it appears in, and one purge request per publish
  is cheap next to a precise-but-incomplete one.

  ## Where it hangs off

  `handle_event/3` is the fourth consumer of `KilnCMS.Webhooks.dispatch/3`, the
  funnel every `<type>.published`/`.unpublished`/`.updated` and
  `release.published` already flows through. Like the federation and automation
  consumers beside it, it is enqueue-only and never raises: a purge problem
  must not fail a publish.

  The job is scheduled a moment out and unique among *scheduled* jobs for its
  site, so a burst of publishes sends one purge. Only scheduled jobs dedupe: a
  purge that is already running may have sent its request before this publish
  committed, so the next publish must get a job of its own.

  The same reasoning covers a **transaction**. A release publishes every item
  and dispatches `release.published` inside one transaction that can run for
  minutes (`KilnCMS.CMS.Releases`); a purge scheduled by an ordinary publish
  just before it would absorb every one of those dispatches, run while the
  release is still uncommitted, and let the CDN refetch the old content with
  no second purge coming. So a dispatch inside a transaction keys its job on
  that transaction's id as well: the release's own dispatches still coalesce
  into one purge, which becomes visible — and runs — only once they commit.
  """

  require Logger

  alias KilnCMS.CDN.PurgeWorker

  # The events after which delivery can serve something different. `in_review`
  # and `returned_to_draft` from a draft change nothing anonymous callers see;
  # unpublishing a live document is `unpublished`.
  @purging_suffixes ~w(published unpublished updated)

  @doc """
  The surrogate keys a cached response for `org_id` carries: `kiln` on every
  Kiln API response (a whole-deployment purge, by hand) and the site's own key
  (`site_key/1`), which is what a publish purges.
  """
  @spec surrogate_keys(String.t()) :: [String.t()]
  def surrogate_keys(org_id), do: ["kiln", site_key(org_id)]

  @doc "The one surrogate key a publish in `org_id` purges."
  @spec site_key(String.t()) :: String.t()
  def site_key(org_id), do: "kiln-org-#{org_id}"

  @doc "Whether a purge URL is configured."
  @spec enabled?() :: boolean()
  def enabled?, do: is_binary(purge_url())

  @doc "The configured purge URL, or `nil`."
  @spec purge_url() :: String.t() | nil
  def purge_url do
    case Keyword.get(config(), :purge_url) do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  @doc """
  Called from `KilnCMS.Webhooks.dispatch/3`: enqueue a purge of `org`'s
  surrogate key when purging is configured and `event` changes delivery.
  Never raises.
  """
  @spec handle_event(String.t(), map(), Ash.ToTenant.t() | nil) :: :ok
  def handle_event(event, _payload, org) do
    with true <- enabled?(),
         true <- purges?(event),
         org_id when is_binary(org_id) <- org_id(org) do
      %{org_id: org_id, txn: transaction_id()}
      |> PurgeWorker.new(schedule_in: 2)
      |> Oban.insert!()
    end

    :ok
  rescue
    error ->
      Logger.warning("CDN.handle_event/3 failed for #{event}: #{Exception.message(error)}")
      :ok
  end

  @doc "Whether `event` changes what anonymous delivery serves."
  @spec purges?(String.t()) :: boolean()
  def purges?(event) when is_binary(event) do
    event |> String.split(".") |> List.last() |> then(&(&1 in @purging_suffixes))
  end

  @doc """
  The purge request's headers for `keys`: the Fastly-shaped `surrogate-key`,
  JSON, and the token when one is configured.
  """
  @spec purge_headers([String.t()]) :: [{String.t(), String.t()}]
  def purge_headers(keys) do
    [{"content-type", "application/json"}, {"surrogate-key", Enum.join(keys, " ")}] ++
      token_header()
  end

  @doc false
  # Extra Req options (a `Req.Test` plug in the test env).
  def req_options, do: Keyword.get(config(), :req_options, [])

  defp token_header do
    header = config() |> Keyword.get(:purge_token_header, "authorization") |> String.downcase()

    case {token(), header} do
      {:none, _header} -> []
      {{:ok, token}, "authorization"} -> [{"authorization", "Bearer " <> token}]
      {{:ok, token}, header} -> [{header, token}]
    end
  end

  # Through `KilnCMS.Keys`' provider tuples, like the governance witness token,
  # so it can come from a file or a secret manager; a plain string works too.
  defp token do
    case Keyword.get(config(), :purge_token) do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      {provider, config} when provider in [:env, :file, :database] ->
        case KilnCMS.Keys.provider!(provider).fetch(config) do
          {:ok, token} when is_binary(token) and token != "" -> {:ok, token}
          _error -> :none
        end

      _unset ->
        :none
    end
  end

  # `nil` outside a transaction, so every committed publish shares one key.
  defp transaction_id do
    if KilnCMS.Repo.in_transaction?() do
      %{rows: [[txid]]} = KilnCMS.Repo.query!("SELECT txid_current()")
      txid
    end
  end

  defp org_id(org) when is_binary(org), do: org
  defp org_id(%{id: id}) when is_binary(id), do: id
  defp org_id(_org), do: nil

  defp config, do: Application.get_env(:kiln_cms, __MODULE__, [])
end
