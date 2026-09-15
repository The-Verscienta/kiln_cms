defmodule KilnCMS.CMS.Changes.NotifyWorkflowEmail do
  @moduledoc """
  After a content lifecycle action, send the matching workflow notification.
  Attach to an action and pass the event name:

      change {KilnCMS.CMS.Changes.NotifyWorkflowEmail, event: :submitted_for_review}
      change {KilnCMS.CMS.Changes.NotifyWorkflowEmail, event: :published}

  Recipient resolution and delivery — email, Web Push, and the in-app inbox —
  live in `KilnCMS.Notifications`.

  ## `after_transaction`, not `after_action`

  `after_action` runs *inside* the write's transaction, and this hook does real
  work there: `Notifications.dispatch/3` loads the record's author, reads the
  org's admins, and (since #1320) inserts a notification row per recipient. A
  query that fails inside `after_action` poisons the Postgres transaction —
  the create/update comes back as an opaque `:rollback` and **the content is
  lost**, which no rescue can prevent. A notification must never be able to
  fail the publish it is describing.

  Post-commit also makes the semantics honest in the other direction: a
  rolled-back submit-for-review now notifies nobody, where before it could
  have mailed the reviewers about a transition that never happened. This is
  the shape `KilnCMS.CMS.Changes.NotifyComment` already had, for the same
  reasons.

  The `{:error, _}` clause falls through untouched, so a failed write is
  returned unchanged and dispatches nothing.

  ## A dispatch failure is logged, never raised

  Post-commit is not the same as harmless: an exception from an
  `after_transaction` hook still propagates to whoever called the action, so a
  raise in `Notifications.dispatch/3` (an author load, the admin roster, an
  `Oban.insert!`) would crash the LiveView or API request whose publish had
  *already committed* — reporting a failure for a write that succeeded. The
  rescue returns the committed result, exactly as `NotifyComment` does.
  """
  use Ash.Resource.Change

  require Logger

  alias KilnCMS.Notifications

  @impl true
  def change(changeset, opts, context) do
    event = Keyword.fetch!(opts, :event)
    actor = context.actor

    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      dispatch(result, event, actor)
    end)
  end

  defp dispatch({:ok, record} = result, event, actor) do
    Notifications.dispatch(event, record, actor)
    result
  rescue
    error ->
      Logger.error("workflow notification #{event} failed: #{Exception.message(error)}")
      result
  end

  defp dispatch(other, _event, _actor), do: other
end
