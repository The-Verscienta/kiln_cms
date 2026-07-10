defmodule KilnCMSWeb.SearchApiController do
  @moduledoc """
  Headless **hybrid search** (`GET /api/search?q=…`) — the query surface the
  search roadmap (#4) left open: keyword + semantic legs fused by RRF (and
  reranked when enabled), which no single Ash action can express, so it ships
  as a thin controller over `KilnCMS.Search.global/2`.

  Anonymous requests see published content only (the read policies); a bearer
  token widens visibility like every other headless surface. Sections mirror
  `global/2` — one per compiled content type, keyed by its plural
  (`pages`/`posts`/… for the core, plus any project-registered types), and
  `entries`/`categories`/`tags` (media is an authoring concern, not a
  content-search result). Content hits carry their
  public `path` and an escape-safe `highlight` snippet (only `<mark>`
  survives); taxonomy hits carry `name`/`slug` (KilnCMS has no public
  taxonomy browse pages — headless frontends build their own listing URLs). A
  sparse content result set carries a `suggestion` ("did you mean") when the
  query is trigram-close to a published title without matching a word exactly
  — including alongside hits the fuzzy hybrid leg rescued from the typo.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.I18n
  alias KilnCMS.Search
  alias KilnCMS.Search.Highlight

  @max_limit 25
  @default_limit 10

  # "Did you mean" fires on sparse results, not only zero — the fuzzy hybrid
  # leg (same threshold) may have rescued a typo's hits, and the suggestion
  # then names the corrected term. Good exact-match queries stay clean:
  # `Search.suggest/2` never suggests when a title word equals the query.
  @suggest_below 3

  def index(conn, params) do
    query = params["q"] |> to_string() |> String.trim()
    locale = validated_locale(params["locale"])
    limit = clamped_limit(params["limit"])

    if query == "" do
      json(conn, %{query: query, locale: locale, results: empty_sections(), suggestion: nil})
    else
      search(conn, query, locale, limit, params)
    end
  end

  defp search(conn, query, locale, limit, params) do
    read_opts = [
      actor: conn.assigns[:current_user],
      authorize?: true,
      locale: locale,
      limit: limit
    ]

    sections =
      Search.global(query, read_opts ++ [highlight: true, filters: filters(params)])

    # One result section per compiled content type, straight from the same
    # registry `Search.global/2` swept — a project type registered on
    # `:content_domains` appears here with no controller edit.
    compiled =
      Map.new(ContentTypes.all(), fn ct ->
        {ct.section,
         Enum.map(Map.get(sections, ct.section, []), &item(&1, to_string(ct.type), ct, locale))}
      end)

    results =
      Map.merge(compiled, %{
        entries: Enum.flat_map(sections.entries, &entry_item(&1, locale)),
        categories: Enum.map(sections.categories, &taxonomy_item(&1, "category")),
        tags: Enum.map(sections.tags, &taxonomy_item(&1, "tag"))
      })

    # Content hits only — a taxonomy name match isn't a found document, so it
    # neither counts for analytics nor suppresses the "did you mean".
    total =
      results
      |> Map.drop([:categories, :tags])
      |> Map.values()
      |> Enum.map(&length/1)
      |> Enum.sum()

    Search.record_query(query, total, locale: locale)

    suggestion = if total < @suggest_below, do: Search.suggest(query, read_opts), else: nil

    payload = %{query: query, locale: locale, results: results, suggestion: suggestion}

    # `facets=true` adds category/tag counts over the (unfiltered) match set —
    # opt-in, since it's an extra scan the common lookup doesn't need.
    payload =
      if params["facets"] == "true",
        do: Map.put(payload, :facets, Search.facets(query, read_opts)),
        else: payload

    json(conn, payload)
  end

  # Facet filter params → `Search` filters. Only the category facet is
  # accepted from the public query string (by slug, resolved world-readably);
  # unknown slugs match nothing rather than silently dropping the filter.
  defp filters(params) do
    case params["category"] do
      slug when is_binary(slug) and slug != "" ->
        case KilnCMS.CMS.get_category_by_slug(slug, authorize?: true) do
          {:ok, category} -> %{category_id: category.id}
          _not_found -> %{category_id: Ecto.UUID.generate()}
        end

      _none ->
        %{}
    end
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

  defp taxonomy_item(record, type) do
    %{id: record.id, type: type, name: record.name, slug: record.slug}
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

  defp empty_sections do
    ContentTypes.all()
    |> Map.new(&{&1.section, []})
    |> Map.merge(%{entries: [], categories: [], tags: []})
  end

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
