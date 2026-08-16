defmodule KilnCMSWeb.BlockDiscussionComponents do
  @moduledoc """
  A block's discussion, rendered inside the block's own card in the editor:
  the thread (#404), the open tasks anchored to that block, who else is looking
  at it, and the composer that starts or continues the conversation.

  Lives outside `KilnCMSWeb.ContentEditorLive` because that module is already
  the largest in the codebase and this is the part of it a reviewer most needs
  to read whole. The LiveView keeps the state and the event handlers;
  everything here is a function of assigns.

  ## The pin says what's true, in one glance

  `discussion_pin/1` is the always-visible control. Its state is the answer to
  "does this block need me?", in priority order:

  | State | Means |
  |---|---|
  | unresolved | a thread is open on this block — the loudest state, warning-toned |
  | tasks | no open thread, but somebody owes work here |
  | resolved | there was a discussion and it's settled |
  | empty | nothing has ever been said about this block |

  A block with both an unresolved thread and open tasks shows unresolved: the
  discussion is the thing that hasn't been *decided*, and the task count still
  renders beside it, so nothing is hidden by the precedence.
  """
  use Phoenix.Component
  use Gettext, backend: KilnCMSWeb.Gettext

  import KilnCMSWeb.CoreComponents, only: [icon: 1]

  @doc """
  A block's thread, its open tasks, and the composer — collapsed to a single
  pin until opened.

  `comments` is the *whole document's* comment list, filtered here rather than
  per block by the caller: `RouteToBlockThread` guarantees every comment on a
  block belongs to one thread, so the filter is all the grouping there is.
  `tasks` is the same shape for open tasks.
  """
  attr :block_id, :string, required: true
  attr :comments, :list, required: true
  attr :tasks, :list, default: []
  attr :open?, :boolean, required: true
  attr :draft, :string, default: nil
  attr :suggestions, :list, default: []
  attr :viewers, :list, default: []
  attr :typing, :list, default: []
  attr :task_draft, :map, default: nil
  attr :assignable_users, :list, default: []
  attr :linkable_tasks, :list, default: []
  attr :auto_complete_default, :boolean, default: true
  attr :orphan?, :boolean, default: false

  def block_discussion(assigns) do
    thread = thread_for_block(assigns.comments, assigns.block_id)
    tasks = Enum.filter(assigns.tasks, &(&1.block_id == assigns.block_id))

    assigns =
      assigns
      |> assign(:thread, thread)
      |> assign(:block_tasks, tasks)
      |> assign(:state, pin_state(thread, tasks))

    ~H"""
    <div class="mt-2">
      <div class="flex items-center gap-2">
        <.discussion_pin
          block_id={@block_id}
          state={@state}
          open?={@open?}
          replies={length(@thread)}
          tasks={length(@block_tasks)}
        />
        <.block_viewers viewers={@viewers} />
      </div>

      <%!-- Escape closes the panel and returns focus to the pin that opened
            it (`comment_close` clears `@comment_block`, so the panel's
            elements go and the pin is what remains at that spot in the tab
            order). Bound on the panel rather than the window: the editor has
            no other Escape handler today, and a window-level one here would
            quietly claim the key for every future modal in this LiveView. --%>
      <div
        :if={@open?}
        id={"thread-#{@block_id}"}
        role="group"
        aria-label={gettext("Discussion on this block")}
        phx-keydown="comment_close"
        phx-key="Escape"
        class="mt-2 space-y-2 rounded border border-base-content/15 bg-base-200/40 p-2"
      >
        <%!-- The block this thread annotates is gone from the document. Nothing
              cascaded when it was deleted — the anchor is soft — so the
              discussion and its tasks are still here and still readable. Said
              plainly, because a thread about a paragraph nobody can find is
              otherwise just confusing. --%>
        <p
          :if={@orphan?}
          class="rounded bg-base-content/5 px-2 py-1 text-xs text-base-content/60"
        >
          {gettext("This block was removed. The discussion and its tasks are kept.")}
        </p>

        <div :if={@block_tasks != []} class="space-y-1">
          <div
            :for={task <- @block_tasks}
            class="flex items-start gap-1.5 rounded bg-info/10 px-2 py-1 text-xs"
          >
            <.icon name="hero-clipboard-document-check" class="mt-0.5 size-3.5 shrink-0" />
            <span>{task_label(task)}</span>
          </div>
        </div>

        <div :if={@thread == []} class="text-xs text-base-content/60">
          {gettext("No comments on this block yet.")}
          <span class="block text-base-content/50">
            {gettext("Type @ to bring someone in.")}
          </span>
        </div>

        <%!-- Announced politely so a screen-reader user hears a reply arrive
              from a collaborator without losing their place in the composer. --%>
        <div aria-live="polite" class="space-y-2">
          <div :for={comment <- @thread} class="rounded bg-base-100 p-2 text-xs">
            <div class="flex items-center justify-between gap-2 text-base-content/60">
              <span>{author_label(comment)}</span>
              <time datetime={DateTime.to_iso8601(comment.inserted_at)}>
                {Calendar.strftime(comment.inserted_at, "%b %-d, %H:%M")}
              </time>
            </div>
            <%!-- Rendered as a text node, never raw markup: a comment is
                  editor-typed prose, not HTML. --%>
            <p class="mt-1 break-words">{comment.body}</p>
            <button
              :if={is_nil(comment.thread_id)}
              type="button"
              phx-click={if comment.resolved_at, do: "comment_unresolve", else: "comment_resolve"}
              phx-value-id={comment.id}
              class="mt-1 text-base-content/60 underline hover:text-base-content"
            >
              {if comment.resolved_at,
                do: gettext("Reopen thread"),
                else: gettext("Resolve thread")}
            </button>
          </div>
        </div>

        <p :if={@typing != []} class="text-xs text-base-content/60">
          <span class="animate-pulse">{typing_label(@typing)}</span>
        </p>

        <.composer block_id={@block_id} draft={@draft} suggestions={@suggestions} />

        <.task_bridge
          block_id={@block_id}
          draft={@task_draft}
          assignable_users={@assignable_users}
          linkable_tasks={@linkable_tasks}
          auto_complete_default={@auto_complete_default}
        />
      </div>
    </div>
    """
  end

  attr :block_id, :string, required: true
  attr :draft, :map, default: nil
  attr :assignable_users, :list, required: true
  attr :linkable_tasks, :list, required: true
  attr :auto_complete_default, :boolean, required: true

  # Turning a discussion into accountable work, without leaving the block.
  #
  # Two affordances rather than one, because they answer different questions.
  # "Create" is the common case and comes seeded from the thread — assignee
  # from the first `@mention` the root comment resolves, note from its body,
  # due a week out — so the usual path is one click and a confirm. "Link
  # existing" is triage: a task somebody already filed against the whole
  # document turns out to be about *this* paragraph, and re-anchoring it is
  # better than filing a second one that says the same thing.
  #
  # Only tasks with no block of their own are offered for linking. Stealing one
  # already anchored elsewhere would silently empty another block's pin, which
  # is not what "link this task here" sounds like it does.
  #
  # No `<form>`, for the reason the composer above spells out: this sits inside
  # the editor's main content form, which cannot nest one.
  defp task_bridge(assigns) do
    ~H"""
    <div class="border-t border-base-content/10 pt-2">
      <div :if={is_nil(@draft)} class="flex flex-wrap items-center gap-2">
        <button
          type="button"
          phx-click="block_task_open"
          phx-value-bid={@block_id}
          class="btn btn-sm btn-default"
        >
          <.icon name="hero-clipboard-document-check" class="size-3.5" />
          {gettext("Create task")}
        </button>

        <div :if={@linkable_tasks != []} class="flex items-center gap-1">
          <label for={"link-task-#{@block_id}"} class="text-xs text-base-content/60">
            {gettext("Link existing")}
          </label>
          <select
            id={"link-task-#{@block_id}"}
            name="link_task_id"
            phx-change="block_task_link"
            class="field-input text-xs"
          >
            <option value="">{gettext("Choose a task…")}</option>
            <option :for={{label, id} <- @linkable_tasks} value={id}>{label}</option>
          </select>
        </div>
      </div>

      <div :if={@draft} class="space-y-2">
        <div>
          <label for={"task-assignee-#{@block_id}"} class="text-xs text-base-content/60">
            {gettext("Assignee")}
          </label>
          <select
            id={"task-assignee-#{@block_id}"}
            name="task_assignee_id"
            phx-change="block_task_draft"
            class="field-input text-xs"
          >
            <option value="">{gettext("Choose an editor…")}</option>
            <option
              :for={{label, id} <- @assignable_users}
              value={id}
              selected={@draft["assignee_id"] == id}
            >
              {label}
            </option>
          </select>
        </div>

        <div>
          <label for={"task-due-#{@block_id}"} class="text-xs text-base-content/60">
            {gettext("Due")}
          </label>
          <input
            id={"task-due-#{@block_id}"}
            type="date"
            name="task_due_on"
            value={@draft["due_on"]}
            phx-change="block_task_draft"
            class="field-input text-xs"
          />
        </div>

        <div>
          <label for={"task-note-#{@block_id}"} class="text-xs text-base-content/60">
            {gettext("Note")}
          </label>
          <textarea
            id={"task-note-#{@block_id}"}
            name="task_note"
            rows="2"
            phx-change="block_task_draft"
            phx-debounce="blur"
            class="field-input text-xs"
          >{@draft["note"]}</textarea>
        </div>

        <%!-- `nil` is a real third value here (#818), not an omission: it means
              "whatever the site is set to", which is the only way a task can
              follow a setting an admin changes later. --%>
        <div>
          <label for={"task-auto-#{@block_id}"} class="text-xs text-base-content/60">
            {gettext("On publish")}
          </label>
          <select
            id={"task-auto-#{@block_id}"}
            name="task_auto_complete"
            phx-change="block_task_draft"
            class="field-input text-xs"
          >
            <option value="" selected={@draft["auto_complete"] in [nil, ""]}>
              {if @auto_complete_default,
                do: gettext("Site default (completes it)"),
                else: gettext("Site default (leaves it open)")}
            </option>
            <option value="true" selected={@draft["auto_complete"] == "true"}>
              {gettext("Complete it")}
            </option>
            <option value="false" selected={@draft["auto_complete"] == "false"}>
              {gettext("Leave it open")}
            </option>
          </select>
        </div>

        <div class="flex items-center gap-2">
          <button
            type="button"
            phx-click="block_task_submit"
            phx-value-bid={@block_id}
            class="btn btn-sm btn-primary"
          >
            {gettext("Assign")}
          </button>
          <button
            type="button"
            phx-click="block_task_close"
            class="text-xs text-base-content/60 underline hover:text-base-content"
          >
            {gettext("Cancel")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :block_id, :string, required: true
  attr :state, :atom, required: true
  attr :open?, :boolean, required: true
  attr :replies, :integer, required: true
  attr :tasks, :integer, required: true

  @doc """
  The always-visible control on a block's card.

  The label carries the counts as words rather than leaving them to the icon
  colour alone — the pin is the one place a colour-blind or screen-reader user
  has to be able to tell "needs attention" from "settled".
  """
  def discussion_pin(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={if @open?, do: "comment_close", else: "comment_open"}
      phx-value-bid={@block_id}
      aria-expanded={to_string(@open?)}
      aria-controls={"thread-#{@block_id}"}
      aria-label={pin_aria_label(@state, @replies, @tasks)}
      data-block-discussion={to_string(@state)}
      class={[
        "inline-flex items-center gap-1 rounded border px-2 py-0.5 text-xs transition-colors duration-150 hover:bg-base-200",
        pin_class(@state)
      ]}
    >
      <.icon name={pin_icon(@state)} class="size-3.5" />
      {pin_label(@state, @replies)}
      <span :if={@tasks > 0} class="inline-flex items-center gap-0.5 text-info-ink">
        <.icon name="hero-clipboard-document-check" class="size-3" />
        {@tasks}
      </span>
    </button>
    """
  end

  attr :viewers, :list, required: true

  @doc """
  Stacked initials for the peers currently focused on this block.

  Advisory only — nothing here locks the block or gates an edit. It exists so
  two editors notice each other *before* both rewrite the same paragraph, which
  is cheaper than resolving it afterwards.
  """
  def block_viewers(assigns) do
    ~H"""
    <span :if={@viewers != []} class="flex items-center">
      <span
        :for={viewer <- Enum.take(@viewers, 2)}
        title={gettext("%{name} is on this block", name: viewer.name)}
        class="-ml-1.5 flex size-5 items-center justify-center rounded-full bg-base-content/70 text-[9px] font-semibold text-base-100 ring-2 ring-base-100 first:ml-0"
      >
        {initials(viewer.name)}
      </span>
      <span :if={length(@viewers) > 2} class="ml-1 text-[10px] text-base-content/60">
        +{length(@viewers) - 2}
      </span>
    </span>
    """
  end

  attr :block_id, :string, required: true
  attr :draft, :string, default: nil
  attr :suggestions, :list, default: []

  # No `<form>`: this sits inside the editor's main content form, which cannot
  # nest one. The textarea carries its own `phx-change` and the Send button
  # reads the synced assign rather than anything in its own click event — the
  # shape `assist_panel/1` and the old `comment_panel/1` both use.
  #
  # `phx-debounce` is left off deliberately, unlike those two: the mention
  # dropdown has to see the `@` the moment it is typed, and a blur-debounced
  # change event arrives long after the author has given up waiting.
  defp composer(assigns) do
    ~H"""
    <div class="relative">
      <textarea
        id={"composer-#{@block_id}"}
        name="comment_body"
        rows="2"
        phx-hook="MentionAutocomplete"
        data-block-id={@block_id}
        phx-change="comment_draft"
        aria-label={gettext("Write a comment")}
        placeholder={gettext("Write a comment…")}
        class="field-input text-xs"
      >{@draft}</textarea>

      <ul
        :if={@suggestions != []}
        role="listbox"
        aria-label={gettext("Mention a teammate")}
        class="absolute z-20 mt-1 max-h-48 w-full overflow-y-auto rounded-lg border border-base-content/15 bg-base-100 shadow-lg"
      >
        <li :for={suggestion <- @suggestions} role="option" aria-selected="false">
          <button
            type="button"
            phx-click="mention_pick"
            phx-value-handle={suggestion.handle}
            phx-value-bid={@block_id}
            class="flex w-full items-center gap-2 px-2 py-1.5 text-left text-xs hover:bg-base-200"
          >
            <span class="flex size-5 items-center justify-center rounded-full bg-base-content/70 text-[9px] font-semibold text-base-100">
              {initials(suggestion.name)}
            </span>
            <span class="min-w-0 flex-1 truncate">{suggestion.name}</span>
            <span class="text-base-content/50">@{suggestion.handle}</span>
            <%!-- Two people whose names normalise identically: the mention can
                  be written and read, but `Mentions.resolve/2` will refuse to
                  guess, so say so here rather than let the author assume it
                  landed. --%>
            <span :if={suggestion.ambiguous?} class="text-warning">
              {gettext("(won't notify)")}
            </span>
          </button>
        </li>
      </ul>

      <div class="mt-2 flex items-center gap-2">
        <button
          type="button"
          phx-click="comment_add"
          phx-value-bid={@block_id}
          class="btn btn-sm btn-default"
        >
          {gettext("Send")}
        </button>
        <button
          type="button"
          phx-click="comment_close"
          class="text-xs text-base-content/60 underline hover:text-base-content"
        >
          {gettext("Close")}
        </button>
      </div>
    </div>
    """
  end

  @doc """
  This block's thread, oldest first — the root followed by its replies.

  `RouteToBlockThread` guarantees every comment sharing a block id already
  belongs to the same one thread, so there is no grouping by `thread_id` to do
  here, and the caller's list is already `inserted_at`-sorted.
  """
  def thread_for_block(comments, block_id),
    do: Enum.filter(comments, &(&1.block_id == block_id))

  @doc """
  Whether a block's thread is resolved.

  An empty thread is not resolved — there is nothing to reopen. Otherwise it
  follows the root (`thread_id: nil`), which is the only comment that carries a
  resolved state at all.
  """
  def thread_resolved?([]), do: false

  def thread_resolved?(thread) do
    case Enum.find(thread, &is_nil(&1.thread_id)) do
      %{resolved_at: %DateTime{}} -> true
      _root_missing_or_open -> false
    end
  end

  @doc """
  Whether a block's thread is open — a root that nobody has resolved.

  Not the negation of `thread_resolved?/1`: a block with no comments is neither
  unresolved nor resolved, and the pin distinguishes the two.
  """
  def thread_unresolved?([]), do: false
  def thread_unresolved?(thread), do: not thread_resolved?(thread)

  @doc """
  A block's discussion state — `:unresolved`, `:tasks`, `:resolved` or
  `:empty` — from the document's whole comment and task lists.

  Public because the block *card* carries it too (`data-block-threads`), which
  is what the editor's "Unresolved" filter hides on. Computed here rather than
  duplicated there, so the filter and the pin cannot disagree about which
  blocks are unresolved.
  """
  @spec discussion_state([struct()], [struct()], String.t()) ::
          :unresolved | :tasks | :resolved | :empty
  def discussion_state(comments, tasks, block_id) do
    pin_state(
      thread_for_block(comments, block_id),
      Enum.filter(tasks, &(&1.block_id == block_id))
    )
  end

  # Unresolved outranks tasks: a task is work somebody has already accepted,
  # an open thread is a decision nobody has made.
  defp pin_state(thread, tasks) do
    cond do
      thread_unresolved?(thread) -> :unresolved
      tasks != [] -> :tasks
      thread != [] -> :resolved
      true -> :empty
    end
  end

  defp pin_class(:unresolved), do: "border-warning/40 bg-warning/10 text-warning-ink"
  defp pin_class(:tasks), do: "border-info/40 bg-info/10 text-info-ink"
  defp pin_class(:resolved), do: "border-base-content/20 text-base-content/50"
  defp pin_class(:empty), do: "border-base-content/20"

  defp pin_icon(:unresolved), do: "hero-chat-bubble-left-ellipsis"
  defp pin_icon(:tasks), do: "hero-clipboard-document-check"
  defp pin_icon(_settled_or_empty), do: "hero-chat-bubble-left-right"

  defp pin_label(:empty, _replies), do: gettext("Comment")

  defp pin_label(:resolved, replies),
    do: ngettext("%{count} comment · Resolved", "%{count} comments · Resolved", replies)

  defp pin_label(_state, 0), do: gettext("Comment")

  defp pin_label(_state, replies),
    do: ngettext("%{count} comment", "%{count} comments", replies)

  # Spelled out rather than assembled from the visual label, so what a screen
  # reader announces is a sentence and not "3 comments clipboard 2".
  #
  # Each arm is a whole sentence rather than fragments glued together: a
  # translator needs the sentence to reorder it, and "0 unresolved comments and
  # 1 open task" — which is what a generic assembly produces for a block whose
  # only content is a task — is a worse thing to hear than a longer table of
  # clauses is to read.
  defp pin_aria_label(:empty, _replies, 0), do: gettext("Start a discussion on this block")

  defp pin_aria_label(_state, 0, tasks) when tasks > 0,
    do: gettext("%{tasks} on this block", tasks: task_phrase(tasks))

  defp pin_aria_label(state, replies, 0),
    do: gettext("%{comments} on this block", comments: comment_phrase(state, replies))

  defp pin_aria_label(state, replies, tasks) do
    gettext("%{comments} and %{tasks} on this block",
      comments: comment_phrase(state, replies),
      tasks: task_phrase(tasks)
    )
  end

  defp comment_phrase(:resolved, count),
    do: ngettext("%{count} resolved comment", "%{count} resolved comments", count)

  defp comment_phrase(_open, count),
    do: ngettext("%{count} unresolved comment", "%{count} unresolved comments", count)

  defp task_phrase(count), do: ngettext("%{count} open task", "%{count} open tasks", count)

  defp task_label(%{assignee: %{name: name}} = task) when is_binary(name) and name != "",
    do: task_line(name, task)

  defp task_label(%{assignee: %{email: email}} = task) when not is_nil(email),
    do: task_line(to_string(email), task)

  defp task_label(task), do: task_line(gettext("Someone"), task)

  defp task_line(who, %{due_on: %Date{} = due} = task),
    do:
      gettext("%{who} — due %{date}%{note}",
        who: who,
        date: Calendar.strftime(due, "%b %-d"),
        note: note_suffix(task)
      )

  defp task_line(who, task), do: gettext("%{who}%{note}", who: who, note: note_suffix(task))

  defp note_suffix(%{note: note}) when is_binary(note) and note != "", do: " · " <> note
  defp note_suffix(_task), do: ""

  defp typing_label([name]), do: gettext("%{name} is typing…", name: name)

  defp typing_label(names),
    do: gettext("%{names} are typing…", names: Enum.join(names, ", "))

  defp author_label(%{author: %{name: name}}) when is_binary(name) and name != "", do: name
  defp author_label(%{author: %{email: email}}) when not is_nil(email), do: to_string(email)
  defp author_label(_comment), do: gettext("Someone")

  defp initials(name) when is_binary(name) do
    case name |> String.split(~r/\s+/, trim: true) |> Enum.take(2) do
      [] -> "?"
      words -> Enum.map_join(words, &(&1 |> String.first() |> String.upcase()))
    end
  end

  defp initials(_name), do: "?"
end
