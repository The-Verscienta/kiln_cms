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

  Resolved from the endpoint's **host**, not the provider's name. Keying on the
  name alone was wrong in the one direction that matters: `req_llm` lets any
  provider's `base_url` be overridden — the very mechanism this module
  recommends for on-prem — so `ollama:` pointed at a remote host reported "no
  egress" while every page body left the deployment, silencing both the boot
  warning and the editor's standing notice.

  `false` only when the resolved host is loopback or a private address.
  Anything unrecognized reads as egress: over-warning is cheap, and quietly
  promising an operator their content stayed home is not.
  """
  @spec egress?() :: boolean()
  def egress? do
    enabled?() and not local_endpoint?()
  end

  @doc """
  The endpoint host drafting would talk to, as configured. `nil` when the
  provider's default is in use and we can't see it from here.
  """
  @spec endpoint_host() :: String.t() | nil
  def endpoint_host do
    with nil <- host_from(cfg(:base_url, nil)),
         nil <- host_from(provider_base_url()) do
      default_host_for(provider())
    end
  end

  defp local_endpoint? do
    case endpoint_host() do
      nil -> false
      host -> loopback?(host) or private?(host)
    end
  end

  # An operator may override the endpoint either in our config or in req_llm's.
  defp provider_base_url do
    case provider() do
      nil -> nil
      name -> :req_llm |> Application.get_env(:"#{name}_base_url", nil) |> normalize_url()
    end
  end

  defp normalize_url(url) when is_binary(url), do: url
  defp normalize_url(_url), do: nil

  defp host_from(nil), do: nil

  defp host_from(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  # With no override, the on-prem providers default to a local daemon; every
  # other provider defaults to its own cloud API.
  defp default_host_for(name) when name in @local_providers, do: "localhost"
  defp default_host_for(_name), do: nil

  defp loopback?(host), do: host in ~w(localhost 127.0.0.1 ::1 0.0.0.0)

  defp private?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {10, _, _, _}} -> true
      {:ok, {192, 168, _, _}} -> true
      {:ok, {172, b, _, _}} when b >= 16 and b <= 31 -> true
      {:ok, {127, _, _, _}} -> true
      _ -> String.ends_with?(host, ".local") or String.ends_with?(host, ".internal")
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
