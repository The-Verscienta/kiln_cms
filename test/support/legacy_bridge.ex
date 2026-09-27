defmodule KilnCMS.LegacyBridge do
  @moduledoc """
  Test-only access to the deprecated legacy-block bridge,
  `KilnCMS.CMS.TypedBlocks.to_legacy/1` and `from_legacy/1` (#1537).

  Tests that pin the bridge's behaviour until 1.0 call it through here, by a
  runtime module reference, so the suite compiles without deprecation
  warnings while the bridge still exists. Delete this module — and the tests
  that use it — when the bridge is removed at 1.0.
  """

  @doc "`KilnCMS.CMS.TypedBlocks.to_legacy/1`, without the compile-time deprecation warning."
  def to_legacy(blocks), do: bridge().to_legacy(blocks)

  @doc "`KilnCMS.CMS.TypedBlocks.from_legacy/1`, without the compile-time deprecation warning."
  def from_legacy(blocks), do: bridge().from_legacy(blocks)

  defp bridge, do: Module.concat([KilnCMS, CMS, TypedBlocks])
end
