defmodule KilnCMS.Notifications.TaskMailWorker do
  @moduledoc """
  Delivers a single task-notification email — either a fresh assignment
  (`"assigned"`) or a daily due-soon/overdue digest (`"digest"`, one job per
  assignee, enqueued by `KilnCMS.Notifications.TaskDigestWorker`).

  Same delivery shape as `KilnCMS.Notifications.WorkflowMailWorker`
  (`KilnCMS.Mail.deliver_for_worker/2`, same retry/backoff), but its own
  worker: a task's recipient is already known (the assignee), and the digest
  body is a per-assignee list rather than a single `Kiln.Tokens` template.

  ## Read back when it runs (#3019)

  The job carries ids: the assignee (`user_id`), the site, and for an
  assignment the task (`task_id`) and the assigning account (`actor_id`); a
  digest's `items` are content ids and due dates. The assignee must still be
  one when the job runs (`KilnCMS.Notifications.mail_recipient/2`): an
  account erased since, or left with no address, is sent nothing, and the mail
  goes to the address the account holds now. An assignment reads the task
  back, and sends nothing for a task deleted, completed or reassigned since;
  the note and due date are the task's now, and an assigner erased since is
  "An editor". A digest whose content is gone keeps its line, titled by the
  content type, as before.

  A skip finishes the job (`:ok`, logged with the job id and the reason), not
  a cancel, so it is not listed as a delivery failure on `/editor/mail`. A
  read that fails, including a refused one, fails the job, which retries.

  The args name the job's type under `"event"`, not `"kind"`, on purpose:
  the previous release's clauses match on `"kind"` alone and would build an
  email with no recipient from a job of this shape. Without it an old node
  fails the job during a rolling deploy and a new node delivers it on retry.

  A job queued by the release before this one carries `"kind"`, the address,
  the note and the actor's name. It is delivered only while an account that
  existed when it was queued still holds that address, and those keys are
  dropped from its row once it finishes (`KilnCMS.Jobs.PrivateArgs`).
  """
  use Oban.Worker, queue: :mail, max_attempts: 8
  use KilnCMSWeb, :verified_routes

  import Swoosh.Email

  require Logger

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Jobs.PrivateArgs
  alias KilnCMS.Mail
  alias KilnCMS.Notifications
  alias KilnCMS.Notifications.Link

  @impl Oban.Worker
  def perform(
        %Oban.Job{
          args: %{"event" => "assigned", "user_id" => user_id, "task_id" => task_id} = args
        } =
          job
      )
      when is_binary(user_id) and is_binary(task_id) do
    tenant = args["org_id"]

    with {:ok, user} <- Notifications.mail_recipient(user_id, nil),
         {:ok, task} <- open_task(task_id, user_id, tenant) do
      %{
        "to" => to_string(user.email),
        "task_id" => task.id,
        "content_type" => task.content_type,
        "content_id" => task.content_id,
        "block_id" => task.block_id,
        "org_id" => tenant,
        "due_on" => task.due_on && Date.to_iso8601(task.due_on),
        "note" => task.note,
        "actor_name" => Notifications.actor_name_now(args["actor_id"])
      }
      |> deliver_assigned(job)
    else
      {:skip, reason} -> skip(job, reason)
      {:error, error} -> {:error, error}
    end
  end

  def perform(%Oban.Job{args: %{"event" => "digest", "user_id" => user_id} = args} = job)
      when is_binary(user_id) do
    case Notifications.mail_recipient(user_id, nil) do
      {:ok, user} -> args |> Map.put("to", to_string(user.email)) |> deliver_digest(job)
      {:skip, reason} -> skip(job, reason)
      {:error, error} -> {:error, error}
    end
  end

  # Queued by the release before #3019, with the address, note and actor name
  # in the args. Remove no earlier than the release after this one: the
  # Pruner deletes finished rows after a week, and a retrying mail job is done
  # within a day.
  def perform(%Oban.Job{args: %{"kind" => kind, "to" => to} = args} = job)
      when kind in ["assigned", "digest"] and is_binary(to) do
    PrivateArgs.finishing(job, PrivateArgs.keys(__MODULE__), fn ->
      case Notifications.mail_recipient_by_address(to, job.inserted_at, nil) do
        {:ok, _user} when kind == "assigned" -> deliver_assigned(args, job)
        {:ok, _user} -> deliver_digest(args, job)
        {:skip, reason} -> skip(job, reason)
        {:error, error} -> {:error, error}
      end
    end)
  end

  # Neither shape: a legacy job whose keys were already dropped
  # (`PrivateArgs.finishing/3` forgets before Oban acks the job, so a node
  # lost in between leaves it executing without them, and Lifeline re-queues
  # it). The mail went out; nothing is left to send.
  def perform(%Oban.Job{}), do: {:cancel, "notification no longer in the job"}

  defp deliver_assigned(args, %Oban.Job{id: id}) do
    args
    |> build_assigned_email()
    |> Mail.ensure_message_id("task-#{id}")
    # Through the site's own relay when it has one (#1322).
    |> Mail.deliver_for_worker(org_id: args["org_id"])
  end

  defp deliver_digest(args, %Oban.Job{id: id}) do
    args
    |> build_digest_email()
    |> Mail.ensure_message_id("task-digest-#{id}")
    |> Mail.deliver_for_worker(org_id: args["org_id"])
  end

  # The task as it is now, read as the notifier's system actor, which
  # `CMS.Task` admits for reads (#1659), with `authorize_with: :error` so a
  # refused read fails the job rather than reading as "task deleted". Sent only
  # while the task is still open and still this assignee's.
  defp open_task(task_id, user_id, tenant) do
    case CMS.get_task(task_id,
           actor: Notifications.system(),
           authorize_with: :error,
           not_found_error?: false,
           tenant: tenant
         ) do
      {:ok, nil} -> {:skip, :task_gone}
      {:ok, %{status: :done}} -> {:skip, :task_done}
      {:ok, %{assignee_id: ^user_id} = task} -> {:ok, task}
      {:ok, _reassigned} -> {:skip, :task_reassigned}
      {:error, error} -> {:error, error}
    end
  end

  # A fixed reason and the job id: never the address.
  defp skip(%Oban.Job{id: id}, reason) do
    Logger.info("task mail job #{id} not sent: #{reason}")
    :ok
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
    # authorize?: false — a content read, kept as a bypass under the #1402
    # content-read argument — a standing system grant on content would hand
    # system code the whole corpus, drafts included, for one block's type. The
    # projection above is why it is safe: ids and types, no field values.
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
  rescue
    # An unknown `content_type` raises — see `content_title/3`.
    _unknown_type -> ""
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
    # authorize?: false — a content read (the #1402 content-read argument —
    # see `block_line/4`), selecting the title only, for a recipient the task
    # already decided.
    case ContentTypes.get_record(content_type, content_id,
           authorize?: false,
           tenant: org_id,
           query: [select: [:id, :title]]
         ) do
      {:ok, record} -> record.title
      _ -> content_type
    end
  rescue
    # `ContentTypes.get_record/3` *raises* for a `content_type` the registry
    # does not know (a dynamic type since deleted, say). Uncaught, the job
    # retries until discarded and the assignee never gets the mail.
    _unknown_type -> content_type
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

  # `?comment=<block_id>` is the editor's existing landing param (the shared
  # preview's pins already use it), so a block task's email opens the same
  # drawer a pin does rather than needing a second deep-link vocabulary. Owned
  # by `KilnCMS.Notifications.Link` since #1320, so this email, the workflow
  # email and the in-app inbox row all resolve to the same URL.
  defp editor_url(kind, id, block_id \\ nil), do: Link.editor_url(kind, id, block_id)
end
