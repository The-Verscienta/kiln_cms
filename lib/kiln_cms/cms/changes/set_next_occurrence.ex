defmodule KilnCMS.CMS.Changes.SetNextOccurrence do
  @moduledoc """
  Maintains the denormalized `next_occurrence_at` attribute the "what's on"
  index sorts by (#766).

  `KilnCMS.Events.Index` has the argument for why the value is stored at all,
  and why `nil` is a terminal answer rather than "not soon". This is the write
  half: every editorial save recomputes it from the document's `datetime_range`
  and `recurrence` fields, so a newly scheduled event is in the index the moment
  it is saved rather than at the next sweep.

  ## It must run after `ApplyCustomFields`

  The schedule lives in `custom_fields`, and `ApplyCustomFields` is what coerces
  the submitted parts into the stored shape (`Changes` run in declaration
  order — #787 was the same ordering bug in the other direction). Reading the
  raw payload here would parse the editor's `datetime-local` string, or a
  three-key part map, rather than the value that will actually be written.

  ## `nil` is the answer for almost every record, and it must be cheap

  This sits on the shared content actions rather than on event-shaped types
  only — which is one less thing to get wrong the day an operator adds a
  schedule field to a type that has been live for a year — so it runs on every
  page, every post, and every **autosave**, which fires per editor pause.

  Asking "does this type have a `datetime_range` field?" is a database read, and
  paying it on every keystroke-pause save of every document would be a real cost
  for an answer that is almost always `nil`. A document with no `custom_fields`
  at all cannot have a schedule, so that case is answered without asking: the
  short-circuit is sound rather than an approximation, and it covers every
  document on every site that does not use custom fields.

  A document that *does* carry custom fields pays one indexed definitions read —
  the same one `ApplyCustomFields` performs, on the same write.
  """
  use Ash.Resource.Change

  alias KilnCMS.Events.Index

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &set_next_occurrence/1)
  end

  defp set_next_occurrence(changeset) do
    Ash.Changeset.force_change_attribute(
      changeset,
      :next_occurrence_at,
      next_occurrence_at(changeset)
    )
  end

  # The EFFECTIVE map — merged, coerced, and already written back by
  # `ApplyCustomFields`, which is why declaration order matters. An empty one is
  # answered `nil` outright; `nil` is still force-changed rather than skipped,
  # because a document whose fields were just cleared has to LOSE the sort key
  # its old schedule gave it.
  defp next_occurrence_at(changeset) do
    case Ash.Changeset.get_attribute(changeset, :custom_fields) do
      fields when is_map(fields) and map_size(fields) > 0 -> compute(changeset)
      _no_fields -> nil
    end
  end

  # `apply_attributes/2` rather than reading `custom_fields` off the changeset
  # by hand: `Events.scope_for/1` dispatches on the *record* — a dynamic entry's
  # `type_definition_id`, a compiled type's module — and hand-building a
  # lookalike map would be a fourth spelling of a scope that already has two.
  #
  # `force?: true` because a changeset carrying errors still reaches
  # `before_action` on some paths, and this must not be the thing that turns a
  # validation failure into a `MatchError`. The value is discarded with the rest
  # of the changeset when those errors surface.
  defp compute(changeset) do
    case Ash.Changeset.apply_attributes(changeset, force?: true) do
      {:ok, record} -> Index.next_occurrence_at(record, changeset.to_tenant)
      _other -> nil
    end
  end
end
