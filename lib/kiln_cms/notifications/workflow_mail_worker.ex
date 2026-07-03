defmodule KilnCMS.Notifications.WorkflowMailWorker do
  @moduledoc """
  Delivers a single content-workflow notification email.

  Enqueued by `KilnCMS.Notifications` (one job per recipient). Builds the
  Swoosh email for the event and delivers it via
  `KilnCMS.Mail.deliver_for_worker/2`: permanent (5xx) failures cancel the
  job, transient failures raise and Oban retries on the same greylist-aware
  backoff as `KilnCMS.Mail.DeliveryWorker`.
  """
  use Oban.Worker, queue: :mail, max_attempts: 8
  use KilnCMSWeb, :verified_routes

  import Swoosh.Email

  alias KilnCMS.Mail

  @impl Oban.Worker
  def perform(%Oban.Job{id: id, args: args}) do
    args
    |> build_email()
    # This worker builds its email at perform time (not via Mail.enqueue!), so
    # stamp a domain-correct Message-ID here too — keyed on the job id so all
    # retries of this job carry the *same* ID rather than a fresh one each
    # attempt (and so gen_smtp doesn't fill in one from the container hostname).
    |> Mail.ensure_message_id("workflow-#{id}")
    |> Mail.deliver_for_worker()
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: Mail.backoff_seconds(attempt)

  defp build_email(%{"event" => "submitted_for_review"} = args) do
    %{"to" => to, "title" => title, "kind" => kind, "id" => id, "actor_name" => who} = args

    base(to)
    |> subject("Review requested: #{title}")
    |> html_body("""
    <p>#{h(submitter(who))} submitted the #{h(kind)} <strong>#{h(title)}</strong> for review.</p>
    <p><a href="#{editor_url(kind, id)}">Open it in the editor</a> to review and publish.</p>
    """)
  end

  defp build_email(%{"event" => "published"} = args) do
    %{"to" => to, "title" => title, "kind" => kind, "id" => id} = args

    base(to)
    |> subject("Published: #{title}")
    |> html_body("""
    <p>Your #{h(kind)} <strong>#{h(title)}</strong> is now live.</p>
    <p><a href="#{editor_url(kind, id)}">View it in the editor</a>.</p>
    """)
  end

  defp build_email(%{"event" => "returned_to_draft"} = args) do
    %{"to" => to, "title" => title, "kind" => kind, "id" => id, "actor_name" => who} = args

    base(to)
    |> subject("Changes requested: #{title}")
    |> html_body("""
    <p>#{h(reviewer(who))} requested changes on your #{h(kind)} <strong>#{h(title)}</strong>.</p>
    <p>It has been moved back to draft so you can revise and resubmit.</p>
    <p><a href="#{editor_url(kind, id)}">Open it in the editor</a>.</p>
    """)
  end

  defp base(to) do
    new()
    |> from(Application.fetch_env!(:kiln_cms, :email_from))
    |> to(to)
  end

  # HTML-escape any editor/importer-controlled value before it lands in the
  # email body. Titles and actor names are author-supplied (and copied verbatim
  # by the Verscienta importer), so interpolating them raw would inject markup
  # into a transactional email. `editor_url/2` values are server-generated
  # verified routes and don't need escaping.
  defp h(value) do
    value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

  defp submitter(nil), do: "An editor"
  defp submitter(who), do: who

  defp reviewer(nil), do: "A reviewer"
  defp reviewer(who), do: who

  defp editor_url("page", id), do: url(~p"/editor/pages/#{id}")
  defp editor_url("post", id), do: url(~p"/editor/posts/#{id}")
  defp editor_url(kind, id), do: url(~p"/editor/content/#{kind}/#{id}")
end
