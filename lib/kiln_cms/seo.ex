defmodule KilnCMS.Seo do
  @moduledoc """
  SEO assistance: deterministic analysis (always on) plus optional LLM drafting.

  Two halves, deliberately decoupled:

    * `KilnCMS.Seo.Analyzer` — pure checks over the authored fields and body.
      No configuration, no network, no model. Works on every install.
    * `KilnCMS.Seo.Generator` — proposes `seo_title` / `seo_description` /
      `seo_keywords`. **Off by default.** With `generator: nil` no module is
      called and nothing leaves the deployment.

  ## Enabling drafting

      config :kiln_cms, KilnCMS.Seo,
        generator: KilnCMS.Seo.Generator.ReqLLM,
        model: "ollama:llama3.1"

  The shipped adapter is provider-agnostic. `req_llm` carries `ollama` and
  `vllm` providers, and every provider's `base_url` is overridable, so an
  on-prem endpoint needs no Kiln code — which is why shipping the adapter is
  not the same as shipping egress. `egress?/0` reports which choice the
  operator actually made; `KilnCMS.Application` logs a warning at boot when a
  third-party provider is configured, and the editor shows a standing notice.

  The operator's API keys are never read or stored by Kiln: `req_llm`
  resolves them itself from its own config and environment
  (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, …).

  ## A site's own provider (#1557)

  A site can bring its own provider, key and model at `/editor/site-ai`. Every
  call resolves the site's route first (`route/1`, through
  `KilnCMS.LLM.SiteProvider`): a site with its own provider switched on uses it
  and nothing of the operator's, a site without one uses the configuration
  above, and a site whose provider is set but unusable is refused with
  `{:error, {:site_provider, reason}}` rather than sent to the operator's.
  The zero-arity `enabled?/0`, `egress?/0` and friends describe the operator's
  configuration only; per-site screens use `summary/1`.
  """

  require Logger

  alias KilnCMS.LLM
  alias KilnCMS.LLM.Budget
  alias KilnCMS.LLM.Route
  alias KilnCMS.LLM.SiteProvider
  alias KilnCMS.Seo.Document
  alias KilnCMS.Seo.Draft

  @doc "Whether LLM drafting is configured. False on a default install."
  @spec enabled?() :: boolean()
  def enabled?, do: not is_nil(generator()) and not is_nil(model())

  @spec generator() :: module() | nil
  def generator, do: cfg(:generator, nil)

  @doc ~S(The `req_llm` model spec, e.g. `"ollama:llama3.1"`.)
  @spec model() :: String.t() | nil
  def model, do: cfg(:model, nil)

  @doc """
  The configured provider name, from the `"provider:model"` spec.
  """
  @spec provider() :: String.t() | nil
  def provider, do: LLM.provider(model())

  @doc """
  Whether the configured provider sends content outside the deployment.

  Resolved from the endpoint's **host**, not the provider's name — see
  `KilnCMS.LLM.egress?/2`, which both this and `KilnCMS.Assist` delegate to so
  the two features can never disagree about what leaves the box.
  """
  @spec egress?() :: boolean()
  def egress?, do: enabled?() and LLM.egress?(model(), cfg(:base_url, nil))

  @doc """
  The endpoint host drafting would talk to, as configured. `nil` when the
  provider's default is in use and we can't see it from here.
  """
  @spec endpoint_host() :: String.t() | nil
  def endpoint_host, do: LLM.endpoint_host(model(), cfg(:base_url, nil))

  @spec title_max() :: pos_integer()
  def title_max, do: cfg(:title_max, 60)

  @spec description_max() :: pos_integer()
  def description_max, do: cfg(:description_max, 160)

  @spec keyword_max() :: pos_integer()
  def keyword_max, do: cfg(:keyword_max, 5)

  @spec max_input_chars() :: pos_integer()
  def max_input_chars, do: cfg(:max_input_chars, 12_000)

  @doc """
  Where drafting goes for the site `org_id`: `{:ok, generator, route}`,
  `{:error, :disabled}` when neither the site nor the operator has it on, or
  `{:error, {:site_provider, reason}}` when the site's own provider is set but
  unusable — refused, never sent to the operator's (see
  `KilnCMS.LLM.SiteProvider`).
  """
  @spec route(term()) ::
          {:ok, module(), Route.t()} | {:error, :disabled | {:site_provider, term()}}
  def route(org_id) do
    case SiteProvider.resolve(org_id, :seo) do
      :operator -> if enabled?(), do: {:ok, generator(), operator_route()}, else: disabled()
      :off -> disabled()
      {:site, route} -> {:ok, KilnCMS.Seo.Generator.ReqLLM, route}
      {:error, reason} -> {:error, {:site_provider, reason}}
    end
  end

  defp disabled, do: {:error, :disabled}

  @doc false
  @spec operator_route() :: Route.t()
  def operator_route, do: Route.operator(model())

  @doc """
  What the editor needs to know about drafting on the site `org_id`, from one
  resolve: whether to offer it, whether it leaves the deployment, and where to.

  A site whose own provider is set but unusable reports `enabled?: true`, so
  the control is there to click and the refusal can say what to fix.
  """
  @spec summary(Ash.UUID.t() | nil) :: LLM.summary()
  def summary(org_id), do: LLM.summary(route(org_id), cfg(:base_url, nil))

  @spec request_opts() :: keyword()
  def request_opts, do: request_opts(operator_route())

  @doc """
  Request options for `route`. The operator's `base_url` is added only to the
  operator's route: a site's route carries its own endpoint.
  """
  @spec request_opts(Route.t()) :: keyword()
  def request_opts(%Route{source: source}) do
    opts = [
      temperature: cfg(:temperature, 0.3),
      max_tokens: cfg(:max_tokens, 700),
      receive_timeout: cfg(:timeout_ms, 20_000)
    ]

    if source == :operator, do: put_base_url(opts, cfg(:base_url, nil)), else: opts
  end

  # `base_url` has to reach the request, not just `egress?/0`. Read only by the
  # classifier it would be a key that silences the egress warning without
  # moving a single byte — see the twin in `KilnCMS.Assist.request_opts/0`.
  defp put_base_url(opts, nil), do: opts
  defp put_base_url(opts, base_url), do: Keyword.put(opts, :base_url, base_url)

  @doc """
  The minimum body length worth drafting from.

  Below this the model would be inventing a description from a title rather
  than summarizing anything, which burns tokens to hallucinate.
  """
  @spec min_words() :: pos_integer()
  def min_words, do: cfg(:min_words, 50)

  @doc """
  Draft SEO metadata for `document`.

  Returns `{:error, :disabled}` when unconfigured, `{:error, :too_short}` below
  `min_words/0`, and `{:error, {:rate_limited, retry_after_ms}}` when a budget
  bucket is exhausted. A generator that raises degrades to `{:error, :crashed}`
  rather than taking the caller down — the same posture `KilnCMS.Ask` takes.

  `opts` accepts `:org_id` and `:user_id` for rate limiting; each bucket is
  skipped when its id isn't supplied (a mix task or a test). `:org_id` also
  picks the site's own provider when it has one (`route/1`), and a site whose
  provider is set but unusable gets `{:error, {:site_provider, reason}}`.

  `unattended?: true` marks a call nobody is waiting on — an automation
  reaction rather than an editor's click. Those stop once the org has spent
  `unattended_share/0` of its window, so an editor's "Suggest with AI" always
  has the remainder available (#943). They can also come back
  `{:error, :unattended_disabled}`, which is a configuration decision rather
  than an overload to wait out.
  """
  @spec draft(Document.t(), keyword()) :: {:ok, Draft.t()} | {:error, term()}
  def draft(%Document{} = document, opts \\ []) do
    with {:ok, generator, route} <- route(opts[:org_id]),
         :ok <- check_length(document) do
      Budget.charge("seo", opts[:org_id], opts[:user_id], budget_limits(opts), fn ->
        run(generator, route, document, opts)
      end)
    end
  end

  defp budget_limits(opts) do
    [
      per_user: cfg(:per_user_limit, {20, :timer.minutes(1)}),
      per_org: cfg(:per_org_limit, {200, :timer.hours(1)}),
      unattended?: Keyword.get(opts, :unattended?, false),
      unattended_share: unattended_share()
    ]
  end

  @doc """
  The share of the per-org window an unattended caller may let the org reach.

  Everything above it is reserved for an editor clicking "Suggest with AI" —
  see `KilnCMS.LLM.Budget`. Set it to `0.0` to stop automation drafting
  metadata against this budget entirely; `1.0` restores the pre-#943
  behaviour, where a background rule could take the last unit.
  """
  @spec unattended_share() :: float()
  def unattended_share, do: cfg(:unattended_share, 0.5)

  defp check_length(document) do
    words = document.body_text |> String.split(~r/\s+/u, trim: true) |> length()
    if words >= min_words(), do: :ok, else: {:error, :too_short}
  end

  defp run(generator, route, document, opts) do
    started = System.monotonic_time()
    result = safe_draft(generator, route, document, opts)

    :telemetry.execute(
      [:kiln_cms, :seo, :draft, :stop],
      %{duration: System.monotonic_time() - started} |> Map.merge(usage_measurements(result)),
      %{
        org_id: opts[:org_id],
        model: route.model,
        provider: LLM.route_provider(route),
        source: route.source,
        outcome: outcome(result)
      }
    )

    result
  end

  defp safe_draft(generator, route, document, opts) do
    case generator.draft(document, generator_opts(route, opts)) do
      {:ok, %Draft{} = draft} -> {:ok, draft |> Draft.normalize() |> stamp(route)}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
    end
  rescue
    exception ->
      Logger.error("SEO draft generator crashed: #{Exception.message(exception)}")
      {:error, :crashed}
  catch
    :exit, reason ->
      Logger.error("SEO draft generator exited: #{inspect(reason)}")
      {:error, :crashed}
  end

  # Only a site's route is handed over: it always runs the shipped adapter,
  # and an operator's bespoke generator is given exactly what it was before.
  defp generator_opts(%Route{source: :site} = route, opts), do: Keyword.put(opts, :llm, route)
  defp generator_opts(_route, opts), do: opts

  defp stamp(%Draft{model: nil} = draft, route), do: %{draft | model: route.model}
  defp stamp(draft, _route), do: draft

  defp usage_measurements({:ok, %Draft{usage: %{} = usage}}) do
    Map.take(usage, [:input_tokens, :output_tokens])
  end

  defp usage_measurements(_result), do: %{}

  defp outcome({:ok, _draft}), do: :ok
  defp outcome({:error, reason}) when is_atom(reason), do: reason
  defp outcome({:error, _reason}), do: :error

  defp cfg(key, default) do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
