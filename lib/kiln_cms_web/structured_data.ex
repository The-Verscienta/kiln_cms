defmodule KilnCMSWeb.StructuredData do
  @moduledoc """
  Builds schema.org JSON-LD for published content, embedded in the page head by
  `ContentController` for richer search/social results.

  The `@type` is resolved through `KilnCMS.Firing.SchemaOrg.resolve/1` — the
  same authority the fired `:json_ld` artifact uses (#357, #480) — so a type's
  declared `schema_org_type` (e.g. `MedicalWebPage`, `MusicEvent`) reaches the
  markup crawlers actually read, not just the headless one. A content page
  emits the main entity plus a `BreadcrumbList`; the blog index emits a
  `CollectionPage`. The result is serialized with
  `Jason.encode!(escape: :html_safe)` at the call site so it is safe to inline in
  a `<script type="application/ld+json">` block.
  """
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Firing.SchemaOrg

  @doc """
  The JSON-LD for a content page: the main entity (`BlogPosting`/`WebPage`) plus
  a `BreadcrumbList`, as a list of schema.org objects.
  """
  @spec document(struct(), ContentTypes.t(), term()) :: [map()]
  def document(record, ct, org \\ nil) do
    # Reuse the main node's already-computed url for the trail's last crumb
    # instead of having breadcrumbs/4 re-derive it via a second `url/3` call.
    built = build(record, ct, org)
    [built, breadcrumbs(record, ct, org, built["url"])]
  end

  @doc """
  Returns the schema.org map for `record` (a published content struct) given its
  `ContentTypes` entry `ct`. Empty/nil fields are omitted.
  """
  @spec build(struct(), ContentTypes.t(), term()) :: map()
  def build(record, ct, org \\ nil) do
    url = url(record, ct, org)
    type = SchemaOrg.resolve(record)

    %{
      "@context" => "https://schema.org",
      "@type" => type,
      title_key(type) => record.title,
      "url" => url,
      "mainEntityOfPage" => url,
      # The `publisher` is the SITE, which is per-org under white-labelling
      # (#48). `org` is nil in tenant-less callers, which resolves to the
      # instance-wide default — the previous behaviour.
      "publisher" => %{"@type" => "Organization", "name" => site_name(org)}
    }
    |> maybe_put("description", record.seo_description)
    |> maybe_put("image", record.seo_image)
    |> maybe_put("author", author(record))
    |> maybe_creative_work_fields(type, record)
    |> maybe_event_schedule(type, record)
    |> maybe_paywalled(record)
  end

  # `keywords`/`datePublished`/`dateModified` are CreativeWork properties (the
  # article/page families); an Event is not a CreativeWork, and emitting them
  # on one produces a node with properties schema.org doesn't define for it —
  # mirrors `Firing.SchemaOrg.base_node/3`, the fired producer's own rule.
  defp maybe_creative_work_fields(node, type, record) do
    if SchemaOrg.event_type?(type) do
      node
    else
      node
      |> maybe_put("keywords", record.seo_keywords)
      |> maybe_put("datePublished", iso8601(record.published_at))
      |> maybe_put("dateModified", iso8601(record.updated_at))
    end
  end

  # `startDate`/`endDate`/`eventSchedule` from the type's `datetime_range`
  # field (#480), same as the fired `:json_ld` artifact — so the markup a
  # crawler reads on the served page carries the same event dates as the
  # headless one.
  defp maybe_event_schedule(node, type, record) do
    if SchemaOrg.event_type?(type) do
      Map.merge(node, KilnCMS.Events.schema_org_schedule(record))
    else
      node
    end
  end

  # A gated document is marked paywalled even when the reader IS entitled, so the
  # markup a subscriber receives matches what a crawler is told (#337 Phase 2).
  defp maybe_paywalled(node, %{audience: audience}) when audience != :public,
    do: Map.merge(node, paywall_markers())

  defp maybe_paywalled(node, _record), do: node

  @doc """
  The JSON-LD for a paywalled document (#337 Phase 2).

  Emits `isAccessibleForFree: false` plus a `hasPart` marking the gated region, so
  a crawler is told the page is paywalled rather than being handed a short article
  it might read as thin content.

  The **same** flags are emitted on the entitled member's full render (see
  `document/3`), because a crawler and a subscriber disagreeing about whether a
  page is free is exactly the cloaking signal search engines penalise — which is
  also why `@type` and the Event dates below must agree with `build/3` rather
  than default to `WebPage`: an operator's declared `MusicEvent` (and its dates)
  is not itself gated content, so hiding it from the reader who can't yet read
  the body is the same disagreement `paywall_markers/0` exists to avoid.

  `teaser.type` and `teaser.event_schedule` are resolved from the gated
  record at projection time (`KilnCMSWeb.Teaser.from_record/3`, #1136) — this
  renderer never sees the record itself, only what the struct already
  summarises, plus the type declaration and the event's own dates, both public
  admin configuration rather than gated content.
  """
  @spec teaser(KilnCMSWeb.Teaser.t(), term()) :: [map()]
  def teaser(teaser, org \\ nil) do
    type = teaser.type || "WebPage"

    node =
      %{
        "@context" => "https://schema.org",
        "@type" => type,
        title_key(type) => teaser.title,
        "url" => teaser.url,
        "mainEntityOfPage" => teaser.url,
        "publisher" => %{"@type" => "Organization", "name" => site_name(org)}
      }
      |> maybe_put("description", teaser.summary || teaser.seo_description)
      |> maybe_put("image", teaser.seo_image)
      |> maybe_teaser_dates(type, teaser)
      |> maybe_teaser_event_schedule(type, teaser)
      |> Map.merge(paywall_markers())

    [node]
  end

  defp maybe_teaser_dates(node, type, teaser) do
    if SchemaOrg.event_type?(type) do
      node
    else
      node
      |> maybe_put("datePublished", iso8601(teaser.published_at))
      |> maybe_put("dateModified", iso8601(teaser.updated_at))
    end
  end

  defp maybe_teaser_event_schedule(node, type, teaser) do
    if SchemaOrg.event_type?(type) do
      Map.merge(node, teaser.event_schedule)
    else
      node
    end
  end

  @doc """
  The schema.org flags marking a document as paywalled.

  Merged into both the teaser node and the entitled render's node — see
  `teaser/2` for why they must agree.
  """
  @spec paywall_markers() :: map()
  def paywall_markers do
    %{
      "isAccessibleForFree" => false,
      "hasPart" => %{
        "@type" => "WebPageElement",
        "isAccessibleForFree" => false,
        "cssSelector" => ".kiln-paywalled"
      }
    }
  end

  @doc "schema.org `CollectionPage` (+ `ItemList`) for the blog index `posts`."
  @spec blog([struct()], term()) :: map()
  def blog(posts, org \\ nil) do
    base_url = KilnCMSWeb.Tenant.base_url(org)
    blog_url = "#{base_url}/blog"

    %{
      "@context" => "https://schema.org",
      "@type" => "CollectionPage",
      "name" => "Blog",
      "url" => blog_url,
      "mainEntity" => %{
        "@type" => "ItemList",
        "itemListElement" => list_items(posts, &"#{base_url}#{locale_prefix(&1)}/blog/#{&1.slug}")
      }
    }
  end

  # Author Person, only when the (loaded) author has a display name.
  defp author(%{author: %{name: name}}) when is_binary(name) and name != "",
    do: %{"@type" => "Person", "name" => name}

  defp author(_record), do: nil

  # Home › [Blog ›] Title — search-engine breadcrumb trail, not localized UI.
  defp breadcrumbs(record, ct, org, record_url) do
    base_url = KilnCMSWeb.Tenant.base_url(org)

    crumbs =
      [{"Home", base_url}] ++
        if(ct.type == :post, do: [{"Blog", "#{base_url}/blog"}], else: []) ++
        [{record.title, record_url}]

    %{
      "@context" => "https://schema.org",
      "@type" => "BreadcrumbList",
      "itemListElement" =>
        crumbs
        |> Enum.with_index(1)
        |> Enum.map(fn {{name, url}, position} ->
          %{"@type" => "ListItem", "position" => position, "name" => name, "item" => url}
        end)
    }
  end

  defp list_items(records, url_fun) do
    records
    |> Enum.with_index(1)
    |> Enum.map(fn {record, position} ->
      %{
        "@type" => "ListItem",
        "position" => position,
        "name" => record.title,
        "url" => url_fun.(record)
      }
    end)
  end

  # Article-family types (BlogPosting/Article/NewsArticle/TechArticle) use
  # `headline`; every other family (WebPage, Event, ...) uses `name`.
  defp title_key(type) do
    if SchemaOrg.article_type?(type), do: "headline", else: "name"
  end

  # Prefer an editor-set canonical URL; otherwise build the public URL the same
  # way the sitemap does (base + the type's path prefix + slug).
  defp url(%{canonical_url: canonical}, _ct, _org) when is_binary(canonical) and canonical != "",
    do: canonical

  # A path alias (#485) is the record's canonical path when set.
  defp url(%{path_alias: alias_path} = record, _ct, org) when is_binary(alias_path),
    do: "#{KilnCMSWeb.Tenant.base_url(org)}#{locale_prefix(record)}#{alias_path}"

  defp url(record, ct, org),
    do:
      "#{KilnCMSWeb.Tenant.base_url(org)}#{locale_prefix(record)}#{ContentTypes.public_prefix(ct)}/#{record.slug}"

  # Locale-prefix non-default-locale URLs so JSON-LD matches the locale-prefixed
  # delivery paths (#164). Records carry their own `locale`.
  defp locale_prefix(%{locale: locale}) when is_binary(locale) do
    if locale == KilnCMS.I18n.default_locale(), do: "", else: "/#{locale}"
  end

  defp locale_prefix(_), do: ""

  defp site_name(org), do: KilnCMS.Branding.for_org(org).site_name

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
