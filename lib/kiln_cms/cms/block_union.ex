defmodule KilnCMS.CMS.BlockUnion do
  @moduledoc """
  The typed-block storage type (Kiln v2 — decision D11): an `Ash.Type.Union` over
  the typed block embedded resources, tagged by the `_type` discriminator.

  This is the canonical container for a document's block tree. It is decided over
  `polymorphic_embed` to stay within Ash idioms (no extra dependency). Members are
  the `Kiln.Block` modules; `KilnCMS.Blocks` is the registry they come from.

  Storage uses the default `:type_and_value` shape (`%{"type" => ..., "value" =>
  ...}`); at runtime each element is an `%Ash.Union{type: atom, value: struct}`.

  > The on-disk `Page.blocks`/`Post.blocks` columns still hold the legacy
  > `KilnCMS.CMS.Block` shape; `KilnCMS.CMS.TypedBlocks` bridges legacy → typed so
  > firing/search/embeddings (Phases D–J) operate on this typed representation.
  > Flipping the stored column + the native-union editor is the remaining Phase C
  > increment.
  """
  use Ash.Type.NewType,
    subtype_of: :union,
    constraints: [
      types: [
        heading: [type: KilnCMS.Blocks.Heading, tag: :_type, tag_value: "heading"],
        image: [type: KilnCMS.Blocks.Image, tag: :_type, tag_value: "image"],
        rich_text: [type: KilnCMS.Blocks.RichText, tag: :_type, tag_value: "rich_text"],
        quote: [type: KilnCMS.Blocks.Quote, tag: :_type, tag_value: "quote"],
        embed: [type: KilnCMS.Blocks.Embed, tag: :_type, tag_value: "embed"],
        custom: [type: KilnCMS.Blocks.Custom, tag: :_type, tag_value: "custom"]
      ]
    ]
end
