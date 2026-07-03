defmodule KilnCMSWeb.SearchApiController do
  @moduledoc """
  Headless **hybrid search** (`GET /api/search?q=…`) — the query surface the
  search roadmap (#4) left open: keyword + semantic legs fused by RRF (and
  reranked when enabled), which no single Ash action can express, so it ships
  as a thin controller over `KilnCMS.Search.global/2`.

  Anonymous requests see published content only (the read policies); a bearer
  token widens visibility like every other headless surface. Sections mirror
  `global/2` (`pages`/`posts`/`entries` — media is an authoring concern, not
  a content-search result). Each hit carries its public `path` and an
  escape-safe `highlight` snippet (only `<mark>` survives). A zero-result
  query returns a `suggestion` ("did you mean") when a published title is
  trigram-close.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.I18n
  alias KilnCMS.Search
  alias KilnCMS.Search.Highlight

  @max_limit 25
  @default_limit 10

  def index(conn, params) do
    query = params["q"] |> to_string() |> String.trim()
    locale = validated_locale(params["locale"])
    limit = clamped_limit(params["limit"])

    if query == "" do
      json(conn, %{query: query, locale: locale, results: empty_sections(), suggestion: nil})
    else
      search(conn, query, locale, limit)
    end
  end

  defp search(conn, query, locale, limit) do
    read_opts = [
      actor: conn.assigns[:current_user],
      authorize?: true,
      locale: locale,
      limit: limit
    ]

    sections = Search.global(query, read_opts ++ [highlight: true])

    results = %{
      pages: Enum.map(sections.pages, &item(&1, "page", ContentTypes.get(:page), locale)),
      posts: Enum.map(sections.posts, &item(&1, "post", ContentTypes.get(:post), locale)),
      entries: Enum.flat_map(sections.entries, &entry_item(&1, locale))
    }

    total = results |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
    Search.record_query(query, total, locale: locale)

    suggestion = if total == 0, do: Search.suggest(query, read_opts), else: nil

    json(conn, %{query: query, locale: locale, results: results, suggestion: suggestion})
  end

  defp item(record, type, ct, locale) do
    %{
      id: record.id,
      type: type,
      title: record.title,
      slug: record.slug,
      path: I18n.localized_path(locale, "#{ContentTypes.public_prefix(ct)}/#{record.slug}"),
      highlight: highlight(record)
    }
  end

  # A dynamic hit resolves its type through the registry for URL + label;
  # hits whose type no longer resolves (archived mid-flight) are dropped.
  defp entry_item(record, locale) do
    case ContentTypes.get_dynamic(record.type_name) do
      nil -> []
      ct -> [item(record, record.type_name, ct, locale)]
    end
  end

  # The ts_headline snippet, reduced to escape-safe HTML (only <mark> lives).
  defp highlight(record) do
    case Map.get(record, :highlight) do
      snippet when is_binary(snippet) and snippet != "" ->
        snippet |> Highlight.to_safe_html() |> Phoenix.HTML.safe_to_string()

      _none ->
        nil
    end
  end

  defp empty_sections, do: %{pages: [], posts: [], entries: []}

  defp validated_locale(locale) do
    if locale in I18n.locales(), do: locale, else: I18n.default_locale()
  end

  defp clamped_limit(limit) do
    case Integer.parse(to_string(limit)) do
      {n, ""} when n in 1..@max_limit -> n
      _other -> @default_limit
    end
  end
end
