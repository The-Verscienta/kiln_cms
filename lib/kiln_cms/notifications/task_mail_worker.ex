defmodule KilnCMS.Notifications.TaskMailWorker do
  @moduledoc """
  Delivers a single task-notification email — either a fresh assignment
  (`"assigned"`) or a daily due-soon/overdue digest (`"digest"`, one job per
  assignee, enqueued by `KilnCMS.Notifications.TaskDigestWorker`).

  Same delivery shape as `KilnCMS.Notifications.WorkflowMailWorker`
  (`KilnCMS.Mail.deliver_for_worker/2`, same retry/backoff), but its own
  worker: a task's recipient is already known (the assignee), and the digest
  body is a per-assignee list rather than a single `Kiln.Tokens` template.
  """
  use Oban.Worker, queue: :mail, max_attempts: 8
  use KilnCMSWeb, :verified_routes

  import Swoosh.Email

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Mail

  @impl Oban.Worker
  def perform(%Oban.Job{id: id, args: %{"kind" => "assigned"} = args}) do
    args
    |> build_assigned_email()
    |> Mail.ensure_message_id("task-#{id}")
    |> Mail.deliver_for_worker()
  end

  def perform(%Oban.Job{id: id, args: %{"kind" => "digest"} = args}) do
    args
    |> build_digest_email()
    |> Mail.ensure_message_id("task-digest-#{id}")
    |> Mail.deliver_for_worker()
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: Mail.backoff_seconds(attempt)

  @impl Oban.Worker
  def timeout(_job), do: Mail.attempt_timeout()

  defp build_assigned_email(args) do
    title = content_title(args["content_type"], args["content_id"], args["org_id"])
    block_id = args["block_id"]

    url =
      editor_url(args["content_type"], args["content_id"], block_id)

    body = """
    <p>#{h(actor_display(args["actor_name"]))} assigned you a task on <strong>#{h(title)}</strong>.</p>
    #{block_line(args["content_type"], args["content_id"], args["org_id"], block_id)}
    #{due_line(args["due_on"])}
    #{note_line(args["note"])}
    <p><a href="#{url}">#{if block_id, do: "Open that block in the editor", else: "Open it in the editor"}</a>.</p>
    """

    base(args["to"])
    |> subject(plain("Task assigned: #{title}"))
    |> html_body(body)
  end

  # Which block the task is about, named by **type** and nothing else.
  #
  # Read through the `block_ids` calculation, which projects the tree to
  # `_id`/`_type` and carries no field values at all. That matters here: block
  # content can sit behind `editable_by` field grants
  # (`Changes.EnforceBlockFieldPolicy`), and an email is a surface with no
  # actor to check them against — quoting the paragraph would be a way around
  # a policy rather than a nicety. The type plus a deep link is enough to know
  # where you are going, and needs no such judgement.
  defp block_line(_content_type, _content_id, _org_id, nil), do: ""

  defp block_line(content_type, content_id, org_id, block_id) do
    case ContentTypes.get_record(content_type, content_id,
           authorize?: false,
           tenant: org_id,
           query: [select: [:id], load: [:block_ids]]
         ) do
      {:ok, %{block_ids: blocks}} ->
        case Enum.find(List.wrap(blocks), &(&1["_id"] == block_id)) do
          %{"_type" => type} when is_binary(type) -> "<p>On the #{h(type)} block.</p>"
          # The block has been deleted since. The task is still real — nothing
          # cascades — so say so rather than drop the line and imply the task
          # is about the whole document.
          _gone -> "<p>On a block that has since been removed.</p>"
        end

      _unreadable ->
        ""
    end
  end

  defp build_digest_email(args) do
    items = args["items"] || []

    rows =
      Enum.map_join(items, "\n", fn item ->
        title = content_title(item["content_type"], item["content_id"], args["org_id"])
        url = editor_url(item["content_type"], item["content_id"])
        status = if overdue?(item["due_on"]), do: "overdue", else: "due soon"

        """
        <li>
          <a href="#{url}">#{h(title)}</a> — #{h(status)}#{due_suffix(item["due_on"])}
        </li>
        """
      end)

    body = """
    <p>You have #{length(items)} open #{plural(length(items), "task", "tasks")} due soon or overdue:</p>
    <ul>
    #{rows}
    </ul>
    <p><a href="#{url(~p"/editor/tasks")}">View your tasks</a>.</p>
    """

    base(args["to"])
    |> subject(
      plain("Your task digest: #{length(items)} #{plural(length(items), "item", "items")}")
    )
    |> html_body(body)
  end

  defp content_title(content_type, content_id, org_id) do
    case ContentTypes.get_record(content_type, content_id,
           authorize?: false,
           tenant: org_id,
           query: [select: [:id, :title]]
         ) do
      {:ok, record} -> record.title
      _ -> content_type
    end
  end

  defp due_line(nil), do: ""
  defp due_line(due_on), do: "<p>Due #{h(due_on)}.</p>"

  defp due_suffix(nil), do: ""
  defp due_suffix(due_on), do: " (#{h(due_on)})"

  defp note_line(nil), do: ""
  defp note_line(""), do: ""
  defp note_line(note), do: "<p>#{h(note)}</p>"

  defp overdue?(nil), do: false

  defp overdue?(due_on) do
    case Date.from_iso8601(due_on) do
      {:ok, date} -> Date.before?(date, Date.utc_today())
      _ -> false
    end
  end

  defp plural(1, singular, _plural), do: singular
  defp plural(_n, _singular, plural), do: plural

  defp base(to) do
    new()
    |> from(Application.fetch_env!(:kiln_cms, :email_from))
    |> to(to)
  end

  defp actor_display(nil), do: "An editor"
  defp actor_display(name), do: name

  # HTML-escape any editor-controlled value (title, note, actor name) before
  # it lands in the email body — same reasoning as WorkflowMailWorker.
  defp h(value) do
    value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

  # A mail header, never HTML — stripped of embedded CR/LF (same reasoning as
  # WorkflowMailWorker.plain/1: an editor-supplied title reaching subject/2
  # unescaped is a header-injection risk, see #468).
  defp plain(value), do: value |> to_string() |> String.replace(~r/[\r\n]+/, " ")

  defp editor_url("page", id), do: url(~p"/editor/pages/#{id}")
  defp editor_url("post", id), do: url(~p"/editor/posts/#{id}")
  defp editor_url(kind, id), do: url(~p"/editor/content/#{kind}/#{id}")

  # `?comment=<block_id>` is the editor's existing landing param (the shared
  # preview's pins already use it), so a block task's email opens the same
  # drawer a pin does rather than needing a second deep-link vocabulary.
  defp editor_url(kind, id, nil), do: editor_url(kind, id)

  defp editor_url("page", id, block_id), do: url(~p"/editor/pages/#{id}?comment=#{block_id}")
  defp editor_url("post", id, block_id), do: url(~p"/editor/posts/#{id}?comment=#{block_id}")

  defp editor_url(kind, id, block_id),
    do: url(~p"/editor/content/#{kind}/#{id}?comment=#{block_id}")
end
