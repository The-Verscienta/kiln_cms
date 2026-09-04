defmodule KilnCMS.Search.Eval.Retriever do
  @moduledoc """
  The three ways `mix kiln.search.eval` turns a golden-set row into one
  ranked list of `t:KilnCMS.Search.Eval.hit/0`s.

    * `global/2` — in-process, through `KilnCMS.Search.global/2` over the
      content sections, exactly as `GET /api/search` reads: `authorize?:
      true` with **no actor**, so only published, world-readable content can
      score. The sections are then sorted together by fused score — the same
      cross-type order `KilnCMS.Ask` selects sources in, and the only one the
      scores support (they are comparable across sections because every
      section of a sweep shares `k` and the leg weights).
    * `ask/2` — in-process, through `KilnCMS.Ask.answer/2` with generation
      off: the ranked list is the `sources` a `/api/ask` client is handed.
      Ask clamps its limit to 12, so recall@k beyond that is recall@12.
    * `remote/2` — over HTTP against a live deployment's `/api/search` (or
      `/api/ask` with `ask: true`), reading the additive `score` and `legs`
      fields those endpoints carry. Nothing about the local database matters
      in this mode; it measures the deployment.

  The rank a row is judged on is a position in this one list — a typed row
  narrows it to one content type first (`KilnCMS.Search.Eval.judge/2`).
  """

  alias KilnCMS.Accounts
  alias KilnCMS.Ask
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Search
  alias KilnCMS.Search.Eval

  @typedoc """
  Options shared by the local retrievers:

    * `:tenant` — the org to search within (default: the default org).
    * `:limit` — hits per section (`global/2`) or sources (`ask/2`).
    * `:locale` — fallback for rows that carry none.
  """
  @type opts :: [tenant: term(), limit: pos_integer(), locale: String.t() | nil]

  @doc "Hits from `KilnCMS.Search.global/2`, sorted together by score."
  @spec global(Eval.row(), opts()) :: [Eval.hit()]
  def global(row, opts \\ []) do
    sections =
      Search.global(
        row.query,
        # The anonymous, published-only floor `GET /api/search` reads under:
        # `authorize?: true` and no actor. Pinned here rather than taken from
        # the options so no flag can make the evaluator score drafts the
        # public endpoint would never return.
        authorize?: true,
        tenant: Accounts.org_id(opts[:tenant]),
        locale: row.locale || opts[:locale],
        limit: Keyword.get(opts, :limit, 10),
        sections: Search.content_sections()
      )

    compiled =
      Enum.flat_map(ContentTypes.all(), fn ct ->
        sections
        |> Map.get(ct.section, [])
        |> Enum.map(&hit(&1.slug, to_string(ct.type), to_string(ct.section), &1))
      end)

    dynamic = Enum.map(sections.entries, &hit(&1.slug, &1.type_name, "entries", &1))

    # Stable, so ties keep the registry order — the same tiebreak Ask uses.
    Enum.sort_by(compiled ++ dynamic, &(&1.score || 0.0), :desc)
  end

  @doc "Hits in the order `KilnCMS.Ask.answer/2` cites them."
  @spec ask(Eval.row(), opts()) :: [Eval.hit()]
  def ask(row, opts \\ []) do
    %{sources: sources} =
      Ask.answer(row.query,
        tenant: Accounts.org_id(opts[:tenant]),
        locale: row.locale || opts[:locale],
        limit: Keyword.get(opts, :limit, 10),
        # Retrieval only: a configured generator would spend a model call per
        # golden-set row and change nothing about the ranking under test.
        generator: nil
      )

    Enum.map(sources, fn source ->
      %{
        slug: slug_from_url(source.url),
        type: source.type,
        section: section_for_type(source.type),
        score: source.score,
        legs: Enum.map(source.legs, &to_string/1)
      }
    end)
  end

  @typedoc """
  Options for `remote/2`: `:base_url` (required), `:ask` to read `/api/ask`
  instead of `/api/search`, `:limit`, `:locale`, and `:req` (extra `Req`
  options — a timeout, headers, or `retry:` to re-enable retries).
  """
  @type remote_opts :: [
          base_url: String.t(),
          ask: boolean(),
          limit: pos_integer(),
          locale: String.t() | nil,
          req: keyword()
        ]

  @doc """
  Hits from a live deployment's `/api/search` (or `/api/ask`), read off the
  `score`/`legs` fields. Raises on a non-200 or an unexpected body, naming the
  URL — an eval that scored an error page as "nothing returned" would pass
  every junk row and fail every other one for a reason the report never
  shows.
  """
  @spec remote(Eval.row(), remote_opts()) :: [Eval.hit()]
  def remote(row, opts) do
    base_url = Keyword.fetch!(opts, :base_url)
    ask? = Keyword.get(opts, :ask, false)
    path = if ask?, do: "/api/ask", else: "/api/search"

    params =
      [q: row.query, limit: Keyword.get(opts, :limit, 10)]
      |> put_locale(row.locale || opts[:locale])

    # No retries: a 502 mid-run should be reported as the failure it is and
    # the run repeated, not paper over a flapping deployment with a delay
    # the report never mentions. `:req` can turn them back on.
    request =
      Req.new(
        [base_url: base_url, url: path, params: params, retry: false] ++
          Keyword.get(opts, :req, [])
      )

    case Req.request(request) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        body = decode_body(body, path, base_url)
        if ask?, do: remote_ask_hits(body), else: remote_search_hits(body)

      {:ok, %Req.Response{status: status}} ->
        raise "#{path} at #{base_url} answered #{status} for #{inspect(row.query)}"

      {:error, reason} ->
        raise "#{path} at #{base_url} failed for #{inspect(row.query)}: #{inspect(reason)}"
    end
  end

  # Req decodes JSON on the content type; a proxy that relabels it hands the
  # text over undecoded, and the text is still the answer.
  defp decode_body(body, _path, _base_url) when is_map(body), do: body

  defp decode_body(body, path, base_url) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> raise "#{path} at #{base_url} did not answer with a JSON object"
    end
  end

  defp decode_body(_body, path, base_url),
    do: raise("#{path} at #{base_url} did not answer with a JSON object")

  defp put_locale(params, nil), do: params
  defp put_locale(params, locale), do: Keyword.put(params, :locale, locale)

  # `/api/search` sections: content hits carry `path`/`score`/`legs`; taxonomy
  # hits (`categories`, `tags`, `tag_groups`) carry `name`/`slug` only and are
  # not documents, so they are not ranks.
  defp remote_search_hits(%{"results" => results}) when is_map(results) do
    results
    |> Enum.flat_map(fn {section, items} when is_list(items) ->
      items
      |> Enum.filter(&(is_map(&1) and Map.has_key?(&1, "path") and is_binary(&1["slug"])))
      |> Enum.map(fn item ->
        %{
          slug: item["slug"],
          type: item["type"],
          section: section,
          score: item["score"],
          legs: List.wrap(item["legs"])
        }
      end)
    end)
    |> Enum.sort_by(&(&1.score || 0.0), :desc)
  end

  defp remote_search_hits(body), do: raise("unexpected /api/search body: #{inspect(body)}")

  defp remote_ask_hits(%{"sources" => sources}) when is_list(sources) do
    Enum.map(sources, fn source ->
      %{
        slug: slug_from_url(source["url"]),
        type: source["type"],
        section: nil,
        score: source["score"],
        legs: List.wrap(source["legs"])
      }
    end)
  end

  defp remote_ask_hits(body), do: raise("unexpected /api/ask body: #{inspect(body)}")

  defp hit(slug, type, section, record) do
    %{
      slug: slug,
      type: type,
      section: section,
      score: Search.hit_score(record),
      legs: Enum.map(Search.hit_legs(record), &to_string/1)
    }
  end

  # Ask sources carry a public URL rather than a slug; the slug is its last
  # segment for every content type (`/<prefix>/<slug>`, locale-prefixed or
  # not).
  defp slug_from_url(url) when is_binary(url) do
    url |> String.split("?", parts: 2) |> hd() |> String.trim_trailing("/") |> Path.basename()
  end

  defp slug_from_url(_other), do: ""

  defp section_for_type(type) do
    case Enum.find(ContentTypes.all(), &(to_string(&1.type) == type)) do
      nil -> "entries"
      ct -> to_string(ct.section)
    end
  end
end
