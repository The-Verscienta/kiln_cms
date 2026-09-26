defmodule KilnCMS.Assist do
  @moduledoc """
  Block-level AI assist for the content editor (#60).

  The author picks one block and one action — draft, continue, summarize,
  rewrite, shorten, expand — and gets prose back to accept or throw away. The
  companion to `KilnCMS.Seo`, which drafts a page's *metadata*; this drafts its
  *body*.

  ## Enabling it

      config :kiln_cms, KilnCMS.Assist,
        generator: KilnCMS.Assist.Generator.ReqLLM,
        model: "ollama:llama3.1"

  **Off by default** (`generator: nil`): on a default install no module is
  called, the editor renders no assist control, and nothing leaves the
  deployment. Enabling `KilnCMS.Seo` does not enable this — see
  `KilnCMS.Assist.Generator` for why the switches are separate.

  The shipped adapter is provider-agnostic. `req_llm` carries `ollama` and
  `vllm` providers, and every provider's `base_url` is overridable, so an
  on-prem endpoint needs no Kiln code. `egress?/0` reports which choice the
  operator actually made; `KilnCMS.Application` logs a warning at boot when a
  third-party provider is configured, and the editor shows a standing notice
  next to the control.

  The operator's API keys are never read or stored by Kiln: `req_llm`
  resolves them itself from its own config and environment
  (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, …).

  ## A site's own provider (#1557)

  As for `KilnCMS.Seo`: `route/1` resolves the site's own provider first
  (`KilnCMS.LLM.SiteProvider`). A site with one switched on uses it and
  nothing of the operator's; a site whose provider is set but unusable gets
  `{:error, {:site_provider, reason}}`, never the operator's provider. The
  zero-arity `enabled?/0`, `egress?/0` and friends describe the operator's
  configuration only; the editor uses `summary/1`.

  ## What this module will not do

  It does not write to a record, and it does not touch the block tree. `run/2`
  is a pure request/response over strings; the editor pushes the result to the
  browser and TipTap applies it as a client-side command only after a human
  clicks. Server-mutating a rich-text block would force the document back into
  the editor mid-edit, discarding the author's cursor and undo stack and
  desynchronizing anyone collaborating on it.
  """

  require Logger

  alias KilnCMS.Assist.Request
  alias KilnCMS.Assist.Suggestion
  alias KilnCMS.LLM
  alias KilnCMS.LLM.Budget
  alias KilnCMS.LLM.Route
  alias KilnCMS.LLM.SiteProvider

  @doc "Whether block assist is configured. False on a default install."
  @spec enabled?() :: boolean()
  def enabled?, do: not is_nil(generator()) and not is_nil(model())

  @spec generator() :: module() | nil
  def generator, do: cfg(:generator, nil)

  @doc ~S(The `req_llm` model spec, e.g. `"ollama:llama3.1"`.)
  @spec model() :: String.t() | nil
  def model, do: cfg(:model, nil)

  @doc "The configured provider name, from the `\"provider:model\"` spec."
  @spec provider() :: String.t() | nil
  def provider, do: LLM.provider(model())

  @doc """
  Whether the configured provider sends content outside the deployment.

  Resolved from the endpoint host, not the provider name — see
  `KilnCMS.LLM.egress?/2`.
  """
  @spec egress?() :: boolean()
  def egress?, do: enabled?() and LLM.egress?(model(), cfg(:base_url, nil))

  @doc "The endpoint host assist would talk to, as configured."
  @spec endpoint_host() :: String.t() | nil
  def endpoint_host, do: LLM.endpoint_host(model(), cfg(:base_url, nil))

  @doc "Largest block passage sent, in characters."
  @spec max_input_chars() :: pos_integer()
  def max_input_chars, do: cfg(:max_input_chars, 8_000)

  @doc "Largest author instruction sent, in characters."
  @spec max_instruction_chars() :: pos_integer()
  def max_instruction_chars, do: cfg(:max_instruction_chars, 500)

  @doc "Largest suggestion kept, in characters."
  @spec max_output_chars() :: pos_integer()
  def max_output_chars, do: cfg(:max_output_chars, 6_000)

  @doc """
  Where assist goes for the site `org_id` — the same contract as
  `KilnCMS.Seo.route/1`.
  """
  @spec route(term()) ::
          {:ok, module(), Route.t()} | {:error, :disabled | {:site_provider, term()}}
  def route(org_id) do
    case SiteProvider.resolve(org_id, :assist) do
      :operator -> if enabled?(), do: {:ok, generator(), operator_route()}, else: disabled()
      :off -> disabled()
      {:site, route} -> {:ok, KilnCMS.Assist.Generator.ReqLLM, route}
      {:error, reason} -> {:error, {:site_provider, reason}}
    end
  end

  defp disabled, do: {:error, :disabled}

  @doc false
  @spec operator_route() :: Route.t()
  def operator_route, do: Route.operator(model())

  @doc "What the editor needs to know about assist on the site `org_id`. See `KilnCMS.Seo.summary/1`."
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
      # Warmer than SEO's 0.3: that path wants the most predictable phrasing of
      # a fixed fact, this one is drafting prose a person will edit.
      temperature: cfg(:temperature, 0.6),
      max_tokens: cfg(:max_tokens, 1_200),
      receive_timeout: cfg(:timeout_ms, 45_000)
    ]

    if source == :operator, do: put_base_url(opts, cfg(:base_url, nil)), else: opts
  end

  # `base_url` has to reach the request, not just `egress?/0`. Read only by the
  # classifier it would be a key that silences the egress warning without
  # moving a single byte — an operator pointing it at `http://10.0.0.5:8000`
  # would be told their content stayed home while `req_llm` fell back to the
  # provider's default and shipped it to the vendor.
  defp put_base_url(opts, nil), do: opts
  defp put_base_url(opts, base_url), do: Keyword.put(opts, :base_url, base_url)

  @doc """
  Generate a suggestion for `request`.

  Returns `{:error, :disabled}` when unconfigured, `{:error, :too_short}` /
  `{:error, :no_instruction}` / `{:error, :unknown_action}` when the request
  can't be honoured, `{:error, {:rate_limited, retry_after_ms}}` when a budget
  bucket is exhausted, and `{:error, :empty}` when nothing usable survived
  normalization. A generator that raises degrades to `{:error, :crashed}`
  rather than taking the caller down — the same posture `KilnCMS.Seo` and
  `KilnCMS.Ask` take.

  `opts` accepts `:org_id` and `:user_id` for rate limiting; both buckets are
  skipped when they aren't supplied (a mix task or a test). `:org_id` also
  picks the site's own provider when it has one (`route/1`).
  """
  @spec run(Request.t(), keyword()) :: {:ok, Suggestion.t()} | {:error, term()}
  def run(%Request{} = request, opts \\ []) do
    with {:ok, generator, route} <- route(opts[:org_id]),
         :ok <- Request.validate(request),
         :ok <- Budget.check("assist", opts[:org_id], opts[:user_id], budget_limits()) do
      measured(generator, route, request, opts)
    end
  end

  defp budget_limits do
    [
      per_user: cfg(:per_user_limit, {10, :timer.minutes(1)}),
      per_org: cfg(:per_org_limit, {150, :timer.hours(1)})
    ]
  end

  defp measured(generator, route, request, opts) do
    started = System.monotonic_time()
    result = safe_generate(generator, route, request, opts)

    :telemetry.execute(
      [:kiln_cms, :assist, :generate, :stop],
      %{duration: System.monotonic_time() - started} |> Map.merge(usage_measurements(result)),
      %{
        org_id: opts[:org_id],
        action: request.action,
        model: route.model,
        provider: LLM.route_provider(route),
        source: route.source,
        outcome: outcome(result)
      }
    )

    result
  end

  defp safe_generate(generator, route, request, opts) do
    request
    # The rate-limiting ids stay here. `Request` is documented — in its own
    # moduledoc, in the behaviour, and in docs/ai-assist.md — as the complete
    # list of what a generator sees, and a bespoke generator written against
    # that contract would otherwise be handed the tenant and actor uuids.
    |> generator.generate(generator_opts(route, Keyword.drop(opts, [:org_id, :user_id])))
    |> normalize(request, route)
  rescue
    exception ->
      Logger.error("Assist generator crashed: #{Exception.message(exception)}")
      {:error, :crashed}
  catch
    :exit, reason ->
      Logger.error("Assist generator exited: #{inspect(reason)}")
      {:error, :crashed}
  end

  # The generator returns raw text; every path through here goes via
  # `Suggestion.normalize/2`, so no generator can hand a caller text it hasn't
  # cleaned. Usage is optional so a bespoke implementation needn't fake it.
  defp normalize({:ok, text}, request, route), do: normalize({:ok, text, %{}}, request, route)

  defp normalize({:ok, text, usage}, request, route) do
    case Suggestion.normalize(text, request.action) do
      {:ok, suggestion} -> {:ok, %{suggestion | model: route.model, usage: usage}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize({:error, reason}, _request, _route), do: {:error, reason}
  defp normalize(other, _request, _route), do: {:error, {:unexpected, other}}

  # Only a site's route is handed over: it always runs the shipped adapter,
  # and an operator's bespoke generator is given exactly what it was before.
  defp generator_opts(%Route{source: :site} = route, opts), do: Keyword.put(opts, :llm, route)
  defp generator_opts(_route, opts), do: opts

  defp usage_measurements({:ok, %Suggestion{usage: %{} = usage}}) do
    Map.take(usage, [:input_tokens, :output_tokens])
  end

  defp usage_measurements(_result), do: %{}

  defp outcome({:ok, _suggestion}), do: :ok
  defp outcome({:error, reason}) when is_atom(reason), do: reason
  defp outcome({:error, _reason}), do: :error

  defp cfg(key, default) do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
