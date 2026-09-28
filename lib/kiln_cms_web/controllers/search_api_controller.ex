defmodule KilnCMSWeb.SearchApiController do
  @moduledoc """
  Headless **hybrid search** (`GET /api/search?q=…`) — the query surface the
  search roadmap (#4) left open: keyword + semantic + title legs fused by RRF
  (and reranked when enabled), which no single Ash action can express, so it
  ships as a thin controller over `KilnCMS.Search.global/2`.

  **Actorless, deliberately** (#1013). This is a delivery surface, and it used
  to pass `conn.assigns[:current_user]` so "a bearer token widens visibility
  like every other headless surface". That is a trap here rather than a
  feature: a key authorizes as the account that minted it, the `OrgAdmin`
  policy bypass authorizes that account past the audience grant *and* the
  passphrase check, and this endpoint returns a `highlight` snippet built from
  `search_text` — so an admin-minted delivery key got a `<mark>`-ed extract of
  every member-only and passphrase-locked document's body. Editors searching
  their own drafts have the JSON:API base routes for that
  (`/api/json/<plural>/search`); this one answers as an anonymous visitor, the
  way the rendered site's search (`ContentController.search/2`) and `/api/ask`
  already do.

  Search, not indexing: `read :published` keeps returning gated rows on purpose,
  because the blog index badges them rather than hiding them. Search is where
  the body text is, which is why the two differ. Sections mirror
  `global/2` — one per compiled content type, keyed by its plural
  (`pages`/`posts`/… for the core, plus any project-registered types), and
  `entries` plus one per taxonomy resource — `categories`/`tags`/`tag_groups`
  (media is an authoring concern, not a content-search result). Content hits carry their
  public `path`, an escape-safe `highlight` snippet (only `<mark>`
  survives), the fused `score` they were ranked by (comparable across
  sections) and the `legs` that matched (`keyword`/`keyword_any`/`semantic`/
  `block`/`title`/`alias`/`fuzzy`/`tag` — `block` is the embedding leg at
  block grain, a record reached through its nearest section; `title` is a
  record the query names outright, `alias` one it names by a custom field
  flagged as a name, `tag` one carrying a tag whose name the query is near,
  and
  `keyword_any` the any-term relaxation that joins when the every-term match
  comes up short on a multi-word query, so a hit carrying only it matched
  some of the words, not all; see `KilnCMS.Search.hit_legs/1`);
  taxonomy hits carry `name`/`slug` (KilnCMS has no public
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
  alias KilnCMSWeb.ApiError
  alias KilnCMSWeb.Params

  @max_limit 25
  @default_limit 10

  # "Did you mean" fires on sparse results, not only zero — the fuzzy hybrid
  # leg (same threshold) may have rescued a typo's hits, and the suggestion
  # then names the corrected term. Good exact-match queries stay clean:
  # `Search.suggest/2` never suggests when a title word equals the query.
  @suggest_below 3

  # Seconds a client is asked to wait after a `503` from a saturated pool. A
  # search's hold on a connection is tens of milliseconds, so the pool turns
  # over many times a second; one second is enough to be past the burst that
  # filled it, without a client giving up on a search it could have had.
  @retry_after "1"

  def index(conn, params) do
    query = params |> Params.string("q", "") |> String.trim()
    locale = validated_locale(Params.string(params, "locale"))
    limit = Params.integer(params, "limit", @default_limit, 1..@max_limit)

    if query == "" do
      json(conn, %{query: query, locale: locale, results: empty_sections(), suggestion: nil})
    else
      search(conn, query, locale, limit, params)
    end
  end

  # One pooled connection for the whole request (`Search.with_connection/1`):
  # the category lookup, the sweep, the "did you mean" and the facet counts
  # all run on it in turn, so a search costs the pool one connection and
  # waits for it once. That wait is where a saturated pool is felt, and it
  # answers `503` + `Retry-After` — a search a client can retry — rather than
  # the `500` a dropped checkout used to raise from somewhere inside the
  # sweep (#1712). The analytics write happens after the connection is
  # handed back, off the request (`Search.record_query_async/3`).
  defp search(conn, query, locale, limit, params) do
    org_id = KilnCMSWeb.Tenant.current_org_id(conn)

    case Search.with_connection(fn -> {:ok, run(query, locale, limit, params, org_id)} end) do
      {:ok, {payload, total}} ->
        Search.record_query_async(query, total, locale: locale, tenant: org_id)
        json(conn, payload)

      {:error, :unavailable} ->
        conn
        |> put_resp_header("retry-after", @retry_after)
        |> ApiError.send(
          :service_unavailable,
          "temporarily_unavailable",
          "Search is temporarily unavailable; retry shortly."
        )
    end
  end

  defp run(query, locale, limit, params, org_id) do
    read_opts = [
      # No `actor:` — see the moduledoc. `authorize?: true` with no actor is
      # what pins this to the anonymous read policy, and `read_opts` is handed
      # verbatim to `Search.facets/2` and `Search.suggest/2` below, so the same
      # rule covers the facet counts and the "did you mean" title.
      authorize?: true,
      # Scope search to the request's org (#336); resolved from the host by the
      # SetTenant plug. Content sections are isolated per site.
      tenant: org_id,
      locale: locale,
      limit: limit
    ]

    sections =
      Search.global(
        query,
        read_opts ++ [highlight: true, filters: filters(params, org_id)]
      )

    # One result section per compiled content type, straight from the same
    # registry `Search.global/2` swept — a project type registered on
    # `:content_domains` appears here with no controller edit.
    compiled =
      Map.new(ContentTypes.all(), fn ct ->
        {ct.section,
         Enum.map(Map.get(sections, ct.section, []), &item(&1, to_string(ct.type), ct, locale))}
      end)

    # One section per taxonomy resource, from the same registry `global/2`
    # swept — the hard-coded pair here is how tag groups came to be missing from
    # this surface while `global/2` was already returning them (#530).
    taxonomy =
      Map.new(KilnCMS.CMS.Taxonomy.searchable(), fn {section, resource} ->
        type = resource |> Module.split() |> List.last() |> Macro.underscore()
        {section, Enum.map(Map.get(sections, section, []), &taxonomy_item(&1, type))}
      end)

    results =
      compiled
      |> Map.merge(taxonomy)
      |> Map.put(:entries, Enum.flat_map(sections.entries, &entry_item(&1, locale)))

    # Content hits only — a taxonomy name match isn't a found document, so it
    # neither counts for analytics nor suppresses the "did you mean". Keyed off
    # the registry for the same reason the sections are.
    total =
      results
      |> Map.drop(Map.keys(taxonomy))
      |> Map.values()
      |> Enum.map(&length/1)
      |> Enum.sum()

    suggestion = if total < @suggest_below, do: Search.suggest(query, read_opts), else: nil

    payload = %{query: query, locale: locale, results: results, suggestion: suggestion}

    # `facets=true` adds category/tag counts over the (unfiltered) match set —
    # opt-in, since it's an extra scan the common lookup doesn't need.
    payload =
      if params["facets"] == "true",
        do: Map.put(payload, :facets, Search.facets(query, read_opts)),
        else: payload

    {payload, total}
  end

  # Facet filter params → `Search` filters. Only the category facet is
  # accepted from the public query string (by slug, resolved world-readably);
  # unknown slugs match nothing rather than silently dropping the filter.
  defp filters(params, org_id) do
    case params["category"] do
      slug when is_binary(slug) and slug != "" ->
        case KilnCMS.CMS.get_category_by_slug(slug, authorize?: true, tenant: org_id) do
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
      highlight: highlight(record),
      # Additive: the score the hit was ranked by and the legs that returned
      # it (`KilnCMS.Search.hit_score/1`, `hit_legs/1`). Until these existed a
      # client's only relevance signal was whether a `<mark>` appeared in the
      # highlight — nothing to threshold on, debug with, or build an
      # evaluation set from.
      score: Search.hit_score(record),
      legs: Search.hit_legs(record)
    }
  end

  # A dynamic hit resolves its type through the per-org registry (#336) for
  # URL + label; hits whose type no longer resolves (archived mid-flight) are
  # dropped.
  defp entry_item(record, locale) do
    case ContentTypes.get_dynamic(record.type_name, record.org_id) do
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
    taxonomy = Map.new(KilnCMS.CMS.Taxonomy.searchable(), &{elem(&1, 0), []})

    ContentTypes.all()
    |> Map.new(&{&1.section, []})
    |> Map.merge(taxonomy)
    |> Map.put(:entries, [])
  end

  defp validated_locale(locale) do
    if locale in I18n.locales(), do: locale, else: I18n.default_locale()
  end
end
