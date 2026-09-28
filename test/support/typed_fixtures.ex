defmodule KilnCMS.TypedFixtures do
  @moduledoc """
  Test fixtures written in the pre-typed block shape (`%{type: :heading,
  content: …, data: …}`), as typed block input.

  1.0 refuses that shape as write input (#1543) but keeps reading it — stored
  rows and version history. Many tests describe their blocks in it because it
  is short; `typed_blocks/1` runs such a list through the same read conversion
  a stored legacy row gets (`KilnCMS.CMS.TypedBlocks.to_typed/1`) and hands back
  the typed input maps a write accepts. A test that is *about* the legacy shape
  should not use this: it should write the stored shape with `Ash.Seed` or raw
  SQL, the way `KilnCMS.LegacyBlockCorpus` does.
  """

  alias KilnCMS.CMS.TypedBlocks

  @doc "Legacy-shaped block maps as typed block input maps."
  @spec typed_blocks([map()]) :: [map()]
  def typed_blocks(blocks) do
    blocks
    |> TypedBlocks.to_typed()
    |> Enum.map(&TypedBlocks.input_map/1)
  end
end
