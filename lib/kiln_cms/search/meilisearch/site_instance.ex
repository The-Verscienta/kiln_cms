defmodule KilnCMS.Search.Meilisearch.SiteInstance do
  @moduledoc """
  Which Meilisearch instance a site uses (#1558): the site's own
  (`KilnCMS.CMS.SiteMeilisearch`, set at `/editor/site-search`) or the
  operator's (`MEILI_URL` / `MEILI_MASTER_KEY` / `MEILI_INDEX`, the
  `config :kiln_cms, KilnCMS.Search.Meilisearch` layer).

  **The one resolver both directions ask.** `KilnCMS.Search.MeilisearchWorker`
  (indexing), `KilnCMS.Search.Meilisearch.search/2` (querying) and the enqueue
  gate on the publish path all go through `resolve/1` or `active?/1`, so the
  instance a site's documents are written to and the instance its queries read
  from can never disagree.

  ## Precedence

    * The site has a row and it is switched on — **the site's instance**, with
      the site's key and index, and nothing from the operator's config: not its
      URL, not its master key, not its index name.
    * No row, or the row is switched off — **the operator's instance** when
      `MEILI_URL` is set, and no Meilisearch at all when it is not. That is the
      site's own choice.

  ## Fail direction

  The third case is a row that exists but cannot be used: the read failed (the
  pool timed out, or the table does not exist yet mid-deploy), or the API key
  cannot be decrypted (`SECRET_KEY_BASE` was rotated, see
  `docs/secrets-rotation.md`). `resolve/1` answers `{:error, reason}`, and
  **never** the operator's instance. Each caller then fails in its own
  direction:

    * **Indexing holds.** The worker returns the error and Oban retries the job
      on a backoff that reaches ~16 hours, like mail. Falling back would write
      the site's content into the operator's index — an instance the site chose
      not to use, which may be one a front end queries with a search-only key.
    * **Searching degrades.** `Meilisearch.search/2` returns the error without
      making a request, and a caller falls back to the built-in Postgres search
      (`KilnCMS.Search`). Querying the operator's index instead would answer from
      an index that holds other sites' content, filtered only by an `org_id`
      facet — the disclosure direction.

  `active?/1` — the cheap gate the publish path asks before enqueueing a job —
  answers `true` for an unreadable row, so a job exists to hold.

  ## SSRF

  A site's URL is checked when it is saved (`Validations.SearchUrl`) and again
  on every request: a site target carries `safe: true`, which makes
  `KilnCMS.Search.Meilisearch.ReqClient` send it through `KilnCMS.SafeFetch`
  (resolved once, connected to by address, no redirects). The operator's
  instance is trusted and dialled directly — an internal `10.x` Meilisearch
  belongs in `MEILI_URL`.

  `allow_private_hosts: true` (`config :kiln_cms, #{inspect(__MODULE__)}`)
  lifts the address check for development, where the instance is on localhost.
  Don't set it on a deployment whose site admins you don't trust with your
  network.
  """

  require Logger

  alias KilnCMS.CMS
  alias KilnCMS.Keys.Vault
  alias KilnCMS.Search.Meilisearch

  @typedoc """
  A resolved instance. `source` says whose it is; `safe` is whether requests to
  it must go through `KilnCMS.SafeFetch` (every site target, unless
  `allow_private_hosts` is set).
  """
  @type target :: %{
          source: :site | :operator,
          url: String.t(),
          master_key: String.t() | nil,
          index: String.t(),
          safe: boolean()
        }

  @type error :: :unavailable | :credentials_unreadable

  @doc """
  The instance `org_id` uses: `{:ok, target}`, `:disabled` when it uses none,
  or `{:error, reason}` when the site set its own and it cannot be used — see
  the moduledoc for why that never becomes the operator's.

  `nil` is a job enqueued before sites could have their own instance (a delete
  with no `"org_id"`), which can only have been the operator's.
  """
  @spec resolve(Ash.UUID.t() | nil) :: {:ok, target()} | :disabled | {:error, error()}
  def resolve(nil), do: operator()

  def resolve(org_id) when is_binary(org_id) do
    case read(org_id) do
      {:ok, nil} -> operator()
      {:ok, %{enabled: false}} -> operator()
      {:ok, row} -> build(row)
      :error -> {:error, :unavailable}
    end
  end

  @doc """
  Whether indexing is on for `org_id` — the gate the publish, unpublish and
  delete paths ask before enqueueing a `MeilisearchWorker` job.

  Cheaper than `resolve/1` (no decryption), and `true` when the row cannot be
  read: an enqueued job holds and retries, and a skipped one is a document the
  site's index silently never gets.
  """
  @spec active?(Ash.UUID.t() | nil) :: boolean()
  def active?(nil), do: Meilisearch.enabled?()

  def active?(org_id) when is_binary(org_id) do
    case read(org_id) do
      {:ok, %{enabled: true}} -> true
      {:ok, _none_or_off} -> Meilisearch.enabled?()
      :error -> true
    end
  end

  @doc """
  Whether the stored key decrypts — for the settings page, which has to say
  when it needs re-entering (the row itself still looks fine).
  """
  @spec api_key_readable?(CMS.SiteMeilisearch.t()) :: boolean()
  def api_key_readable?(%{api_key_encrypted: nil}), do: true

  def api_key_readable?(%{api_key_encrypted: encrypted}),
    do: match?({:ok, _}, Vault.decrypt(encrypted))

  @doc "A sentence fragment for an `error()`, for logs and the settings page."
  @spec describe_error(error()) :: String.t()
  def describe_error(:unavailable), do: "its settings could not be read"

  def describe_error(:credentials_unreadable),
    do: "its API key could not be decrypted (was SECRET_KEY_BASE rotated?) and must be re-entered"

  @doc false
  # See the moduledoc's SSRF section.
  @spec allow_private_hosts?() :: boolean()
  def allow_private_hosts?, do: config()[:allow_private_hosts] == true

  defp operator do
    if Meilisearch.enabled?() do
      {:ok,
       %{
         source: :operator,
         url: Meilisearch.url(),
         master_key: Meilisearch.master_key(),
         index: Meilisearch.index_name(),
         safe: false
       }}
    else
      :disabled
    end
  end

  defp build(row) do
    with encrypted when is_binary(encrypted) <- row.api_key_encrypted,
         {:ok, key} <- Vault.decrypt(encrypted) do
      {:ok,
       %{
         source: :site,
         url: row.url,
         master_key: key,
         index: row.index,
         safe: not allow_private_hosts?()
       }}
    else
      _unreadable -> {:error, :credentials_unreadable}
    end
  end

  # The row, `nil` when the site has none, or `:error` when it could not be read.
  #
  # `authorize?: false` — a system read, and the bypass is safe here for the
  # reasons `KilnCMS.Mail.SiteRelay` gives: the jobs asking have no actor (the
  # read policy is org-admin, and an indexing job is nobody), the read is
  # tenant-scoped to the one site being indexed or searched, and the row never
  # leaves this module except as that site's own connection.
  defp read(org_id) do
    case CMS.list_site_meilisearch(tenant: org_id, authorize?: false) do
      {:ok, [row | _rest]} -> {:ok, row}
      {:ok, []} -> {:ok, nil}
      {:error, error} when is_exception(error) -> unreadable(org_id, Exception.message(error))
      {:error, error} -> unreadable(org_id, inspect(error))
    end
  rescue
    error -> unreadable(org_id, Exception.message(error))
  end

  defp unreadable(org_id, detail) do
    Logger.error("Meilisearch settings for site #{org_id} could not be read: #{detail}")
    :error
  end

  defp config, do: Application.get_env(:kiln_cms, __MODULE__, [])
end
