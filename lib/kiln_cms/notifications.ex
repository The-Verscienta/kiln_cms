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
    |> Enum.each(&enqueue(email_of(&1), :submitted_for_review, record, actor))
  end

  def dispatch(:published, record, _actor) do
    record
    |> Ash.load!(:author, authorize?: false)
    |> Map.get(:author)
    |> email_of()
    |> enqueue(:published, record, nil)
  end

  def dispatch(:returned_to_draft, record, actor) do
    record
    |> Ash.load!(:author, authorize?: false)
    |> Map.get(:author)
    |> email_of()
    |> enqueue(:returned_to_draft, record, actor)
  end

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
  defp actor_name(nil), do: nil
  defp actor_name(actor), do: actor |> email_of() |> local_part()

  defp same_user?(_user, nil), do: false
  defp same_user?(%{id: id}, %{id: id}), do: true
  defp same_user?(_user, _actor), do: false

  # `email` is an `Ash.CiString`, so normalise via `to_string/1`.
  defp email_of(%{email: email}) when not is_nil(email), do: to_string(email)
  defp email_of(_), do: nil

  defp local_part(nil), do: nil
  defp local_part(email), do: email |> String.split("@") |> hd()
end
