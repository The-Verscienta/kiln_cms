defmodule KilnCMS.CMS.JoinGraduation.SourceCap do
  @moduledoc """
  A graduated field's `max_sources` (R1b) on its join resource's create:
  `mix kiln.gen.join` writes `change {KilnCMS.CMS.JoinGraduation.SourceCap,
  max_sources: n}` when the field had a cap (#2024).

  The same rule `KilnCMS.CMS.ContentLinks.reconcile/1` held the field to,
  checked the same way, inside the create's transaction:

    * before the insert, the transaction-scoped advisory lock for
      `(org, source type, field, target)` — the very key the field used
      (`KilnCMS.CMS.ContentLinks.lock_target/4`), so while both the field and
      its join table are live, neither counts past the other — then
    * a count of the other sources already connected to the target; at the
      cap or above it (a tightened cap), the create is refused with a
      `target_id` error that names the count, never the other sources.

  Only the create is checked: a connection's ends cannot change on update,
  and removing one is never refused. The field, label and source type come
  from the resource's `__kiln_join__/0`.

  A `bulk_create` runs this once per row, before the batch inserts, so rows
  of one batch do not see each other: bring connections in one create at a
  time where the cap is tight. The graduation's own copy (`--data-migration`)
  is plain SQL and is not held to the cap, as the edges it copies already
  were.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.ContentLinks
  alias KilnCMS.CMS.JoinGraduation

  @impl true
  def init(opts) do
    case opts[:max_sources] do
      max when is_integer(max) and max >= 1 -> {:ok, opts}
      other -> {:error, "max_sources must be a positive integer, got: #{inspect(other)}"}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, &check(&1, opts[:max_sources]))
  end

  defp check(changeset, max) do
    %{field: field, label: label, source_type: source_type} =
      changeset.resource.__kiln_join__()

    org_id = changeset.tenant || Ash.Changeset.get_attribute(changeset, :org_id)
    target_id = Ash.Changeset.get_attribute(changeset, :target_id)
    source_id = Ash.Changeset.get_attribute(changeset, :source_id)

    ContentLinks.lock_target(org_id, source_type, field, target_id)

    count =
      changeset.resource
      |> JoinGraduation.connected_sources(target_id, org_id)
      |> Enum.count(&(&1 != source_id))

    if count >= max do
      Ash.Changeset.add_error(
        changeset,
        Ash.Error.Changes.InvalidAttribute.exception(
          field: :target_id,
          message:
            "#{label} (#{field}) — the chosen record is full: it already has " <>
              "#{count} of #{max} connected through this field",
          value: target_id
        )
      )
    else
      changeset
    end
  end
end
