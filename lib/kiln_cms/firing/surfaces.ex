defmodule KilnCMS.Firing.Surfaces do
  @moduledoc """
  The single authority for the fired-surface set. Everything that enumerates
  surfaces — the engine, the artifact cache, static export, the delivery and
  provenance controllers, the `PublishedArtifact` constraint — derives from
  here, so adding a surface is one edit (plus its composer and, where wanted,
  per-block renderers) instead of a hand-sweep that can silently miss the
  cache-invalidation or delivery layer.
  """

  @all [:web, :json, :json_ld, :llm]

  @doc "Every fired surface, in firing order."
  @spec all() :: [atom()]
  def all, do: @all

  @doc "Request-string → surface atom map (`\"json_ld\"` → `:json_ld`)."
  @spec name_map() :: %{String.t() => atom()}
  def name_map, do: Map.new(@all, &{to_string(&1), &1})
end
