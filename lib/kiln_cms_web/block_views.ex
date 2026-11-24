defmodule KilnCMSWeb.BlockViews do
  @moduledoc """
  A document's block tree as the view maps `KilnCMSWeb.BlockComponents`
  renders, with its fragments inlined (#479, #2767).

  `BlockComponents.view_blocks/1` cannot expand a fragment: it has no org or
  audience to resolve one with, and it stays free of database reads. This
  module is the one place every surface that renders a whole document does it:
  public delivery, the pop-out, token and release previews, the editor's
  pop-out broadcast, the presentation editor's broadcast and the in-context
  editor's read-only blocks. A surface that skips it shows a fragment as
  nothing, which is the bug #2767 found on three of them.
  """

  alias KilnCMS.CMS.Fragments
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.Firing.Engine
  alias KilnCMSWeb.BlockComponents

  @doc """
  `blocks` (anything `TypedBlocks.to_typed/1` takes) as view maps, with every
  fragment inlined the way `KilnCMS.Firing.Engine` inlines it for the fired
  artifact, rendered in `record`'s locale.

  `record` is the host document: its `org_id`, `id`, `locale`, `audience` and
  type. `blocks` is passed separately because a caller may render an unsaved
  or patched tree (the editor's form, an experiment variant) for it.

  ## Options

    * `:audiences` — the gated tiers a fragment target may carry. Defaults to
      the host's own (`Engine.host_audiences/1`), the rule the artifact and
      the editor's Preview tab follow, so no preview shows text the published
      page will not have. Public delivery passes the reader's instead.
    * `:org_id` — the org fragments resolve in. Defaults to `record.org_id`.

  The host's type and audiences are only worked out when the tree holds a
  fragment: for a dynamic-type document the type is a database read, and the
  common tree has no fragment at all.
  """
  @spec document_view_blocks([term()] | nil, map(), keyword()) :: [map()]
  def document_view_blocks(blocks, record, opts \\ []) do
    KilnCMS.CodeBlocks.with_content_locale(Map.get(record, :locale), fn ->
      blocks
      |> TypedBlocks.to_typed()
      |> expand(record, opts)
      |> BlockComponents.view_blocks()
    end)
  end

  defp expand(typed, record, opts) do
    if Fragments.any_fragment?(typed) do
      Fragments.expand(typed, Keyword.get(opts, :org_id, record.org_id),
        audiences: Keyword.get_lazy(opts, :audiences, fn -> Engine.host_audiences(record) end),
        # Seeded with the host itself, so a page embedding *itself* does not
        # inline its own body once before the cycle guard catches it a level
        # down.
        ancestry: [{Engine.public_type(record), record.id}]
      )
    else
      typed
    end
  end
end
