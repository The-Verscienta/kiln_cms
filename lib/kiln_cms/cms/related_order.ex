defmodule KilnCMS.CMS.RelatedOrder do
  @moduledoc """
  The order of a record's curated related content (#2025): the `position` of
  the `kind: :related` link joining it to each related record, as the sort
  of every `related_<type>s` relationship.

  A relationship's sort is an expression over the destination, and the link
  is not one of the destination's own fields, so the expression reads it
  back. It is a scalar subquery, because the alternatives do not resolve
  there: inside an aggregate's filter `parent` is the destination, and
  `parent(parent(id))` is not bound in a relationship sort. Here `parent(id)`
  is the source. A `parent` reference makes Ash load the relationship with a
  lateral join, which it allows because `KilnCMS.CMS.RelatedLink` is unique
  on `(source_id, target_id)`; the subquery is an index probe on
  `target_id`.

  Built here rather than inline in `KilnCMS.CMS.Content`, where field names
  inside the macro's `quote` would be hygienic variables, not references.
  """
  import Ash.Expr, only: [expr: 1]

  @doc "The sort expression: the joining link's `position`."
  @spec position_expr() :: Ash.Expr.t()
  def position_expr do
    expr(
      fragment(
        "(SELECT cl.position FROM content_links cl WHERE cl.kind = 'related' AND cl.field IS NULL AND cl.source_id = ? AND cl.target_id = ?)",
        parent(id),
        id
      )
    )
  end
end
