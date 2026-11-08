defmodule KilnCMS.CMS.Checks.LiveOrScheduled do
  @moduledoc """
  Matches an **update** of a content record that is live (`:published`) or
  already scheduled to go live (`scheduled_at` set), as the row was read
  (`changeset.data`), not the state the update moves it to.

  A policy condition beside `changing_attributes/1` on the content resource's
  `unpublish_at` and `expiry_action` policies (#2134). On such a record those
  two fields are a takedown the AshOban scheduler runs through its bypass —
  for a scheduled draft, one that follows the scheduled publish without
  anybody approving it — so changing them takes the publish permission. On an
  unscheduled draft they do nothing until a publisher publishes (or schedules)
  the whole record, and on a create there is no record at all, so neither is
  gated there.

  Matches no struct but `Ash.Changeset` (a bare module is at most a runtime
  dependency): a check that pattern-matched the content resource's struct would
  be a compile-time cycle with the `policies` block that names it — see
  `KilnCMS.CMS.Checks.EditorMayPublish`.
  """
  use Ash.Policy.SimpleCheck

  @impl Ash.Policy.Check
  def describe(_opts), do: "updating a record that is published or scheduled to publish"

  @impl Ash.Policy.SimpleCheck
  def match?(_actor, %{subject: %Ash.Changeset{action_type: :update, data: data}}, _opts),
    do: live_or_scheduled?(data)

  def match?(_actor, _context, _opts), do: false

  @doc """
  Whether `record` is live or scheduled to go live: the condition the policy
  checks, for a UI that only offers what the policy allows.
  """
  @spec live_or_scheduled?(map()) :: boolean()
  def live_or_scheduled?(record),
    do: Map.get(record, :state) == :published or not is_nil(Map.get(record, :scheduled_at))
end
