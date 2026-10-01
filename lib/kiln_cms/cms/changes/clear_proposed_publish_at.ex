defmodule KilnCMS.CMS.Changes.ClearProposedPublishAt do
  @moduledoc """
  Clears a content record's `proposed_publish_at` once a real publish date
  answers it (#1812).

  A proposal is an editor without publish rights asking for a date. It is
  answered when someone who may publish either sets `scheduled_at` (to the
  proposed date — "Confirm date" is exactly that write — or to any other) or
  publishes the record. Both settle the question, so the proposal goes; left
  behind, it would keep drawing a "Proposed" chip on the calendar beside the
  real schedule.

  Clearing `scheduled_at` (unscheduling) does not touch a proposal: that is a
  decision about the schedule, not an answer to the request.

  On every update action through the Content macro's `changes` block, so a
  schedule set through the editor, the API or a calendar drag all count the
  same.
  """
  use Ash.Resource.Change

  @publishes [:publish, :publish_scheduled]

  @impl true
  def change(changeset, _opts, _context) do
    if answered?(changeset) do
      Ash.Changeset.force_change_attribute(changeset, :proposed_publish_at, nil)
    else
      changeset
    end
  end

  defp answered?(%{action: %{name: name}}) when name in @publishes, do: true

  defp answered?(changeset) do
    Ash.Changeset.changing_attribute?(changeset, :scheduled_at) and
      not is_nil(Ash.Changeset.get_attribute(changeset, :scheduled_at))
  end
end
