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

  alias KilnCMS.Seo.Patterns

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

  `opts` may carry `:type` (the content type descriptor) and `:org`, which the
  caller has already resolved; they only decide the #805 pattern defaults below,
  and are looked up from the record when absent.
  """
  @spec from_record(struct(), String.t(), keyword()) :: t()
  def from_record(record, url, opts \\ []) do
    %__MODULE__{
      title: record.title,
      # `Map.get/2`: `excerpt` only exists on types that opted into it.
      #
      # The STORED description, never the type's #805 default. `summary` is the
      # paragraph a locked-out reader READS (`teaser.html.heex`,
      # `lock.html.heex`), not a meta tag, and a type patterned
      # `"[title] — subscribe to read"` must not show that string as if it were
      # the article's own lede.
      summary: blank_to_nil(Map.get(record, :excerpt)) || blank_to_nil(record.seo_description),
      audience: record.audience,
      url: url,
      published_at: Map.get(record, :published_at),
      # The meta tags get the opposite rule — the type's default where the
      # record has none, exactly as the member render resolves it (#805).
      #
      # Resolved from the record here rather than applied to this struct
      # afterwards (#1102), so that the slug route and the `path_alias` route —
      # which reach this through two different reads — cannot answer differently
      # for one document.
      #
      # `[category]` and `[field:<name>]` still expand empty on a teaser: both
      # need columns the paywall-safe select deliberately omits, and loading the
      # `effective_seo_*` calculations here would widen that select for every
      # consumer of the record, not just this one. `docs/seo.md` says so, and
      # the separator elision makes it a shorter tag rather than a broken one.
      seo_title: Patterns.effective(record, :seo_title, opts),
      seo_description: Patterns.effective(record, :seo_description, opts),
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
