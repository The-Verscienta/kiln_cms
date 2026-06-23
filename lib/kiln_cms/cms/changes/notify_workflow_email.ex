defmodule KilnCMS.CMS.Changes.NotifyWorkflowEmail do
  @moduledoc """
  After a content lifecycle action, send the matching workflow notification
  email. Attach to an action and pass the event name:

      change {KilnCMS.CMS.Changes.NotifyWorkflowEmail, event: :submitted_for_review}
      change {KilnCMS.CMS.Changes.NotifyWorkflowEmail, event: :published}

  Recipient resolution and delivery (via Oban) live in `KilnCMS.Notifications`.
  """
  use Ash.Resource.Change

  alias KilnCMS.Notifications

  @impl true
  def change(changeset, opts, context) do
    event = Keyword.fetch!(opts, :event)

    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      Notifications.dispatch(event, record, context.actor)
      {:ok, record}
    end)
  end
end
