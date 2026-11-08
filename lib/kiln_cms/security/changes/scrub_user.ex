defmodule KilnCMS.Security.Changes.ScrubUser do
  @moduledoc """
  The per-event half of `KilnCMS.Security.anonymize_actor/1` (#2241).

  For the erased `user_id` argument: an event the user acted in loses
  `actor_id`, `actor_label`, `ip` and `user_agent`; an event that names the
  user as its `target_id` loses that. Any touched event's `metadata` is
  emptied, since an allowlisted value (a passkey's name, an API key's name) can
  still be the user's own words. The event itself, its type and its time stay.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    user_id = Ash.Changeset.get_argument(changeset, :user_id)
    record = changeset.data

    changeset =
      if record.actor_id == user_id do
        Ash.Changeset.change_attributes(changeset, %{
          actor_id: nil,
          actor_label: nil,
          ip: nil,
          user_agent: nil
        })
      else
        changeset
      end

    changeset =
      if record.target_id == user_id,
        do: Ash.Changeset.change_attribute(changeset, :target_id, nil),
        else: changeset

    Ash.Changeset.change_attribute(changeset, :metadata, %{})
  end
end
