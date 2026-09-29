defmodule KilnCMSWeb.AutomationLive.Preview do
  @moduledoc """
  "Try it on real content": what the rule being built would do if its event
  fired for a document the admin picks — the email it would send, the post it
  would make, the task it would create — without doing any of it.

  The effects come from `KilnCMS.Automation.RuleWorker.preview/4`, the same
  templating and defaults the real reaction runs, so the preview can't
  describe a rule differently from how it behaves. This module only finds a
  document to try, builds the event payload the job would carry, and hands
  both over.

  The document is read as the admin, with their permissions — the picker
  offers only what they could open in the editor anyway.
  """
  use KilnCMSWeb, :html

  require Logger

  alias KilnCMS.Automation.RuleWorker
  alias KilnCMS.CMS.ContentSerializer
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.HealthSweep

  @limit 12

  # Verbs that fire for editorial tasks, not documents (`task.assigned`) — a
  # document can't stand in for one.
  @task_triggers [:assigned, :overdue]

  @doc "Whether a rule on `trigger` can be previewed against a document."
  @spec previewable?(atom() | nil) :: boolean()
  def previewable?(trigger), do: trigger not in @task_triggers

  @doc """
  Recent documents to try a rule on, newest first, as `{label, value}` select
  options. Scoped to `content_type` when the rule is; `value` is what
  `load/3` takes back.
  """
  @spec candidates(struct(), struct(), String.t() | nil) :: [{String.t(), String.t()}]
  def candidates(actor, org, content_type) do
    org
    |> ContentTypes.all_for_org()
    |> Enum.filter(&(content_type in [nil, ""] or to_string(&1.type) == content_type))
    |> Enum.flat_map(fn ct ->
      ct
      |> ContentTypes.list!(
        actor: actor,
        tenant: org,
        query: [select: [:id, :title, :updated_at], sort: [updated_at: :desc], limit: @limit]
      )
      |> Enum.map(&{ct, &1})
    end)
    |> Enum.sort_by(fn {_ct, record} -> record.updated_at end, {:desc, DateTime})
    |> Enum.take(@limit)
    |> Enum.map(fn {ct, record} ->
      {"#{record.title || "Untitled"} — #{ct.label}", "#{ct.type}:#{record.id}"}
    end)
  end

  @doc """
  The document behind a `candidates/3` value, read as `actor`, as
  `{type, record}` — or `nil` for a value that doesn't resolve (a document
  deleted since the list loaded, one the actor can't read, a forged value).
  """
  @spec load(String.t(), struct(), struct()) :: {String.t(), struct()} | nil
  def load(value, actor, org) when is_binary(value) do
    with [type, id] <- String.split(value, ":", parts: 2),
         {:ok, _uuid} <- Ecto.UUID.cast(id),
         %{} <- ContentTypes.get(type, org),
         {:ok, record} <-
           ContentTypes.get_record(type, id,
             actor: actor,
             tenant: org,
             # What the social composer reads for a record's description
             # (#1102) — the same load the real reaction makes.
             load: KilnCMS.Seo.Patterns.loads()
           ) do
      {type, record}
    else
      _ -> nil
    end
  rescue
    # A type archived between listing and loading raises in the registry.
    _ -> nil
  end

  def load(_value, _actor, _org), do: nil

  @doc """
  The effects of `draft` (the builder's `%{trigger_event, action, config}`)
  firing for `record`, a document of `type`, on `org`.
  """
  @spec run(map(), String.t(), struct(), struct()) :: [RuleWorker.effect()]
  def run(draft, type, record, org) do
    event = "#{type}.#{draft.trigger_event}"
    payload = draft.trigger_event |> payload(record) |> Jason.encode!() |> Jason.decode!()

    RuleWorker.preview(
      %{action: draft.action, config: draft.config, org_id: KilnCMS.Accounts.org_id(org)},
      event,
      payload,
      record
    )
  rescue
    # A preview that raises must not take the admin's half-built rule down
    # with the LiveView; say it couldn't be previewed and log why.
    error ->
      Logger.warning(
        "Automation preview failed: " <> Exception.format(:error, error, __STACKTRACE__)
      )

      [{:skipped, :preview_failed}]
  end

  # The payload as the job would carry it, from the same builder the real event
  # uses — the health sweep's narrow map for a health event, the serialized
  # document (`NotifyWebhooks`' `:full`) for every editorial one — then through
  # JSON, so atoms are strings and dates ISO strings exactly as the worker sees
  # them. The difference matters: only the health payload names the author,
  # so `:create_task` on a publish really does have nobody to assign, and the
  # preview says so.
  defp payload(:health_overdue, record), do: HealthSweep.event_payload(record, :overdue)
  defp payload(:health_expired, record), do: HealthSweep.event_payload(record, :expired)
  defp payload(_editorial, record), do: ContentSerializer.to_map(record)

  # --- render ----------------------------------------------------------------

  attr :effects, :list, required: true
  attr :names, :map, required: true, doc: "as for `Wording.summary/2`"

  @doc "What the rule would do, one effect per row."
  def effects(assigns) do
    ~H"""
    <ul class="space-y-3">
      <li :for={effect <- @effects} class="text-sm">
        <.effect effect={effect} names={@names} />
      </li>
    </ul>
    """
  end

  attr :effect, :any, required: true
  attr :names, :map, required: true

  defp effect(%{effect: {:email, email}} = assigns) do
    assigns = assign(assigns, :email, email)

    ~H"""
    <p class="font-medium">
      {if @email.to,
        do: gettext("Email to %{to}", to: @email.to),
        else: gettext("Email — add an address under “Send to”")}
    </p>
    <p class="text-base-content/70">{gettext("Subject: %{subject}", subject: @email.subject)}</p>
    <%!-- The rendered body is HTML. A sandboxed frame shows it as the mail
         would look while keeping it — scripts, forms, links — out of the
         console. --%>
    <iframe
      sandbox=""
      srcdoc={@email.body_html}
      title={gettext("Email body preview")}
      class="mt-2 h-40 w-full rounded-md border border-base-content/15 bg-white"
    ></iframe>
    """
  end

  defp effect(%{effect: {:social, %{provider: nil}}} = assigns) do
    ~H"""
    <p>{gettext("Choose a network under “Post to” to see the post.")}</p>
    """
  end

  defp effect(%{effect: {:social, social}} = assigns) do
    assigns =
      assigns
      |> assign(:social, social)
      |> assign(:network, Phoenix.Naming.humanize(social.provider))

    ~H"""
    <p class="font-medium">
      {if @social.accounts == 0,
        do:
          gettext("No enabled %{network} account — nothing would be posted. It would read:",
            network: @network
          ),
        else:
          ngettext(
            "Post to %{count} %{network} account:",
            "Post to %{count} %{network} accounts:",
            @social.accounts,
            network: @network
          )}
    </p>
    <blockquote class="mt-1 whitespace-pre-line rounded-md border-l-2 border-base-content/20 bg-base-200/50 p-2">
      {@social.text}
    </blockquote>
    """
  end

  defp effect(%{effect: {:task, task}} = assigns) do
    assigns =
      assigns
      |> assign(:task, task)
      |> assign(
        :person,
        get_in(assigns.names, [:users, task.assignee_id]) || gettext("an editor")
      )

    ~H"""
    <p class="font-medium">
      {gettext("A task for %{person}, due %{date}",
        person: @person,
        date: Date.to_iso8601(@task.due_on)
      )}
    </p>
    <p class="text-base-content/70">{@task.note}</p>
    """
  end

  defp effect(%{effect: {:newsletter, newsletter}} = assigns) do
    assigns =
      assigns
      |> assign(:newsletter, newsletter)
      |> assign(:audience, audience(newsletter.segment_id, Map.get(assigns.names, :segments)))

    ~H"""
    <p class="font-medium">
      {gettext("Newsletter “%{subject}” to %{audience}",
        subject: @newsletter.subject,
        audience: @audience
      )}
    </p>
    """
  end

  defp effect(%{effect: {:broadcast, broadcast}} = assigns) do
    assigns = assign(assigns, :broadcast, broadcast)

    ~H"""
    <p>
      {gettext("Broadcast “%{event}” on the internal channel %{topic}.",
        event: @broadcast.event,
        topic: @broadcast.topic
      )}
    </p>
    """
  end

  defp effect(%{effect: {:invalidate_cache, _}} = assigns) do
    ~H"""
    <p>{gettext("Clear this page's cached copy, the sitemap and llms.txt.")}</p>
    """
  end

  defp effect(%{effect: {:reindex, _}} = assigns) do
    ~H"""
    <p>{gettext("Regenerate this page's published version.")}</p>
    """
  end

  defp effect(%{effect: {:analysis, _}} = assigns) do
    ~H"""
    <p>
      {gettext(
        "Run the analysis on this content and deliver what it finds. A preview doesn't run it: it costs what the real rule costs, and may send the page to an outside AI provider."
      )}
    </p>
    """
  end

  defp effect(%{effect: {:skipped, :preview_failed}} = assigns) do
    ~H"""
    <p>{gettext("This one couldn't be previewed. The rule itself is unaffected.")}</p>
    """
  end

  defp effect(%{effect: {:skipped, reason}} = assigns) do
    assigns = assign(assigns, :reason, skip_reason(reason))

    ~H"""
    <p class="font-medium">{gettext("Nothing would happen.")}</p>
    <p class="text-base-content/70">{@reason}</p>
    """
  end

  # Worded as `Wording.summary/2` words it: a missing `segment_id` means
  # everyone, but one that doesn't resolve is a deleted segment (the send is
  # refused) or pickers not loaded yet — neither is "all subscribers".
  defp audience(nil, _segments), do: gettext("all confirmed subscribers")

  defp audience(id, %{} = segments) when is_map_key(segments, id),
    do: Map.fetch!(segments, id)

  defp audience(_id, %{}), do: gettext("a segment that no longer exists")
  defp audience(_id, _segments), do: gettext("one segment")

  defp skip_reason(:non_default_locale),
    do: gettext("Newsletters follow the default-language version, and this is a translation.")

  defp skip_reason(:task_already_open),
    do: gettext("An open review task already covers this content.")

  defp skip_reason(:no_assignee),
    do:
      gettext(
        "Neither the author nor the fallback assignee is an editor, so nobody could hold the task."
      )

  defp skip_reason(_reason), do: nil
end
