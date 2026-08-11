defmodule KilnCMS.Links.Extract do
  @moduledoc """
  Every outbound URL in a document, and which block it is in (#474).

  The input side of the external link sweep. `Kiln.Advisory.Body` walks a block
  tree for the *editor*, on a keystroke, and keeps only same-origin paths; this
  walks it for a background job and keeps only the absolute ones. The shared
  part — where a link hides inside Portable Text, including inside a table's
  cells — is `Kiln.Advisory.Body.node_hrefs/1`, so a new nested node type is
  learned once rather than twice.

  Separate from `Body` rather than another field on it, because the two run
  under opposite constraints: `Body` is recomputed while someone types and pays
  for every field it collects, and this runs a handful of times a night.

  ## Links are not only in prose

  A rich-text annotation is the common case, but two blocks *are* a URL:

    * `KilnCMS.Blocks.Embed` — the link an unrecognised provider renders as a
      card. A video taken down is exactly the kind of dead link this feature
      exists for.
    * `KilnCMS.Blocks.Claim` — a citation. A claim whose source has vanished is
      worse than a broken link in prose.

  Media URLs (`Image`, `Gallery`) are deliberately not collected: they point at
  Kiln's own storage or CDN, so a check would be this deployment asking itself
  whether its own files exist, on a schedule, over the network.

  ## One row per URL per document

  A URL repeated in a document collapses to its **first** occurrence, keeping
  the lowest block index. The stored grain is `{document, url}`
  (`KilnCMS.CMS.ExternalLink`), so the alternative is not more detail — it is
  the same row written twice with whichever index happened to land last.
  """

  alias Kiln.Advisory.Body
  alias KilnCMS.Blocks.Claim
  alias KilnCMS.Blocks.Columns
  alias KilnCMS.Blocks.Embed
  alias KilnCMS.Blocks.RichText
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.Links.External

  @type occurrence :: %{url: String.t(), block_index: non_neg_integer()}

  @doc """
  The checkable outbound URLs in `blocks`, in document order.

  Accepts whatever the caller holds — stored `BlockUnion` values, typed structs,
  or raw string-keyed maps — because `TypedBlocks.to_typed/1` is total and never
  raises on a malformed block.
  """
  @spec from_blocks(term()) :: [occurrence()]
  def from_blocks(blocks) do
    blocks
    |> List.wrap()
    |> TypedBlocks.to_typed()
    |> from_typed()
  end

  @doc "Like `from_blocks/1`, for a caller that already typed the blocks."
  @spec from_typed([struct()]) :: [occurrence()]
  def from_typed(typed) when is_list(typed) do
    typed
    |> Enum.with_index()
    |> Enum.flat_map(&occurrences/1)
    |> Enum.filter(&External.checkable?(&1.url))
    |> Enum.uniq_by(& &1.url)
  end

  # A nested block reports against its top-level ancestor's index: that is the
  # block the editor can scroll to, and the same attribution `Body` makes.
  defp occurrences({block, index}) do
    block
    |> flatten()
    |> Enum.flat_map(&urls/1)
    |> Enum.map(&%{url: String.trim(&1), block_index: index})
  end

  defp flatten(%Columns{} = block) do
    [block | block |> Columns.child_blocks_flat() |> Enum.flat_map(&flatten/1)]
  end

  defp flatten(block), do: [block]

  defp urls(%RichText{body: body}) do
    body |> List.wrap() |> Enum.flat_map(&Body.node_hrefs/1)
  end

  defp urls(%Embed{url: url}), do: List.wrap(url)
  defp urls(%Claim{source_url: url}), do: List.wrap(url)
  defp urls(_block), do: []
end
