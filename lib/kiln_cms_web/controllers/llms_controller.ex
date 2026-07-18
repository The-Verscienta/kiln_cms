defmodule KilnCMSWeb.LlmsController do
  @moduledoc """
  `/llms.txt` — a Markdown index of published content for large language models
  (the emerging [llmstxt.org](https://llmstxt.org) convention, the LLM analogue
  of `sitemap.xml`). Groups published records by content type with title, URL,
  and description, so answer engines can discover and cite the site's content
  accurately (GEO — Generative Engine Optimization, issue #357).

  Lists only **published, default-locale** records at their public URLs,
  discovered through `KilnCMS.CMS.ContentTypes` — the same authorization and
  type discovery as the sitemap, so drafts and gated content never appear.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Cache
  alias KilnCMS.CMS.ContentTypes

  # A hard ceiling so the per-request scan stays bounded regardless of how much
  # content exists. llms.txt is meant to be a digestible index, not exhaustive.
  @max_entries 10_000
  @cache_ttl :timer.minutes(5)

  def index(conn, _params) do
    # Per-org `llms.txt` (epic #336): each site indexes only its own content.
    org_id = KilnCMSWeb.Tenant.current_org_id(conn)

    body =
      Cache.fetch(Cache.llms_key(org_id), @cache_ttl, fn -> build_body(build_groups(org_id)) end)

    conn
    |> put_resp_content_type("text/markdown")
    |> send_resp(200, body)
  end

  # No actor + `authorize?: true` ⇒ the read policy returns published records
  # only. Dynamic types (D17) are included — same read policy. Non-default
  # locales are dropped so the index stays single-language and link-clean.
  defp build_groups(org_id) do
    default_locale = KilnCMS.I18n.default_locale()

    {groups, _count} =
      Enum.reduce_while(ContentTypes.all() ++ ContentTypes.dynamic_all(), {[], 0}, fn ct,
                                                                                      {acc, count} ->
        remaining = @max_entries - count

        if remaining <= 0 do
          {:halt, {acc, count}}
        else
          entries =
            ct
            |> ContentTypes.list!(
              authorize?: true,
              tenant: org_id,
              query: [select: [:title, :slug, :locale, :seo_description], limit: remaining]
            )
            |> Enum.filter(&(&1.locale == default_locale))
            |> Enum.map(&entry(&1, ContentTypes.public_prefix(ct)))

          {:cont, {[%{label: ct.plural, entries: entries} | acc], count + length(entries)}}
        end
      end)

    groups
    |> Enum.reverse()
    |> Enum.reject(&(&1.entries == []))
  end

  defp entry(record, prefix) do
    %{
      title: record.title,
      url: "#{base_url()}#{prefix}/#{record.slug}",
      description: record.seo_description
    }
  end

  defp build_body(groups) do
    header = """
    # #{site_name()}

    > Published content from #{site_name()}, indexed for language models (see https://llmstxt.org).
    """

    sections =
      Enum.map_join(groups, "\n", fn %{label: label, entries: entries} ->
        "## #{String.capitalize(label)}\n\n" <>
          Enum.map_join(entries, "\n", &render_entry/1) <> "\n"
      end)

    header <> "\n" <> sections
  end

  defp render_entry(%{title: title, url: url, description: desc})
       when is_binary(desc) and desc != "" do
    "- [#{md(title)}](#{url}): #{md(desc)}"
  end

  defp render_entry(%{title: title, url: url}), do: "- [#{md(title)}](#{url})"

  # Keep author-controlled text on one Markdown list line and unable to break out
  # of the link label.
  defp md(text) do
    text |> to_string() |> String.replace(["\r", "\n"], " ") |> String.replace("]", "\\]")
  end

  defp site_name, do: Application.get_env(:kiln_cms, :site_name, "KilnCMS")
  defp base_url, do: Application.get_env(:kiln_cms, :public_base_url, "http://localhost:4000")
end
