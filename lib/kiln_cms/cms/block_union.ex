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
  # The member list is the compile-time union of core + plugin blocks (D18) —
  # see `KilnCMS.Blocks.union_types/0`. A plugin's `blocks/0` joins storage,
  # the editor palette, and firing with no core edits.
  use Ash.Type.NewType,
    subtype_of: :union,
    constraints: [types: KilnCMS.Blocks.union_types()]

  alias KilnCMS.CMS.TypedBlocks

  # Tolerant casts (Kiln v2 storage flip): accept legacy block params and legacy
  # stored rows by normalizing them to the typed shape before the union cast. This
  # keeps existing callers/tests working and converts old rows lazily on read — no
  # data migration required.
  @impl Ash.Type
  def cast_input(value, constraints),
    do: value |> TypedBlocks.to_union_input() |> super(constraints)

  @impl Ash.Type
  def cast_input_array(list, constraints) when is_list(list),
    do: list |> Enum.map(&TypedBlocks.to_union_input/1) |> super(constraints)

  def cast_input_array(other, constraints), do: super(other, constraints)

  @impl Ash.Type
  def cast_stored(value, constraints),
    do: value |> TypedBlocks.to_union_stored() |> super(constraints)

  @impl Ash.Type
  def cast_stored_array(list, constraints) when is_list(list),
    do: list |> Enum.map(&TypedBlocks.to_union_stored/1) |> super(constraints)

  def cast_stored_array(other, constraints), do: super(other, constraints)
end
