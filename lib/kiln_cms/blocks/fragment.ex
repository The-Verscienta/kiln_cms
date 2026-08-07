defmodule KilnCMS.Blocks.Fragment do
  @moduledoc """
  A **reusable content fragment**: define once, embed everywhere (#479).

  This is the Regular Labs / WP reusable-block / Contentful-reference idea —
  a shared banner, CTA or notice authored as one document and inlined into
  many. Edit the fragment, every page carrying it updates.

  ## It is inlined, not rendered

  The block itself renders nothing. `KilnCMS.CMS.Fragments.expand/3` replaces it
  with the target's own block tree **before** any surface renderer runs, at fire
  time and on the live delivery path alike. That is decision A3 ("resolve/embed
  at fire time") taken literally, and it is why one small module buys the whole
  feature: all four fired surfaces — `:web`, `:json`, `:llm`, `:json_ld` — see
  the expanded tree and need no knowledge of fragments at all.

  A `render/2` that fetched its target instead would have to exist once per
  surface and would put a DB read inside a pure serializer.

  Write-time derivations (the `search_text` column, `word_count`,
  `reading_time_minutes`) run over the *raw* tree, so a fragment's words are
  not in the host's search index and do not count towards its reading time. See
  `KilnCMS.CMS.Fragments` for why, and #910.

  ## The re-fire wave already existed

  `ref` is a DSL `:reference` field, which `KilnCMS.Firing.References` already
  extracts into a `ReferenceEdge` — so publishing a fragment re-fires every
  document that embeds it, with no new machinery. Expansion deliberately runs
  *after* the edge rebuild reads the raw tree: expand first and the edge would
  vanish, silently breaking the wave the feature depends on.

  ## Failing closed

  A target that is missing, unpublished, in another org, or gated to an audience
  the reader doesn't hold expands to **nothing**. A fragment is a pointer, and a
  pointer to something the caller may not see has no safe rendering — showing a
  placeholder would leak its existence.
  """
  use Kiln.Block

  block :fragment do
    # `ref` is `%{"type" => "page", "id" => "<uuid>"}` — the same reference
    # shape `Redirect` and `ContentLink` speak, and what `Firing.References`
    # already extracts into a `ReferenceEdge`.
    field :ref, :reference, required: true

    # Editor-facing only: a label so the collapsed block in the editor says
    # which fragment it points at, instead of a bare uuid. Never rendered —
    # expansion replaces the block entirely — and never trusted: the target's
    # own title is what any surface would show.
    field :label, :string
  end

  @impl Kiln.Block.Renderer
  # Nothing renders. An unexpanded fragment reaching a serializer means its
  # target wasn't visible (or expansion was skipped), and the fail-closed answer
  # is empty. Deliberately not an error — a page whose fragment points at a
  # still-unpublished target should render the rest of itself.
  #
  # `:json` gets a content-free map rather than `nil` for two reasons: the
  # surface's contract is that every block serializes to a map (a `nil` would
  # land in the artifact's `blocks` array), and emitting the *reference* would
  # publish the id of a document the caller was just refused.
  def render(_block, :json), do: %{"_type" => "fragment"}
  def render(_block, _surface), do: []

  @impl Kiln.Block.Renderer
  def search_text(_block), do: ""
end
