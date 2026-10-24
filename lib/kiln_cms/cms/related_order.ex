defmodule KilnCMS.CMS.RelatedOrder do
  @moduledoc """
  SPIKE: the sort expression for `related_<type>s` — the `position` of the
  destination's incoming curated link whose source is the record being
  loaded (`parent(parent(id))`: the aggregate's parent is the destination,
  its parent the source).
  """
  import Ash.Expr, only: [expr: 1]

  @doc "The joining link's position."
  def position_expr do
    # A scalar subquery rather than an aggregate: inside an aggregate's
    # filter `parent` is the destination, and `parent(parent(..))` does not
    # resolve in a relationship sort. Here `parent(id)` is the source.
    expr(
      fragment(
        "(SELECT cl.position FROM content_links cl WHERE cl.kind = 'related' AND cl.field IS NULL AND cl.source_id = ? AND cl.target_id = ?)",
        parent(id),
        id
      )
    )
  end
end
