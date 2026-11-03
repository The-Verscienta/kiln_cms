defmodule KilnCMS.CMS.ContentSearch do
  @moduledoc """
  Hybrid search over every content type as one Ash action, for the `/mcp`
  `search_content` tool — the surface `KilnCMS.Search.global/2` had nowhere
  else to be called from. `read_pages`/`read_posts` filter by field; an
  LLM authoring client looking for "the page about reishi" needs ranking,
  the site's synonyms (`KilnCMS.CMS.SearchSynonym`) and the title and alias
  legs, which only the hybrid search has.

  No data layer: the action runs `Search.global/2` as the caller, so every
  content read policy applies to what it finds — an editor's key finds drafts
  the way `read_pages` shows them, a viewer's finds published content only.
  The policy here admits the call itself; it never widens what comes back.

  Answers the content hits of every section merged into one list by the
  score each was ranked by (scores are comparable across sections — see
  `Search.hit_score/1`), and the alternate wordings the site's synonyms added
  (`also_searched`), as `/api/search` reports them.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    authorizers: [Ash.Policy.Authorizer]

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Search
  alias KilnCMS.Search.Synonyms

  @max_limit 25

  actions do
    action :search, :map do
      description "Hybrid search across every content type, ranked, with the site's synonyms applied."

      argument :query, :string do
        allow_nil? false
        description "What to search for."
        constraints max_length: 500
      end

      argument :limit, :integer do
        default 10
        description "How many hits to return (1–#{@max_limit})."
        constraints min: 1, max: @max_limit
      end

      argument :locale, :string do
        description "The locale to search (default: the site's default locale)."
      end

      run fn input, context ->
        {:ok, search(input.arguments, context)}
      end
    end
  end

  policies do
    # The call is open to any caller of the action; what it finds is the
    # content read policies' answer for that caller (see the moduledoc).
    policy action(:search) do
      authorize_if always()
    end
  end

  defp search(%{query: query, limit: limit} = args, context) do
    query = String.trim(query)
    tenant = context.tenant
    also_searched = Synonyms.alternates(query, tenant)

    sections =
      Search.global(query,
        actor: context.actor,
        authorize?: true,
        tenant: tenant,
        locale: args[:locale],
        limit: limit,
        synonyms: also_searched,
        select: [:id, :title, :slug, :locale, :org_id],
        sections: Search.content_sections()
      )

    compiled =
      Enum.flat_map(ContentTypes.all(), fn ct ->
        sections |> Map.get(ct.section, []) |> Enum.map(&hit(&1, to_string(ct.type)))
      end)

    entries = sections |> Map.get(:entries, []) |> Enum.map(&hit(&1, &1.type_name))

    results =
      (compiled ++ entries)
      |> Enum.sort_by(&(-(&1.score || 0.0)))
      |> Enum.take(limit)

    %{query: query, also_searched: also_searched, results: results}
  end

  defp hit(record, type) do
    %{
      type: type,
      id: record.id,
      title: record.title,
      slug: record.slug,
      locale: record.locale,
      score: Search.hit_score(record),
      legs: Search.hit_legs(record)
    }
  end
end
