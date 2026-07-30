defmodule KilnCMSWeb.Teaser do
  @moduledoc """
  The paywall-safe projection of a gated document.

  A hand-written struct with **no `blocks` field**, deliberately. The
  `:teaser_by_slug` read already omits the block tree from its `select`, but a
  projection is not an authorization primitive: if someone later widened that
  select, the template would happily render whatever arrived — and
  `KilnCMSWeb.ContentHTML` aliases `BlockComponents` module-wide, so template
  scope protects nothing.

  Converting to this struct before assigning makes the teaser template unable to
  render a block even if one were fetched. The regression test is a single line —
  `refute :blocks in Map.keys(%KilnCMSWeb.Teaser{})` — and it cannot be satisfied
  by accident.

  ## The summary chain is deliberately thin

  `summary` is `excerpt || seo_description` and nothing more. In particular it is
  never synthesised from the first block, because that would require selecting
  `blocks` and destroy the guarantee above.

  `excerpt` is opt-in per content type — present on posts and entries, **absent
  on pages** — so a gated page teases on its title and SEO description alone. And
  the meta tags mirror delivery's real (thin) chain: delivery reads `seo_image`
  and `seo_description` directly with no featured-image fallback, so the teaser
  must not invent a richer one, or the teaser and the member render would disagree
  about their own metadata.
  """

  @enforce_keys [:title, :audience, :url]
  defstruct [
    :title,
    :summary,
    :audience,
    :url,
    :published_at,
    :seo_title,
    :seo_description,
    :seo_image,
    :canonical_url,
    :path_alias,
    :locale,
    :org_id,
    :updated_at
  ]

  @type t :: %__MODULE__{}

  @doc """
  Project a gated record onto the paywall-safe struct.

  `url` is the document's own canonical path — a paywall must not canonicalise to
  the join page, or search engines would index the wrong URL.
  """
  @spec from_record(struct(), String.t()) :: t()
  def from_record(record, url) do
    %__MODULE__{
      title: record.title,
      # `Map.get/2`: `excerpt` only exists on types that opted into it.
      summary: blank_to_nil(Map.get(record, :excerpt)) || blank_to_nil(record.seo_description),
      audience: record.audience,
      url: url,
      published_at: Map.get(record, :published_at),
      seo_title: record.seo_title,
      seo_description: record.seo_description,
      seo_image: record.seo_image,
      canonical_url: record.canonical_url,
      path_alias: record.path_alias,
      locale: record.locale,
      org_id: record.org_id,
      updated_at: record.updated_at
    }
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end
