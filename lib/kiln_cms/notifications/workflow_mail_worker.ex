defmodule KilnCMS.Notifications.WorkflowMailWorker do
  @moduledoc """
  Delivers a single content-workflow notification email.

  Enqueued by `KilnCMS.Notifications` (one job per recipient). Builds the
  Swoosh email for the event and delivers it via
  `KilnCMS.Mail.deliver_for_worker/2`: permanent (5xx) failures cancel the
  job, transient failures raise and Oban retries on the same greylist-aware
  backoff as `KilnCMS.Mail.DeliveryWorker`.

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
  """
  use Oban.Worker, queue: :mail, max_attempts: 8
  use KilnCMSWeb, :verified_routes

  import Swoosh.Email

  alias Kiln.Tokens
  alias KilnCMS.Mail

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
    }
  }

  @doc "The event names this worker has a template for."
  @spec events() :: [String.t()]
  def events, do: Map.keys(@templates)

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
      url: editor_url(kind, id)
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
  # by the Verscienta importer), so interpolating them raw would inject markup
  # into a transactional email. `editor_url/2` values are server-generated
  # verified routes and don't need escaping.
  defp h(value) do
    value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

  defp plain(value), do: value |> to_string() |> String.replace(~r/[\r\n]+/, " ")

  defp submitter(nil), do: "An editor"
  defp submitter(who), do: who

  defp reviewer(nil), do: "A reviewer"
  defp reviewer(who), do: who

  defp editor_url("page", id), do: url(~p"/editor/pages/#{id}")
  defp editor_url("post", id), do: url(~p"/editor/posts/#{id}")
  defp editor_url(kind, id), do: url(~p"/editor/content/#{kind}/#{id}")
end
