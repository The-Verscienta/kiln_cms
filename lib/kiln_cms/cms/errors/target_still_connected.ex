defmodule KilnCMS.CMS.Errors.TargetStillConnected do
  @moduledoc """
  A purge refused because a `:reference` field whose `on_target_delete` is
  `:restrict` (R5 in `docs/relationships-plan.md`) still connects records to
  the one being purged (`KilnCMS.CMS.Changes.ApplyTargetDeleteRules`).

  Carries the field's label and how many records connect through it — never
  which ones — so the trash can say what stands in the way in plain words.
  Trash itself is never refused: only the permanent delete is.
  """
  use Splode.Error, fields: [:field_label, :count], class: :invalid

  @impl true
  def message(%{field_label: label, count: count}) do
    "can't be deleted permanently: #{count} #{if count == 1, do: "record still connects", else: "records still connect"} " <>
      "to it through “#{label}”, which is set to keep connected records from being deleted"
  end
end
