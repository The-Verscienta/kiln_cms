defmodule KilnCMS.Notifications.WorkflowMailWorker do
  @moduledoc """
  Delivers a single content-workflow notification email.

  Enqueued by `KilnCMS.Notifications` (one job per recipient). Builds the
  Swoosh email for the event and delivers it via
  `KilnCMS.Mail.deliver_for_worker/2`: a permanent (5xx) reject of the message
  cancels the job; transient failures, and the relay refusing our AUTH, TLS or
  sender, raise and Oban retries on the same greylist-aware backoff as
  `KilnCMS.Mail.DeliveryWorker`.

  Subject/body are `Kiln.Tokens` patterns (#468) rather than hand-interpolated
  strings — `@templates` below is still the one place that owns the actual
  copy (there's no admin UI to edit these, only the plumbing to make one
  possible later), but every value that reaches the template goes through the
  same `[token]` substitution `KilnCMS.Slug.Pattern` uses for slugs. Two
  definition sets, not one: `plain_definitions/0` for the subject (a mail
  header, never HTML) and `html_definitions/0` for the body (individually
  escaped per value — matches the pre-#468 code's `h/1` calls exactly, and
  is why the body isn't escaped as one whole string: that would also escape
  the template's own `<p>`/`<a>` markup).

  ## Read back when it runs (#3019)

  The job carries ids: the recipient (`user_id`), the content (`kind`, `id`),
  the acting account (`actor_id`) and, for a comment event, the comment
  (`comment_id`). Everything the email says is read when the job runs, so a
  job that waited hours for a retry sends what is true then:

    * the recipient must still be one (`KilnCMS.Notifications.mail_recipient/2`):
      an account erased since, left with no address, or that has turned the
      event's preference off since, is sent nothing, and the mail goes to the
      address the account holds now;
    * the actor's name is the account's name now, and an actor erased since
      is "An editor" (or "A reviewer");
    * content deleted or trashed since, or a comment deleted since, sends
      nothing.

  A skip finishes the job (`:ok`, logged with the job id and the reason, no
  address), rather than cancelling it: `KilnCMS.Mail.recent_delivery_failures/1`
  lists cancelled mail jobs as delivery failures. A read that fails, including
  a refused one, fails the job, which retries (#1659).

  A job queued by the release before this one carries the address, title,
  actor name and excerpt themselves. It is delivered only while an account
  that existed when it was queued still holds that address and would still be
  sent it, and those keys are dropped from its row once it finishes
  (`KilnCMS.Jobs.PrivateArgs`).
  """
  use Oban.Worker, queue: :mail, max_attempts: 8
  use KilnCMSWeb, :verified_routes

  import Swoosh.Email

  require Logger

  alias Kiln.Tokens
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Jobs.PrivateArgs
  alias KilnCMS.Mail
  alias KilnCMS.Notifications
  alias KilnCMS.Notifications.Link

  @templates %{
    "submitted_for_review" => %{
      subject: "Review requested: [title]",
      body: """
      <p>[actor-name] submitted the [kind] <strong>[title]</strong> for review.</p>
      <p><a href="[url]">Open it in the editor</a> to review and publish.</p>
      """
    },
    "published" => %{
      subject: "Published: [title]",
      body: """
      <p>Your [kind] <strong>[title]</strong> is now live.</p>
      <p><a href="[url]">View it in the editor</a>.</p>
      """
    },
    "returned_to_draft" => %{
      subject: "Changes requested: [title]",
      body: """
      <p>[actor-name] requested changes on your [kind] <strong>[title]</strong>.</p>
      <p>It has been moved back to draft so you can revise and resubmit.</p>
      <p><a href="[url]">Open it in the editor</a>.</p>
      """
    },
    # Editorial comments (#801). `[url]` carries `?comment=<block_id>`, so the
    # link lands on the thread rather than on the document — the same deep link
    # the shared preview's pins use (#802).
    "comment_added" => %{
      subject: "New comment on [title]",
      body: """
      <p>[actor-name] commented on the [kind] <strong>[title]</strong>:</p>
      <blockquote>[excerpt]</blockquote>
      <p><a href="[url]">Open the thread in the editor</a>.</p>
      """
    },
    "comment_resolved" => %{
      subject: "Comment resolved on [title]",
      body: """
      <p>[actor-name] marked a comment thread resolved on the [kind]
      <strong>[title]</strong>:</p>
      <blockquote>[excerpt]</blockquote>
      <p><a href="[url]">Open it in the editor</a> if it needs reopening.</p>
      """
    },
    "comment_mention" => %{
      subject: "[actor-name] mentioned you on [title]",
      body: """
      <p>[actor-name] mentioned you in a comment on the [kind]
      <strong>[title]</strong>:</p>
      <blockquote>[excerpt]</blockquote>
      <p><a href="[url]">Open the thread in the editor</a>.</p>
      """
    }
  }

  @doc "The event names this worker has a template for."
  @spec events() :: [String.t()]
  def events, do: Map.keys(@templates)

  @comment_events ~w(comment_added comment_resolved comment_mention)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "event" => event} = args} = job)
      when is_binary(user_id) do
    tenant = args["org_id"]

    with {:ok, preference} <- preference(event),
         {:ok, user} <- Notifications.mail_recipient(user_id, preference),
         {:ok, title} <- content_title(args["kind"], args["id"], tenant),
         {:ok, excerpt} <- excerpt(event, args["comment_id"], tenant) do
      args
      |> Map.merge(%{
        "to" => to_string(user.email),
        "title" => title,
        "actor_name" => Notifications.actor_name_now(args["actor_id"]),
        "excerpt" => excerpt
      })
      |> deliver(job)
    else
      {:skip, reason} -> skip(job, reason)
      {:error, error} -> {:error, error}
    end
  end

  # Queued by the release before #3019, with the address, title, actor name
  # and excerpt in the args. Remove no earlier than the release after this
  # one: the Pruner deletes finished rows after a week, and a retrying mail
  # job is done within a day.
  def perform(%Oban.Job{args: %{"to" => to, "title" => _title} = args} = job)
      when is_binary(to) do
    PrivateArgs.finishing(job, PrivateArgs.keys(__MODULE__), fn ->
      with {:ok, preference} <- preference(args["event"]),
           {:ok, _user} <-
             Notifications.mail_recipient_by_address(to, job.inserted_at, preference) do
        deliver(args, job)
      else
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

  defp deliver(args, %Oban.Job{id: id}) do
    args
    |> build_email()
    # This worker builds its email at perform time (not via Mail.enqueue!), so
    # stamp a domain-correct Message-ID here too — keyed on the job id so all
    # retries of this job carry the *same* ID rather than a fresh one each
    # attempt (and so gen_smtp doesn't fill in one from the container hostname).
    |> Mail.ensure_message_id("workflow-#{id}")
    # Through the site's own relay when it has one (#1322). Jobs queued before
    # `org_id` was in the args carry none and use the operator's relay, as
    # they would have.
    |> Mail.deliver_for_worker(org_id: args["org_id"])
  end

  # The preference that governs each event's mail — the one `dispatch/3` and
  # `dispatch_comment/4` consulted when the job was queued. Explicit clauses:
  # the event comes from a job row, and is never turned into an atom.
  defp preference("submitted_for_review"), do: {:ok, :submitted_for_review}
  defp preference("published"), do: {:ok, :published}
  defp preference("returned_to_draft"), do: {:ok, :returned_to_draft}
  defp preference(event) when event in @comment_events, do: {:ok, :comment}
  defp preference(_unknown), do: {:skip, :unknown_event}

  # The content's title now. Gone (deleted, trashed, or of a type that no
  # longer exists) is a skip: there is nothing left to link to.
  defp content_title(kind, id, tenant) do
    # authorize?: false — a content read (the #1402 content-read argument, as
    # `TaskMailWorker` reads titles): a standing system grant on content would
    # hand the notifier the whole corpus, drafts included, for one title. The
    # job already decided the recipient; only the title is selected.
    case ContentTypes.get_record(kind, id,
           authorize?: false,
           not_found_error?: false,
           tenant: tenant,
           query: [select: [:id, :title]]
         ) do
      {:ok, %{title: title}} -> {:ok, title}
      {:ok, nil} -> {:skip, :content_gone}
      {:error, :unknown_content_type} -> {:skip, :content_gone}
      {:error, error} -> {:error, error}
    end
  rescue
    # `ContentTypes.get_record/3` raises for a type the registry cannot
    # resolve to a resource (see `TaskMailWorker.content_title/3`).
    _unknown_type -> {:skip, :content_gone}
  end

  # The comment's excerpt now, read as the notifier's system actor, which
  # `CMS.Comment` admits for reads (#1659). `authorize_with: :error`: a refused
  # read must fail the job, not read as "comment deleted".
  defp excerpt(event, comment_id, tenant)
       when event in @comment_events and is_binary(comment_id) do
    case CMS.get_comment(comment_id,
           actor: Notifications.system(),
           authorize_with: :error,
           not_found_error?: false,
           tenant: tenant
         ) do
      {:ok, nil} -> {:skip, :comment_gone}
      {:ok, comment} -> {:ok, Notifications.snippet(comment.body)}
      {:error, error} -> {:error, error}
    end
  end

  defp excerpt(event, _comment_id, _tenant) when event in @comment_events,
    do: {:skip, :comment_gone}

  defp excerpt(_event, _comment_id, _tenant), do: {:ok, nil}

  # A fixed reason and the job id: never the address.
  defp skip(%Oban.Job{id: id}, reason) do
    Logger.info("workflow mail job #{id} not sent: #{reason}")
    :ok
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: Mail.backoff_seconds(attempt)

  # Same per-attempt ceiling as DeliveryWorker (see `Mail.attempt_timeout/0`).
  @impl Oban.Worker
  def timeout(_job), do: Mail.attempt_timeout()

  defp build_email(
         %{"event" => event, "to" => to, "title" => title, "kind" => kind, "id" => id} = args
       ) do
    template = Map.fetch!(@templates, event)

    context = %{
      title: title,
      kind: kind,
      actor_display: actor_display(event, args["actor_name"]),
      excerpt: args["excerpt"] || "",
      url: editor_url(kind, id, args["block_id"])
    }

    base(to)
    |> subject(Tokens.expand(template.subject, plain_definitions(), context))
    |> html_body(Tokens.expand(template.body, html_definitions(), context))
  end

  # Fallback text is chosen per event, before it ever reaches token
  # substitution — [actor-name] itself doesn't know "submitter" from
  # "reviewer", it only ever interpolates whatever display string it's given.
  defp actor_display("submitted_for_review", who), do: submitter(who)
  defp actor_display("returned_to_draft", who), do: reviewer(who)
  # A comment always has a human behind it, but `name` is optional (#214 keeps
  # us from falling back to the email local-part), so this needs its own
  # neutral stand-in rather than rendering an empty subject line.
  defp actor_display(event, nil) when event in ~w(comment_added comment_resolved comment_mention),
    do: "An editor"

  defp actor_display(_event, who), do: who

  # Raw values — a mail header, never HTML. Still stripped of embedded
  # CR/LF: `title`/`actor_display` are author-supplied, and a raw line break
  # in a `subject/2` value would smuggle extra headers into the message
  # (same reasoning as `KilnCMS.Automation.RuleWorker`'s `:text` escape).
  defp plain_definitions do
    [
      %{match: "title", resolve: fn _token, ctx -> plain(ctx.title) end},
      %{match: "kind", resolve: fn _token, ctx -> plain(ctx.kind) end},
      %{match: "actor-name", resolve: fn _token, ctx -> plain(ctx.actor_display) end},
      %{match: "excerpt", resolve: fn _token, ctx -> plain(ctx.excerpt) end},
      %{match: "url", resolve: fn _token, ctx -> ctx.url end}
    ]
  end

  # Escaped per value (see moduledoc for why not the whole expanded body).
  # `url` is a server-generated verified route, not escaped — same as before.
  defp html_definitions do
    [
      %{match: "title", resolve: fn _token, ctx -> h(ctx.title) end},
      %{match: "kind", resolve: fn _token, ctx -> h(ctx.kind) end},
      %{match: "actor-name", resolve: fn _token, ctx -> h(ctx.actor_display) end},
      # A comment body is whatever an editor typed, so this is the one token
      # carrying free user input into the mail. It takes the same per-value
      # escape as every other — the reason the body is escaped per token rather
      # than as one string is exactly so a value cannot bring its own markup.
      %{match: "excerpt", resolve: fn _token, ctx -> h(ctx.excerpt) end},
      %{match: "url", resolve: fn _token, ctx -> ctx.url end}
    ]
  end

  defp base(to) do
    new()
    |> from(Application.fetch_env!(:kiln_cms, :email_from))
    |> to(to)
  end

  # HTML-escape any editor/importer-controlled value before it lands in the
  # email body. Titles and actor names are author-supplied (and copied verbatim
  # by a downstream importer), so interpolating them raw would inject markup
  # into a transactional email. `editor_url/3` values are server-generated
  # verified routes and don't need escaping.
  defp h(value) do
    value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

  defp plain(value), do: value |> to_string() |> String.replace(~r/[\r\n]+/, " ")

  defp submitter(nil), do: "An editor"
  defp submitter(who), do: who

  defp reviewer(nil), do: "A reviewer"
  defp reviewer(who), do: who

  # One deep-link vocabulary for every channel (#1320): `KilnCMS.Notifications.Link`
  # owns the page/post routes and the `?comment=<block_id>` thread anchor the
  # editor reads at mount, so the link in this email is the same link the
  # in-app inbox row resolves to. A comment notification therefore lands on
  # the THREAD, not just the document — the same param the shared preview's
  # pins use (#802).
  defp editor_url(kind, id, block_id), do: Link.editor_url(kind, id, block_id)
end
