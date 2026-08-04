defmodule KilnCMS.Firing.SchemaOrg do
  @moduledoc """
  The document-level schema.org node of the fired `:json_ld` surface (#357,
  GEO — expanded structured data).

  Every content type declares the schema.org `@type` of its main node: compiled
  types via the Content macro's `schema_org_type:` option, dynamic types (D17)
  via `TypeDefinition.schema_org_type` — so a health-domain type can fire e.g.
  a **`MedicalWebPage`** while a blog post stays a `BlogPosting`. The node also
  carries the citation-relevant document metadata answer engines key on:
  `datePublished` / `dateModified`, `inLanguage`, and the SEO description.
  """

  # Page-level types the main node may declare. Article-family types carry the
  # body as `articleBody`; the rest (WebPage family) as the generic `text`.
  @article_types ~w(Article BlogPosting NewsArticle TechArticle)
  @page_types ~w(WebPage AboutPage ContactPage FAQPage MedicalWebPage)

  # A third family (#480). An `Event` is not a `CreativeWork`: it has no body in
  # the schema.org sense, so it carries neither `articleBody` nor `text`, and it
  # gains `startDate`/`endDate`/`eventSchedule` from a `datetime_range` field
  # instead. Declaring one on a type with no schedule is allowed and simply
  # produces an Event with no dates — the type is what an operator says it is.
  @event_types ~w(Event BusinessEvent CourseInstance EducationEvent ExhibitionEvent
                  Festival MusicEvent ScreeningEvent SocialEvent SportsEvent TheaterEvent)

  @doc "Allowlist of supported page-level schema.org types."
  @spec types() :: [String.t()]
  def types, do: @article_types ++ @page_types ++ @event_types

  @doc "Whether `type` is one of the schema.org Event family."
  @spec event_type?(String.t()) :: boolean()
  def event_type?(type), do: type in @event_types

  @doc "The default main-node @type."
  @spec default_type() :: String.t()
  def default_type, do: "Article"

  @doc """
  The declared schema.org @type for a document: its type definition's (dynamic
  types), else its module's `__kiln_schema_org_type__/0` (compiled types), else
  `Article`. Unknown/stale declarations fall back to the default rather than
  firing an unvetted @type.
  """
  @spec resolve(struct()) :: String.t()
  def resolve(%{type_definition_id: id}) when not is_nil(id) do
    case KilnCMS.CMS.get_type_definition(id, authorize?: false) do
      {:ok, %{schema_org_type: type}} -> normalize(type)
      _ -> default_type()
    end
  end

  def resolve(%module{}) do
    if function_exported?(module, :__kiln_schema_org_type__, 0) do
      normalize(module.__kiln_schema_org_type__())
    else
      default_type()
    end
  end

  @doc """
  The document's main `@graph` node: the declared @type, headline, body (as
  `articleBody` or `text` per the type family), and document metadata.
  """
  @spec main_node(struct(), String.t()) :: map()
  def main_node(document, body) do
    type = resolve(document)

    type
    |> base_node(document, body)
    |> put_if("description", Map.get(document, :seo_description))
    |> put_if("keywords", Map.get(document, :seo_keywords))
    |> put_if("inLanguage", Map.get(document, :locale))
    |> put_if("datePublished", iso(Map.get(document, :published_at)))
    |> put_if("dateModified", iso(Map.get(document, :updated_at)))
  end

  # An Event's headline is its `name`, and it has no body — `articleBody` on an
  # Event is not a property schema.org defines, and emitting it makes the node
  # invalid rather than merely verbose.
  defp base_node(type, document, _body) when type in @event_types,
    do: %{"@type" => type, "name" => Map.get(document, :title)}

  defp base_node(type, document, body) do
    body_key = if type in @article_types, do: "articleBody", else: "text"
    %{"@type" => type, "headline" => Map.get(document, :title), body_key => body}
  end

  defp normalize(type)
       when type in @article_types or type in @page_types or type in @event_types,
       do: type

  defp normalize(_type), do: default_type()

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(_), do: nil

  defp put_if(map, _key, nil), do: map
  defp put_if(map, _key, ""), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
