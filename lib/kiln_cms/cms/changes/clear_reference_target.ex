defmodule KilnCMS.CMS.Changes.ClearReferenceTarget do
  @moduledoc """
  The body of a content resource's internal `:clear_reference_target` action
  (R5): takes a purged record out of this record's `:reference` fields whose
  `on_target_delete` is `:clear` (`KilnCMS.CMS.ContentLinks.TargetDelete`).

  The target and the fields ride in the changeset **context**
  (`cleared_reference: %{target_id:, fields:}`), not in an argument, so the
  action has no input an HTTP surface could fill — the
  `:sync_shared_fields` pattern. A pending working copy that holds the
  custom fields loses the target too, and its recorded base moves with the
  live value when it was based on it, so *Publish changes* neither brings
  the purged record back nor reports a conflict nobody made.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.ContentLinks.TargetDelete
  alias KilnCMS.CMS.WorkingCopy

  @impl true
  def change(changeset, _opts, _context) do
    case Map.get(changeset.context, :cleared_reference) do
      %{target_id: target_id, fields: [_ | _] = fields} ->
        record = changeset.data
        live = TargetDelete.drop_target(record.custom_fields, fields, target_id)

        changeset
        |> Ash.Changeset.force_change_attribute(:custom_fields, live)
        |> clear_working_copy(record, live, fields, target_id)

      _nothing ->
        changeset
    end
  end

  defp clear_working_copy(changeset, record, live, fields, target_id) do
    case Map.get(record, :working_fields) do
      %{"custom_fields" => held} = working ->
        held = TargetDelete.drop_target(held, fields, target_id)

        changeset
        |> Ash.Changeset.force_change_attribute(
          :working_fields,
          Map.put(working, "custom_fields", held)
        )
        |> Ash.Changeset.force_change_attribute(:working_base, rebase(record, live))

      _nothing_held ->
        changeset
    end
  end

  defp rebase(record, live) do
    base = WorkingCopy.base_fingerprints(record)

    if Map.get(base, "custom_fields") == WorkingCopy.live_fingerprint(record, "custom_fields"),
      do:
        Map.put(
          base,
          "custom_fields",
          WorkingCopy.fingerprint(record.__struct__, "custom_fields", live)
        ),
      else: base
  end
end
