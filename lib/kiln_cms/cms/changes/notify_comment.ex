defmodule KilnCMS.CMS.Changes.NotifyComment do
  @moduledoc """
  Emails a block comment's audience (#801).

  The sibling of `KilnCMS.CMS.Changes.NotifyWorkflowEmail`, kept separate
  because a comment is not a lifecycle transition: the recipient set comes from
  the *thread* rather than from a role, and one of the events
  (`:comment_mention`) is addressed to a person named in the body rather than
  to anyone the state machine knows about. Recipients and opt-outs are resolved
  in `KilnCMS.Notifications.dispatch_comment/4`; this is only the trigger.

  ## `after_transaction`, and why the record is re-read here

  Mail is the outside world, so nothing may be enqueued before the row commits
  — a job that runs faster than the transaction would link a recipient to a
  comment that is not there yet, and a rolled-back write must send nothing at
  all. The `{:error, _}` clause falls through untouched, so it does.

  The comment carries only `content_type`/`content_id` (it is anchored
  soft-polymorphically, with no FK), so the content record it belongs to is
  fetched here — the email needs a title and a link, and the audience includes
  that record's author.

  A failure to notify never fails the comment: it is already saved and already
  visible on the thread, and losing an email is a smaller harm than losing the
  feedback.
  """
  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, opts, context) do
    event = Keyword.get(opts, :event, :comment_added)
    actor = context.actor

    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      notify(result, event, actor)
    end)
  end

  defp notify({:ok, comment} = result, event, actor) do
    case content_record(comment) do
      nil -> result
      record -> dispatch(comment, record, event, actor)
    end
  end

  defp notify(other, _event, _actor), do: other

  defp dispatch(comment, record, event, actor) do
    KilnCMS.Notifications.dispatch_comment(event, comment, record, actor)
    {:ok, comment}
  rescue
    error ->
      Logger.error("comment notification failed: #{Exception.message(error)}")
      {:ok, comment}
  end

  defp content_record(comment) do
    KilnCMS.CMS.ContentTypes.get_record!(comment.content_type, comment.content_id,
      authorize?: false,
      tenant: comment.org_id
    )
  rescue
    _error -> nil
  end
end
