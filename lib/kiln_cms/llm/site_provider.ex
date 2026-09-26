defmodule KilnCMS.LLM.SiteProvider do
  @moduledoc """
  Which AI provider, model and key a site uses for a feature (#1557): the
  site's own (`KilnCMS.CMS.SiteAiProvider`, set at `/editor/site-ai`) or the
  operator's (`SEO_MODEL` / `ASSIST_MODEL` / `ASK_MODEL` and the provider key
  variables `req_llm` reads).

  `KilnCMS.Seo`, `KilnCMS.Assist` and `KilnCMS.Ask` ask `resolve/2` once per
  request, before spending any budget, and turn the answer into a
  `KilnCMS.LLM.Route`. No generator reads `Application` config for a site that
  has its own provider switched on.

  ## Precedence

    * The site has a row and it is switched on — **the site's provider, key and
      models, for all three features**, and nothing from the operator's AI
      config: not the key, not `base_url`, not the generator module. A feature
      whose model the site left blank is **off** for the site (`:off`), not
      handed back to the operator. A site that brought its own key has said
      where its content goes; quietly sending one feature's content through the
      operator's account instead would undo that for the feature it forgot.
    * No row, or the row is switched off — **the operator's configuration**,
      exactly as before this existed. That is the site's own choice.

  ## Fail direction

  The row exists but cannot be used: the read failed (the pool timed out, or
  the table does not exist yet mid-deploy), or the key cannot be decrypted
  (`SECRET_KEY_BASE` was rotated, see `docs/secrets-rotation.md`). Both return
  `{:error, reason}`, and the features **refuse the request** — SEO and Assist
  say so to the editor, `/api/ask` degrades to retrieval-only with
  `generation: "failed"`. They never fall back to the operator's provider.

  Falling back looks safe, and it isn't. It sends the site's drafts, or a
  stranger's question and the site's published passages, to a provider the
  site chose not to use, under an account and a data-processing agreement that
  are not the site's, and bills the operator for it. Refusing costs an editor
  one click they can retry, and the settings page says what to fix.

  ## Budgets

  The `KilnCMS.LLM.Budget` buckets apply to a site's own key exactly as to the
  operator's: the per-user and per-caller buckets are abuse limits (a stuck
  button, an anonymous flood on `/api/ask`) rather than billing, and the
  per-org bucket now caps what a runaway can spend on the *site's* account.
  Each call also holds a process on this server for up to the feature's
  timeout, whoever pays the provider. Per-site limits are not configurable
  here; the operator's limits apply to every site.

  ## What never rides along

  `req_llm` looks for a key in three places: the `:api_key` option, then
  `config :req_llm, :<provider>_api_key`, then the `<PROVIDER>_API_KEY`
  environment variable — the operator's. And it takes the endpoint from the
  model, then the `:base_url` option, then `config :req_llm, :<provider>` —
  again the operator's. So a site route always carries **both** options
  explicitly (`KilnCMS.LLM.Client`): the site's key, and the provider's
  published API root. A site with no key sends an empty one, which `req_llm`
  refuses rather than filling in.

  `KilnCMS.LLM.SiteProviderIsolationTest` plants the operator's key and
  endpoint in every place `req_llm` reads and asserts the request that leaves
  carries the site's.
  """

  require Logger

  alias KilnCMS.CMS
  alias KilnCMS.Keys.Vault
  alias KilnCMS.LLM.Route

  @type feature :: :seo | :assist | :ask
  @type error :: :unavailable | :credentials_unreadable

  @model_fields %{seo: :seo_model, assist: :assist_model, ask: :ask_model}

  @doc """
  The route for `feature` on the site `org_id`:

    * `:operator` — no row, or the row is off: the operator's config applies;
    * `:off` — the site's row is on and leaves this feature's model blank;
    * `{:site, route}` — the site's provider, model and key;
    * `{:error, reason}` — the site's row is set but cannot be used. Refuse the
      request; see the moduledoc.
  """
  #
  # The facades take whatever their callers pass as `:org_id` for the budget
  # buckets — an id, an organization struct, or `nil` from a mix task — so this
  # does too. Something that is not an organization id at all cannot have a row,
  # which makes `:operator` the truthful answer there, not a fallback.
  @spec resolve(term(), feature()) ::
          :operator | :off | {:site, Route.t()} | {:error, error()}
  def resolve(%{id: org_id}, feature), do: resolve(org_id, feature)

  def resolve(org_id, feature) when is_binary(org_id) and is_map_key(@model_fields, feature) do
    # The text form only: `Ecto.UUID.cast/1` also takes any 16-byte binary as a
    # raw UUID, and a 16-character label is not an organization id.
    with 36 <- byte_size(org_id),
         {:ok, uuid} <- Ecto.UUID.cast(org_id) do
      resolve_row(uuid, feature)
    else
      _not_an_org_id -> :operator
    end
  end

  def resolve(_no_org, feature) when is_map_key(@model_fields, feature), do: :operator

  defp resolve_row(org_id, feature) do
    case read(org_id) do
      {:ok, nil} -> :operator
      {:ok, %{enabled: false}} -> :operator
      {:ok, row} -> build(row, feature)
      :error -> {:error, :unavailable}
    end
  end

  @doc """
  Whether the stored key decrypts — for the settings page, which has to say
  when it needs re-entering (the row itself still looks fine).
  """
  @spec key_readable?(CMS.SiteAiProvider.t()) :: boolean()
  def key_readable?(%{api_key_encrypted: nil}), do: true

  def key_readable?(%{api_key_encrypted: encrypted}),
    do: match?({:ok, _}, Vault.decrypt(encrypted))

  @doc "A sentence fragment for an `error()`, for logs, the editor and the settings page."
  @spec describe_error(error() | term()) :: String.t()
  def describe_error(:unavailable), do: "its settings could not be read"

  def describe_error(:credentials_unreadable),
    do: "its API key could not be decrypted (was SECRET_KEY_BASE rotated?) and must be re-entered"

  def describe_error(_other), do: "it could not be used"

  @doc """
  The host a route sends to — the site's endpoint, or `nil` for an operator
  route (whose host `KilnCMS.LLM.endpoint_host/2` works out from the
  operator's config).
  """
  @spec endpoint_host(Route.t()) :: String.t() | nil
  def endpoint_host(%Route{source: :site, base_url: url}) when is_binary(url),
    do: URI.parse(url).host

  def endpoint_host(_route), do: nil

  # The row, `nil` when the site has none, or `:error` when it could not be read.
  #
  # `authorize?: false` — a system read, and the bypass is safe here for the
  # reason `KilnCMS.Mail.SiteRelay` gives: `/api/ask` has no actor at all and
  # the resource's read policy is org-admin, the read is tenant-scoped to the
  # one site the request is for, and the row never leaves this module except as
  # that site's own route.
  defp read(org_id) do
    case CMS.list_site_ai_provider(tenant: org_id, authorize?: false) do
      {:ok, [row | _rest]} -> {:ok, row}
      {:ok, []} -> {:ok, nil}
      {:error, error} when is_exception(error) -> unreadable(org_id, Exception.message(error))
      {:error, error} -> unreadable(org_id, inspect(error))
    end
  rescue
    error -> unreadable(org_id, Exception.message(error))
  end

  defp unreadable(org_id, detail) do
    Logger.error("AI provider settings for site #{org_id} could not be read: #{detail}")
    :error
  end

  defp build(row, feature) do
    case Map.fetch!(row, Map.fetch!(@model_fields, feature)) do
      model when is_binary(model) and model != "" ->
        with {:ok, api_key} <- api_key(row) do
          {:site, route(row, model, api_key)}
        end

      _blank ->
        :off
    end
  end

  defp api_key(%{api_key_encrypted: nil, provider: :openai_compatible}), do: {:ok, nil}

  defp api_key(%{api_key_encrypted: encrypted} = row) when is_binary(encrypted) do
    case Vault.decrypt(encrypted) do
      {:ok, key} ->
        {:ok, key}

      {:error, _reason} ->
        Logger.warning(
          "Refusing AI requests for site #{row.org_id}: its provider is set but " <>
            describe_error(:credentials_unreadable)
        )

        {:error, :credentials_unreadable}
    end
  end

  # A hosted provider with no key stored — `Changes.StoreAiApiKey` refuses to
  # save one, so this is an out-of-band write. Refused, not sent keyless:
  # a missing key is exactly the case `req_llm` would fill from the operator's.
  defp api_key(_row), do: {:error, :credentials_unreadable}

  defp route(%{provider: :openai_compatible} = row, model, api_key) do
    %Route{
      source: :site,
      provider: :openai_compatible,
      model: model,
      base_url: row.base_url,
      api_key: api_key
    }
  end

  defp route(%{provider: provider}, model, api_key) do
    %Route{
      source: :site,
      provider: provider,
      model: "#{provider}:#{model}",
      base_url: default_base_url(provider),
      api_key: api_key
    }
  end

  # The provider's own published API root, from `req_llm`'s provider module —
  # never the operator's `config :req_llm, :<provider>, base_url:` override,
  # which `req_llm` would otherwise apply (see the moduledoc).
  defp default_base_url(provider) do
    {:ok, module} = ReqLLM.provider(provider)
    module.default_base_url()
  end
end
