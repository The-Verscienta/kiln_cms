defmodule KilnCMS.Backups.DestinationConfig.Changes.SetTestResult do
  @moduledoc """
  A Test's outcome on the destination (#2220): when it ran, whether it
  worked, the node it ran on, and the error, redacted
  (`KilnCMS.Backups.Redact`) and cut to 500 characters so the column's
  `max_length` can never refuse the write. The error arrives already scrubbed
  of the destination's own secrets (`KilnCMS.Backups.Destination.call/4`);
  this is the generic pass on top.
  """
  use Ash.Resource.Change

  alias KilnCMS.Backups.Redact

  @max 500

  @impl true
  def change(changeset, _opts, _context) do
    ok? = Ash.Changeset.get_argument(changeset, :ok) == true

    error =
      if ok?,
        do: nil,
        else:
          changeset |> Ash.Changeset.get_argument(:error) |> to_string() |> Redact.text([], @max)

    node =
      (Ash.Changeset.get_argument(changeset, :node) || to_string(node()))
      |> String.slice(0, KilnCMS.Limits.identifier())

    changeset
    |> Ash.Changeset.force_change_attribute(:last_tested_at, DateTime.utc_now())
    |> Ash.Changeset.force_change_attribute(:last_test_ok, ok?)
    |> Ash.Changeset.force_change_attribute(:last_test_error, error)
    |> Ash.Changeset.force_change_attribute(:last_test_node, node)
  end
end
