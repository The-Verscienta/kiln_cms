defmodule KilnCMSWeb.StructuredData do
  @moduledoc """
  Builds schema.org JSON-LD for published content, embedded in the page head by
  `ContentController` for richer search/social results.

  Posts map to `BlogPosting`, every other content type to `WebPage`. The map is
  serialized with `Jason.encode!(escape: :html_safe)` at the call site so it is
  safe to inline in a `<script type="application/ld+json">` block.
  """
  alias KilnCMS.CMS.ContentTypes

  @doc """
  Returns the schema.org map for `record` (a published content struct) given its
  `ContentTypes` entry `ct`. Empty/nil fields are omitted.
  """
  @spec build(struct(), ContentTypes.t()) :: map()
  def build(record, ct) do
    url = url(record, ct)

    %{
      "@context" => "https://schema.org",
      "@type" => schema_type(ct),
      title_key(ct) => record.title,
      "url" => url,
      "mainEntityOfPage" => url,
      "publisher" => %{"@type" => "Organization", "name" => site_name()}
    }
    |> maybe_put("description", record.seo_description)
    |> maybe_put("image", record.seo_image)
    |> maybe_put("datePublished", iso8601(record.published_at))
    |> maybe_put("dateModified", iso8601(record.updated_at))
  end

  defp schema_type(%{type: :post}), do: "BlogPosting"
  defp schema_type(_ct), do: "WebPage"

  # BlogPosting uses `headline`; WebPage uses `name`.
  defp title_key(%{type: :post}), do: "headline"
  defp title_key(_ct), do: "name"

  # Prefer an editor-set canonical URL; otherwise build the public URL the same
  # way the sitemap does (base + the type's path prefix + slug).
  defp url(%{canonical_url: canonical}, _ct) when is_binary(canonical) and canonical != "",
    do: canonical

  defp url(record, ct), do: "#{base_url()}#{ContentTypes.public_prefix(ct)}/#{record.slug}"

  defp site_name, do: Application.get_env(:kiln_cms, :site_name, "KilnCMS")
  defp base_url, do: Application.get_env(:kiln_cms, :public_base_url, "http://localhost:4000")

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
