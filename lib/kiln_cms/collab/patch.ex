defmodule KilnCMS.Collab.Patch do
  @moduledoc """
  Fine-grained prose patch application (Kiln v2 — decision D5/F).

  The v1 strategy is the plan's "lightweight patch": the client sends the block's
  new Portable Text body and the server applies it last-write-wins. The seam is
  deliberately small so CRDT/OT (`y_ex`) can replace `apply_prose/2` in v2 without
  changing callers.
  """

  @doc "Apply a prose patch to a block map, replacing its Portable Text body."
  @spec apply_prose(map(), %{optional(String.t()) => term()}) :: map()
  def apply_prose(block, %{"body" => body}) when is_list(body), do: Map.put(block, "body", body)
  def apply_prose(block, _patch), do: block
end
