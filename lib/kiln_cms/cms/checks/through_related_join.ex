defmodule KilnCMS.CMS.Checks.ThroughRelatedJoin do
  @moduledoc """
  Matches a join-row read that Ash runs **as the join** of a content
  resource's `related_<type>s` many-to-many (#1594), or of its write side
  `curated_<type>s` — reads of `KilnCMS.CMS.RelatedLink` since #2025.

  Those reads never hand a link row to the caller: a load uses the rows only to
  find destination ids, and the destinations are then read under their own
  policy (an unpublished related page is filtered out there), while the source
  is the record being loaded, which the caller could already read. A managed
  unrelate reads the row only to delete it, inside a write the caller was
  authorized for.

  So the both-ends check (`Checks.LinkEndsReadable`) has nothing to add on that
  path — and, being a runtime check, it cannot be folded into the join query
  Ash authorizes ahead of the load. Ash marks the path with
  `context.accessing_from.name`, the join relationship's name, which for a
  `many_to_many` it generates as `<relationship>_join_assoc`.
  """
  use Ash.Policy.SimpleCheck

  @impl Ash.Policy.Check
  def describe(_opts), do: "the read is the join of a related-content relationship"

  @impl Ash.Policy.SimpleCheck
  def match?(_actor, %{subject: %{context: context}}, _opts), do: related_join?(context)
  def match?(_actor, _authorizer, _opts), do: false

  @doc false
  @spec related_join?(map() | nil) :: boolean()
  def related_join?(%{accessing_from: %{name: name}}) when is_atom(name) do
    name = Atom.to_string(name)

    # `curated_<type>s` is the write side of `related_<type>s` over the same
    # join (`KilnCMS.CMS.RelatedLink`): its managed unrelate reads the row.
    (String.starts_with?(name, "related_") or String.starts_with?(name, "curated_")) and
      String.ends_with?(name, "_join_assoc")
  end

  def related_join?(_context), do: false
end
