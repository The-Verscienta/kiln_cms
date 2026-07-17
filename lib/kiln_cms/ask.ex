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
  `answer: nil`, `generated: false`, `sources: [...]`.
  """
  require Logger

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.I18n
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
  @type result :: %{
          question: String.t(),
          answer: String.t() | nil,
          generated: boolean(),
          sources: [source()]
        }

  @doc """
  Answer `question` from published content.

  Options:

    * `:actor` — the requesting user (widens visibility beyond published for
      editors/admins, exactly like other read paths); omit for anonymous.
    * `:authorize?` — defaults to `true` (published-only for anonymous).
    * `:locale` — content locale (defaults to the configured default).
    * `:limit` — max sources to retrieve (clamped to #{@max_limit}).
    * `:generator` — override the configured generator module (mainly for tests).
  """
  @spec answer(String.t(), keyword()) :: result()
  def answer(question, opts \\ []) do
    question = question |> to_string() |> String.trim()

    if question == "" do
      %{question: question, answer: nil, generated: false, sources: []}
    else
      locale = validate_locale(opts[:locale])

      read_opts = [
        actor: opts[:actor],
        authorize?: Keyword.get(opts, :authorize?, true),
        locale: locale,
        limit: clamp(opts[:limit])
      ]

      sources = retrieve(question, read_opts)
      generator = Keyword.get(opts, :generator, configured_generator())

      case generate(generator, question, sources) do
        {:ok, answer} when is_binary(answer) ->
          %{question: question, answer: answer, generated: true, sources: sources}

        _none_or_error ->
          %{question: question, answer: nil, generated: false, sources: sources}
      end
    end
  end

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
        case ContentTypes.get_dynamic(record.type_name) do
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

  defp generate(nil, _question, _sources), do: :disabled

  defp generate(module, question, sources) when is_atom(module) do
    module.generate(question, sources)
  rescue
    error ->
      # A generator failure must degrade to retrieval-only, never 500 the ask.
      Logger.error("Ask generator #{inspect(module)} failed: #{Exception.message(error)}")
      {:error, error}
  end

  defp configured_generator do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(:generator)
  end

  defp validate_locale(locale) do
    if locale in I18n.locales(), do: locale, else: I18n.default_locale()
  end

  defp clamp(nil), do: @default_limit
  defp clamp(n) when is_integer(n) and n > 0, do: min(n, @max_limit)
  defp clamp(_), do: @default_limit
end
