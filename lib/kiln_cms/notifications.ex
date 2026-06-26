defmodule KilnCMS.Notifications do
  @moduledoc """
  Outbound email notifications for content-workflow events.

  Mirrors the webhook pipeline (`KilnCMS.Webhooks`): a lifecycle change calls
  `dispatch/3`, which resolves recipients (as a system read) and enqueues one
  `WorkflowMailWorker` Oban job per recipient. The job builds and delivers the
  Swoosh email, so the editor's request never blocks on mail delivery and a
  transient failure simply retries with backoff.

  Events:

    * `:submitted_for_review` — an editor moved content into review; every admin
      (except the submitter, if they are themselves an admin) is notified so
      someone can approve it.
    * `:published` — content went live; the author is notified. This also covers
      scheduled publishing, where there is no acting user.
    * `:returned_to_draft` — an admin sent reviewed content back to the author.

  Each recipient is honoured against their per-user notification preferences
  (`User.notify_on_*`, issue #46) before a job is enqueued: a user who has
  muted an event for their account is skipped. Preferences default on, so
  existing behaviour is unchanged until someone opts out.
  """
  require Ash.Query

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS.{Page, Post}
  alias KilnCMS.Notifications.WorkflowMailWorker

  @spec dispatch(
          :submitted_for_review | :published | :returned_to_draft,
          Page.t() | Post.t(),
          map() | nil
        ) :: :ok
  def dispatch(:submitted_for_review, record, actor) do
    User
    |> Ash.Query.filter(role == :admin)
    |> Ash.read!(authorize?: false)
    |> Enum.reject(&same_user?(&1, actor))
    |> Enum.filter(&wants?(&1, :submitted_for_review))
    |> Enum.each(&enqueue(email_of(&1), :submitted_for_review, record, actor))
  end

  def dispatch(:published, record, _actor) do
    notify_author(record, :published, nil)
  end

  def dispatch(:returned_to_draft, record, actor) do
    notify_author(record, :returned_to_draft, actor)
  end

  # Author-targeted events (`:published`, `:returned_to_draft`) load the author
  # and notify them unless they've muted that event for their account.
  defp notify_author(record, event, actor) do
    author = record |> Ash.load!(:author, authorize?: false) |> Map.get(:author)

    if author && wants?(author, event) do
      enqueue(email_of(author), event, record, actor)
    else
      :ok
    end
  end

  # Per-user opt-out (issue #46). Unknown/legacy users default to opted-in.
  defp wants?(%{notify_on_review_request: enabled?}, :submitted_for_review), do: enabled?
  defp wants?(%{notify_on_publish: enabled?}, :published), do: enabled?
  defp wants?(%{notify_on_return_to_draft: enabled?}, :returned_to_draft), do: enabled?
  defp wants?(_user, _event), do: true

  defp enqueue(nil, _event, _record, _actor), do: :ok

  defp enqueue(to, event, record, actor) do
    %{
      "to" => to,
      "event" => to_string(event),
      "kind" => kind(record),
      "title" => record.title,
      "id" => record.id,
      "actor_name" => actor_name(actor)
    }
    |> WorkflowMailWorker.new()
    |> Oban.insert!()

    :ok
  end

  defp kind(%Page{}), do: "page"
  defp kind(%Post{}), do: "post"

  # The submitter's display name for the body; nil for actor-less events.
  # Privacy (#214): prefer the user's chosen `name`; never fall back to the
  # email local-part. When no name is set we return nil and the mail worker
  # renders a neutral "An editor" / "A reviewer".
  defp actor_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp actor_name(_actor), do: nil

  defp same_user?(_user, nil), do: false
  defp same_user?(%{id: id}, %{id: id}), do: true
  defp same_user?(_user, _actor), do: false

  # `email` is an `Ash.CiString`, so normalise via `to_string/1`.
  defp email_of(%{email: email}) when not is_nil(email), do: to_string(email)
  defp email_of(_), do: nil
end
