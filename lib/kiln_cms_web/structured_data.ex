defmodule KilnCMSWeb.StructuredData do
  @moduledoc """
  Builds schema.org JSON-LD for published content, embedded in the page head by
  `ContentController` for richer search/social results.

  Posts map to `BlogPosting`, every other content type to `WebPage`. A content
  page emits the main entity plus a `BreadcrumbList`; the blog index emits a
  `CollectionPage`. The result is serialized with
  `Jason.encode!(escape: :html_safe)` at the call site so it is safe to inline in
  a `<script type="application/ld+json">` block.
  """
  alias KilnCMS.CMS.ContentTypes

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

    %{
      "@context" => "https://schema.org",
      "@type" => schema_type(ct),
      title_key(ct) => record.title,
      "url" => url,
      "mainEntityOfPage" => url,
      # The `publisher` is the SITE, which is per-org under white-labelling
      # (#48). `org` is nil in tenant-less callers, which resolves to the
      # instance-wide default — the previous behaviour.
      "publisher" => %{"@type" => "Organization", "name" => site_name(org)}
    }
    |> maybe_put("description", record.seo_description)
    |> maybe_put("keywords", record.seo_keywords)
    |> maybe_put("image", record.seo_image)
    |> maybe_put("datePublished", iso8601(record.published_at))
    |> maybe_put("dateModified", iso8601(record.updated_at))
    |> maybe_put("author", author(record))
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

  defp schema_type(%{type: :post}), do: "BlogPosting"
  defp schema_type(_ct), do: "WebPage"

  # BlogPosting uses `headline`; WebPage uses `name`.
  defp title_key(%{type: :post}), do: "headline"
  defp title_key(_ct), do: "name"

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
