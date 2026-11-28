defmodule KilnCMS.CMS.Changes.SetIpBlockSource do
  @moduledoc """
  Records who added an IP block rule (#2810): `:scanner_guard` when the actor
  is the scanner guard's system actor, otherwise the attribute's default,
  `:admin`.

  The value comes from the actor and nothing else. `source` is not writable
  and not in the create's `accept`, so a person cannot mark a rule of their
  own as the scanner guard's, which would silence its `blocked_ip` alerts.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, %{actor: %KilnCMS.SystemActor{subsystem: :scanner_guard}}),
    do: Ash.Changeset.force_change_attribute(changeset, :source, :scanner_guard)

  def change(changeset, _opts, _context), do: changeset
end
