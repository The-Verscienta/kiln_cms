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

  API keys are never read or stored by Kiln: `req_llm` resolves them itself
  from its own config and environment (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
  …), so no new secret enters Kiln's config, database or release env.
  """

  require Logger

  alias KilnCMS.Seo.Budget
  alias KilnCMS.Seo.Document
  alias KilnCMS.Seo.Draft

  # Providers that run inside the deployment. Anything else is egress.
  @local_providers ~w(ollama vllm)

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
  def provider do
    case model() do
      nil -> nil
      spec -> spec |> to_string() |> String.split(":", parts: 2) |> hd()
    end
  end

  @doc """
  Whether the configured provider sends content outside the deployment.

  `false` for on-prem runtimes (`ollama`, `vllm`) and when drafting is off.
  Errs toward `true` for anything unrecognized — an unknown provider should
  read as egress until an operator says otherwise, not the reverse.
  """
  @spec egress?() :: boolean()
  def egress? do
    cond do
      not enabled?() -> false
      provider() in @local_providers -> false
      true -> true
    end
  end

  @spec title_max() :: pos_integer()
  def title_max, do: cfg(:title_max, 60)

  @spec description_max() :: pos_integer()
  def description_max, do: cfg(:description_max, 160)

  @spec keyword_max() :: pos_integer()
  def keyword_max, do: cfg(:keyword_max, 5)

  @spec max_input_chars() :: pos_integer()
  def max_input_chars, do: cfg(:max_input_chars, 12_000)

  @spec request_opts() :: keyword()
  def request_opts do
    [
      temperature: cfg(:temperature, 0.3),
      max_tokens: cfg(:max_tokens, 700),
      receive_timeout: cfg(:timeout_ms, 20_000)
    ]
  end

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

  `opts` accepts `:org_id` and `:user_id` for rate limiting; both buckets are
  skipped when they aren't supplied (a mix task or a test).
  """
  @spec draft(Document.t(), keyword()) :: {:ok, Draft.t()} | {:error, term()}
  def draft(%Document{} = document, opts \\ []) do
    with :ok <- check_enabled(),
         :ok <- check_length(document),
         :ok <- Budget.check(opts[:org_id], opts[:user_id]) do
      run(document, opts)
    end
  end

  defp check_enabled, do: if(enabled?(), do: :ok, else: {:error, :disabled})

  defp check_length(document) do
    words = document.body_text |> String.split(~r/\s+/u, trim: true) |> length()
    if words >= min_words(), do: :ok, else: {:error, :too_short}
  end

  defp run(document, opts) do
    started = System.monotonic_time()
    result = safe_draft(document, opts)

    :telemetry.execute(
      [:kiln_cms, :seo, :draft, :stop],
      %{duration: System.monotonic_time() - started} |> Map.merge(usage_measurements(result)),
      %{
        org_id: opts[:org_id],
        model: model(),
        provider: provider(),
        outcome: outcome(result)
      }
    )

    result
  end

  defp safe_draft(document, opts) do
    case generator().draft(document, opts) do
      {:ok, %Draft{} = draft} -> {:ok, draft |> Draft.normalize() |> stamp()}
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

  defp stamp(%Draft{model: nil} = draft), do: %{draft | model: model()}
  defp stamp(draft), do: draft

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
