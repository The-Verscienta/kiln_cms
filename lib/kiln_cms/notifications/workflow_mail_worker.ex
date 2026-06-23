defmodule KilnCMS.Notifications.WorkflowMailWorker do
  @moduledoc """
  Delivers a single content-workflow notification email.

  Enqueued by `KilnCMS.Notifications` (one job per recipient). Builds the Swoosh
  email for the event and delivers it via `KilnCMS.Mailer`; delivery failures
  raise and Oban retries with backoff.
  """
  use Oban.Worker, queue: :default, max_attempts: 3
  use KilnCMSWeb, :verified_routes

  import Swoosh.Email

  alias KilnCMS.Mailer

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    args
    |> build_email()
    |> Mailer.deliver!()

    :ok
  end

  defp build_email(%{"event" => "submitted_for_review"} = args) do
    %{"to" => to, "title" => title, "kind" => kind, "id" => id, "actor_name" => who} = args

    base(to)
    |> subject("Review requested: #{title}")
    |> html_body("""
    <p>#{submitter(who)} submitted the #{kind} <strong>#{title}</strong> for review.</p>
    <p><a href="#{editor_url(kind, id)}">Open it in the editor</a> to review and publish.</p>
    """)
  end

  defp build_email(%{"event" => "published"} = args) do
    %{"to" => to, "title" => title, "kind" => kind, "id" => id} = args

    base(to)
    |> subject("Published: #{title}")
    |> html_body("""
    <p>Your #{kind} <strong>#{title}</strong> is now live.</p>
    <p><a href="#{editor_url(kind, id)}">View it in the editor</a>.</p>
    """)
  end

  defp build_email(%{"event" => "returned_to_draft"} = args) do
    %{"to" => to, "title" => title, "kind" => kind, "id" => id, "actor_name" => who} = args

    base(to)
    |> subject("Changes requested: #{title}")
    |> html_body("""
    <p>#{reviewer(who)} requested changes on your #{kind} <strong>#{title}</strong>.</p>
    <p>It has been moved back to draft so you can revise and resubmit.</p>
    <p><a href="#{editor_url(kind, id)}">Open it in the editor</a>.</p>
    """)
  end

  defp base(to) do
    new()
    |> from(Application.fetch_env!(:kiln_cms, :email_from))
    |> to(to)
  end

  defp submitter(nil), do: "An editor"
  defp submitter(who), do: who

  defp reviewer(nil), do: "A reviewer"
  defp reviewer(who), do: who

  defp editor_url("page", id), do: url(~p"/editor/pages/#{id}")
  defp editor_url("post", id), do: url(~p"/editor/posts/#{id}")
  defp editor_url(kind, id), do: url(~p"/editor/content/#{kind}/#{id}")
end
