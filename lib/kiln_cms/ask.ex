defmodule KilnCMS.Ask do
  @moduledoc """
  "Ask your content" — retrieval-augmented answering over **published** content
  (RAG, issue #339). The retrieval half of the pipeline, plus a pluggable
  generation seam.

  `answer/2` retrieves the most relevant published passages via
  `KilnCMS.Search.global/2` (keyword + semantic RRF, reranked — degrading to
  keyword when semantic search is disabled, so it works with no model stack),
  assembles them into cited `sources`, and — if a generator is configured (see
  `KilnCMS.Ask.Generator`) — synthesizes an answer grounded in those sources.

  Retrieval is **policy-scoped**: an anonymous caller only ever sees published,
  world-readable content (the same read policies as every headless surface), so
  drafts and gated content can never leak into an answer or its citations.

  With no generator configured (the default), it returns retrieval-only:
  `answer: nil`, `generated: false`, `generation: :disabled`, `sources: [...]`.
  `generation` is what separates that permanent state from a transient one —
  see `t:generation/0`.

  ## Enabling generation

      config :kiln_cms, KilnCMS.Ask,
        generator: KilnCMS.Ask.Generator.ReqLLM,
        model: "ollama:llama3.1"

  **Off by default** (`generator: nil`): a default install calls no module and
  sends nothing anywhere. The shipped adapter is provider-agnostic — `req_llm`
  carries `ollama` and `vllm` alongside the hosted providers, and every
  provider's `base_url` is overridable, so an on-prem endpoint needs no Kiln
  code. `egress?/0` reports which choice the operator actually made, resolved
  from the endpoint host rather than the provider name (`KilnCMS.LLM`).

  ## Why this one is budgeted harder than the other AI features

  `KilnCMS.Seo` and `KilnCMS.Assist` are reached by an authenticated editor
  clicking a control. `/api/ask` is **public and anonymous**: the per-IP
  pipeline limiter allows 120 requests a minute, which is a fine ceiling for a
  search query and an absurd one for model inference. So generation carries its
  own `KilnCMS.LLM.Budget` buckets, and the caller-side bucket falls back to the
  client address when there is no user to key on — see `answer/2`'s
  `:client_id`. Exhausting a bucket degrades to retrieval-only; it never fails
  the request, because the sources are still a useful answer.

  ## Telling an anonymous caller they were throttled (#853)

  `generation: :rate_limited` is reported to anonymous callers too, and that is
  a decision rather than an oversight — a bucket's state is information about
  traffic, and one of the two buckets is shared.

  The per-caller bucket is keyed on the caller's address, which is *mostly*
  their own traffic reflected back — but not reliably. Everyone behind one NAT
  or proxy egress shares a key, and `KilnCMSWeb.RateLimit.client_key/1`
  collapses an unresolvable address to a single shared `"unknown"` bucket, so
  even the per-caller bucket can tell one stranger about another. The per-org
  bucket is shared by construction.

  And `retry_after` says which bucket it was, whether or not it means to. The
  two windows differ by default — a minute per caller, an hour per org — so any
  value above the per-caller window can only have come from the shared one, and
  it also says how far into that hour the org currently is.
  `KilnCMS.LLM.Budget.check/4` does not label the bucket, but the number gives
  it away, so treat this as disclosed rather than assuming it is not.

  Reported anyway, on two grounds: the pipeline's own per-IP limiter already
  answers 429 to the same anonymous caller and discloses more than an aggregate
  window position; and withholding it would preserve exactly the ambiguity #853
  exists to remove, in the case an operator most needs to diagnose — generation
  silently off for everyone because the shared bucket is spent. Clamping the
  reported value to the per-caller window was the alternative, and it is worse:
  it would tell a client to retry in a minute when the real wait is most of an
  hour, turning a disclosure into a lie the client acts on.
  """
  require Logger

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.I18n
  alias KilnCMS.LLM
  alias KilnCMS.LLM.Budget
  alias KilnCMS.Search
  alias KilnCMS.Search.Highlight

  @default_limit 6
  @max_limit 12

  @type source :: %{
          type: String.t(),
          title: String.t(),
          url: String.t(),
          excerpt: String.t() | nil
        }
  @typedoc """
  Why there is no generated answer, or `nil` when there is one (#853).

  `generated: false` on its own cannot be acted on: a client cannot tell "this
  deployment does not do generated answers, stop showing the spinner" from "you
  asked too fast, try again in a moment", and only the second has a recovery.

    * `:disabled` — no generator configured. The default install; permanent
      until an operator changes it.
    * `:rate_limited` — a `KilnCMS.LLM.Budget` bucket is exhausted. Transient;
      `retry_after` says for how long.
    * `:failed` — the generator errored, timed out, or returned nothing usable.
      Transient, but the caller cannot know when it clears.
    * `:no_question` — `q` was blank, so nothing was retrieved or generated.
      Not in #853's list, but the alternative was reporting `nil` (which means
      success) for a request that produced no answer at all.

  This is deliberately **coarser** than the `{:error, reason}` vocabulary
  `KilnCMS.Assist` and `KilnCMS.Seo` use internally, which separates `:crashed`
  from `:empty` from `:too_short`. Those two are reached by an authenticated
  editor who can act on the distinction; this one is public and anonymous, and
  the difference between "the model raised" and "the model returned whitespace"
  is not the caller's to act on — both mean *try again, we don't know when*.
  So they collapse into `:failed`, and only `:disabled` and `:rate_limited`,
  which carry genuinely different recoveries, stay apart.
  """
  @type generation :: :disabled | :rate_limited | :failed | :no_question | nil

  @type result :: %{
          question: String.t(),
          answer: String.t() | nil,
          generated: boolean(),
          generation: generation(),
          retry_after: pos_integer() | nil,
          sources: [source()]
        }

  @doc "Whether a generator is configured. False on a default install."
  @spec enabled?() :: boolean()
  def enabled?, do: not is_nil(generator())

  @doc """
  The configured generator module, or `nil`.

  The shipped `KilnCMS.Ask.Generator.ReqLLM` additionally needs `model/0`; a
  bespoke module may well not, which is why `enabled?/0` keys on this alone.
  """
  @spec generator() :: module() | nil
  def generator, do: cfg(:generator, nil)

  @doc ~S(The `req_llm` model spec, e.g. `"ollama:llama3.1"`. `nil` unless set.)
  @spec model() :: String.t() | nil
  def model, do: cfg(:model, nil)

  @doc "The configured provider name, from the `\"provider:model\"` spec."
  @spec provider() :: String.t() | nil
  def provider, do: LLM.provider(model())

  @doc """
  Whether answering sends content outside the deployment.

  Resolved from the endpoint host, not the provider name — see
  `KilnCMS.LLM.egress?/2`. `false` when no model is configured: a bespoke
  generator's destination is not ours to classify, and claiming egress we
  can't demonstrate is as misleading as denying egress we can.
  """
  @spec egress?() :: boolean()
  def egress?, do: enabled?() and LLM.egress?(model(), cfg(:base_url, nil))

  @doc "The endpoint host answering would talk to, as configured."
  @spec endpoint_host() :: String.t() | nil
  def endpoint_host, do: LLM.endpoint_host(model(), cfg(:base_url, nil))

  @doc "Largest answer kept, in characters."
  @spec max_output_chars() :: pos_integer()
  def max_output_chars, do: cfg(:max_output_chars, 4_000)

  @doc "Request options for the shipped `req_llm` adapter."
  @spec request_opts() :: keyword()
  def request_opts do
    [
      # Cooler than block assist's 0.6: this path restates retrieved facts, and
      # every degree of creativity here is a degree of confabulation.
      temperature: cfg(:temperature, 0.2),
      max_tokens: cfg(:max_tokens, 800),
      receive_timeout: cfg(:timeout_ms, 30_000)
    ]
    |> put_base_url(cfg(:base_url, nil))
  end

  # `base_url` has to reach the request, not just `egress?/0`. Read only by the
  # classifier it would be a key that silences the egress warning without moving
  # a single byte — the same trap `KilnCMS.Assist` documents.
  defp put_base_url(opts, nil), do: opts
  defp put_base_url(opts, base_url), do: Keyword.put(opts, :base_url, base_url)

  @doc """
  Answer `question` from published content.

  Options:

    * `:actor` — the requesting user (widens visibility beyond published for
      editors/admins, exactly like other read paths); omit for anonymous.
    * `:authorize?` — defaults to `true` (published-only for anonymous).
    * `:locale` — content locale (defaults to the configured default).
    * `:limit` — max sources to retrieve (clamped to #{@max_limit}).
    * `:generator` — override the configured generator module (mainly for tests).
    * `:client_id` — what to key the caller's generation budget on when there is
      no actor (the controller passes the client address). Ignored when an
      actor is present, and skipping the bucket entirely when neither is given,
      the same way `KilnCMS.LLM.Budget` treats a `nil` id everywhere else.

  Retrieval always runs. Generation is skipped — leaving `answer: nil,
  generated: false` — when no generator is configured, when a budget bucket is
  exhausted, or when the generator errors. `generation` says which of those it
  was, and `retry_after` (seconds) is set for the one case that has a deadline.
  """
  @spec answer(String.t(), keyword()) :: result()
  def answer(question, opts \\ []) do
    question = question |> to_string() |> String.trim()

    if question == "" do
      result(question, nil, [], :no_question, nil)
    else
      locale = validate_locale(opts[:locale])

      read_opts = [
        actor: opts[:actor],
        authorize?: Keyword.get(opts, :authorize?, true),
        # Tenant (#336): retrieval via `Search.global` scopes to this org.
        tenant: opts[:tenant],
        locale: locale,
        limit: clamp(opts[:limit])
      ]

      sources = retrieve(question, read_opts)
      generator = Keyword.get(opts, :generator, generator())

      case generate(generator, question, sources, locale, opts) do
        {:ok, answer} ->
          result(question, answer, sources, nil, nil)

        :disabled ->
          result(question, nil, sources, :disabled, nil)

        # The only outcome with a deadline the caller can act on. Rounded
        # through `AccountThrottle.retry_after_seconds/1` rather than here:
        # it is exported precisely so the surfaces that answer "come back in N
        # seconds" round the same way, and it already never answers 0 — which
        # would invite an immediate retry straight into another refusal.
        {:error, {:budget, retry_after_ms}} ->
          result(question, nil, sources, :rate_limited, retry_after_seconds(retry_after_ms))

        _error ->
          result(question, nil, sources, :failed, nil)
      end
    end
  end

  # `generated` is kept, and kept as the plain boolean it always was: it is the
  # field existing clients read, and #853 is additive by construction.
  defp result(question, answer, sources, generation, retry_after) do
    %{
      question: question,
      answer: answer,
      generated: not is_nil(answer),
      generation: generation,
      retry_after: retry_after,
      sources: sources
    }
  end

  defp retry_after_seconds(ms), do: AccountThrottle.retry_after_seconds(ms)

  # --- retrieval -------------------------------------------------------------

  defp retrieve(question, read_opts) do
    locale = Keyword.fetch!(read_opts, :locale)
    limit = Keyword.fetch!(read_opts, :limit)
    sections = Search.global(question, read_opts ++ [highlight: true])

    compiled =
      Enum.flat_map(ContentTypes.all(), fn ct ->
        sections
        |> Map.get(ct.section, [])
        |> Enum.map(&source(&1, to_string(ct.type), ct, locale))
      end)

    dynamic =
      Enum.flat_map(sections.entries, fn record ->
        # Resolve the entry's dynamic type within its own site (epic #336).
        case ContentTypes.get_dynamic(record.type_name, record.org_id) do
          nil -> []
          ct -> [source(record, record.type_name, ct, locale)]
        end
      end)

    # Sections come back already ranked within a type; interleave by taking the
    # strongest across types up to the limit (compiled first, then dynamic).
    (compiled ++ dynamic) |> Enum.take(limit)
  end

  defp source(record, type, ct, locale) do
    %{
      type: type,
      title: record.title,
      url: I18n.localized_path(locale, "#{ContentTypes.public_prefix(ct)}/#{record.slug}"),
      excerpt: excerpt(record)
    }
  end

  # The ts_headline snippet, flattened to plain text (drop the <mark> tags) so it
  # can ground a generator or show as a citation preview.
  defp excerpt(record) do
    case Map.get(record, :highlight) do
      snippet when is_binary(snippet) and snippet != "" ->
        snippet
        |> Highlight.to_safe_html()
        |> Phoenix.HTML.safe_to_string()
        |> String.replace(~r/<[^>]+>/, "")

      _none ->
        nil
    end
  end

  # --- generation seam -------------------------------------------------------

  defp generate(nil, _question, _sources, _locale, _opts), do: :disabled

  defp generate(module, question, sources, locale, opts) when is_atom(module) do
    with :ok <- check_budget(opts) do
      module
      |> invoke(question, sources, locale)
      |> normalize()
    end
  end

  # `generate/3` is the preferred arity — it carries the content locale — but
  # the behaviour's required callback is still `generate/2` (#361's contract),
  # so a generator written before this existed must keep working untouched.
  defp invoke(module, question, sources, locale) do
    if Code.ensure_loaded?(module) and function_exported?(module, :generate, 3) do
      module.generate(question, sources, locale: locale)
    else
      module.generate(question, sources)
    end
  rescue
    error ->
      # A generator failure must degrade to retrieval-only, never 500 the ask.
      Logger.error("Ask generator #{inspect(module)} failed: #{Exception.message(error)}")
      {:error, error}
  catch
    :exit, reason ->
      Logger.error("Ask generator #{inspect(module)} exited: #{inspect(reason)}")
      {:error, reason}
  end

  # No generator can hand a caller text it hasn't been through here: an answer
  # is echoed to an anonymous HTTP client, and a model that ignores the length
  # rule (or a compromised endpoint that streams megabytes) must not be able to
  # decide the response size.
  defp normalize({:ok, text}) when is_binary(text) do
    case text |> String.trim() |> String.slice(0, max_output_chars()) do
      "" -> {:error, :empty}
      answer -> {:ok, answer}
    end
  end

  defp normalize({:error, reason}), do: {:error, reason}
  defp normalize(other), do: {:error, {:unexpected, other}}

  # Anonymous callers key the caller bucket on the client address; without that
  # fallback the only real ceiling on a public endpoint would be the org bucket,
  # which one client could exhaust for everybody.
  defp check_budget(opts) do
    caller_id =
      case opts[:actor] do
        %{id: id} -> id
        _anonymous -> opts[:client_id]
      end

    case Budget.check("ask", opts[:tenant], caller_id, budget_limits()) do
      :ok ->
        :ok

      # Re-tagged, not passed through. `normalize/1` hands a generator's own
      # `{:error, reason}` back untouched, so an adapter forwarding a provider
      # 429 as `{:error, {:rate_limited, ms}}` would otherwise land in the same
      # clause and be reported as one of OUR buckets — sending an operator to
      # inspect `per_user_limit` for a limit that lives at the provider.
      {:error, {:rate_limited, retry_after_ms}} ->
        Logger.info("Ask generation rate-limited; degrading to retrieval-only")
        {:error, {:budget, retry_after_ms}}
    end
  end

  defp budget_limits do
    [
      # Tighter than assist's per-user allowance: that bucket identifies a
      # signed-in editor, this one usually identifies an IP address.
      per_user: cfg(:per_user_limit, {5, :timer.minutes(1)}),
      per_org: cfg(:per_org_limit, {300, :timer.hours(1)})
    ]
  end

  defp cfg(key, default) do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end

  defp validate_locale(locale) do
    if locale in I18n.locales(), do: locale, else: I18n.default_locale()
  end

  defp clamp(nil), do: @default_limit
  defp clamp(n) when is_integer(n) and n > 0, do: min(n, @max_limit)
  defp clamp(_), do: @default_limit
end
