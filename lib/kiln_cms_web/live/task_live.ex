defmodule KilnCMSWeb.TaskLive do
  @moduledoc """
  The editorial workload view (`/editor/tasks`, #501): "my tasks" by default,
  plus a team-wide view of who owns what — every editor can already read
  every org task (`KilnCMS.CMS.Task`'s read policy is editor-wide, same as
  comments), so no separate admin gate is needed here.

  Content titles are resolved live per task (`ContentTypes.get_record/3`),
  not denormalized onto the task — same reasoning as `Comment`/`Consent`'s
  soft-polymorphic content ref: a stored title would go stale the moment the
  content is renamed.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.TaskSettings

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Tasks"))
     |> assign(:view, :mine)
     |> assign(:is_admin, KilnCMSWeb.LiveUserAuth.effective_tier(socket) == :admin)
     |> load_site_default()
     |> load_tasks()}
  end

  defp load_site_default(socket),
    do:
      assign(
        socket,
        :auto_complete_default,
        TaskSettings.site_default(socket.assigns.current_org)
      )

  @impl true
  def handle_params(params, _uri, socket) do
    view = if params["view"] == "team", do: :team, else: :mine
    {:noreply, socket |> assign(:view, view) |> load_tasks()}
  end

  # The site default (#818). Editor-visible because the rows below say what
  # publishing will do to them, and that sentence is wrong if you cannot see the
  # setting — but only an admin can change it, enforced by the resource policy
  # rather than by this page. `/editor/links` draws the same line.
  @impl true
  def handle_event("set_auto_complete", %{"enabled" => enabled}, socket)
      when is_binary(enabled) do
    attrs = %{auto_complete_tasks_on_publish: enabled == "true"}

    case CMS.save_site_editorial_settings(attrs,
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, _settings} ->
        {:noreply, socket |> load_site_default() |> load_tasks()}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't change that setting."))}
    end
  end

  # A pushed payload is client-chosen, so the guard above must have somewhere to
  # fall (#764). `TaskLive` predates `KilnCMSWeb.MalformedEvent`'s catch-all and
  # has none of its own, so without this a `%{"enabled" => true}` push is a
  # FunctionClauseError that kills the view.
  def handle_event("set_auto_complete", _params, socket), do: {:noreply, socket}

  def handle_event("complete", %{"id" => id}, socket) when is_binary(id) do
    case Enum.find(all_tasks(socket), &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      task ->
        case CMS.complete_task(task, %{}, actor: socket.assigns.current_user) do
          {:ok, _task} ->
            {:noreply, load_tasks(socket)}

          {:error, _error} ->
            {:noreply, put_flash(socket, :error, gettext("Couldn't update that task."))}
        end
    end
  end

  defp all_tasks(%{assigns: %{view: :mine, my_tasks: tasks}}), do: tasks

  defp all_tasks(%{assigns: %{view: :team, team_tasks: groups}}),
    do: Enum.flat_map(groups, &elem(&1, 1))

  defp load_tasks(socket) do
    actor = socket.assigns.current_user
    org = socket.assigns.current_org

    case socket.assigns.view do
      :mine ->
        tasks =
          CMS.list_tasks_for_assignee!(actor.id, actor: actor, tenant: org)
          |> Enum.map(&with_title(&1, actor, org))

        assign(socket, :my_tasks, tasks)

      :team ->
        tasks =
          CMS.list_tasks!(actor: actor, tenant: org, query: [filter: [status: :open]])
          |> Ash.load!(:assignee, authorize?: false, tenant: org)
          |> Enum.map(&with_title(&1, actor, org))
          |> Enum.sort_by(&(&1.due_on || ~D[9999-12-31]), Date)
          |> Enum.group_by(&assignee_label/1)
          |> Enum.sort_by(&elem(&1, 0))

        assign(socket, :team_tasks, tasks)
    end
  end

  defp with_title(task, actor, org) do
    title =
      case ContentTypes.get_record(task.content_type, task.content_id,
             actor: actor,
             tenant: org,
             query: [select: [:id, :title]]
           ) do
        {:ok, record} -> record.title
        _ -> gettext("(content unavailable)")
      end

    Map.put(task, :content_title, title)
  end

  defp assignee_label(%{assignee: %{name: name}}) when is_binary(name) and name != "", do: name
  defp assignee_label(%{assignee: %{email: email}}), do: to_string(email)

  defp overdue?(%{due_on: due_on}), do: due_on != nil and Date.before?(due_on, Date.utc_today())

  # Asked through `TaskSettings.describe/2` rather than by reading the field, so
  # the precedence rule lives in exactly one module (#818).
  defp overrides_site?(task, site_default) do
    case TaskSettings.describe(task, site_default) do
      {^site_default, _source} -> false
      {_effective, :task} -> true
      {_effective, :site} -> false
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:tasks}
    >
      <div class="space-y-4">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h1 class="text-2xl font-semibold">{gettext("Tasks")}</h1>
          <div class="flex items-center gap-2">
            <.link
              patch={~p"/editor/tasks"}
              class={["btn btn-sm", @view == :mine && "btn-primary", @view != :mine && "btn-default"]}
            >
              {gettext("My tasks")}
            </.link>
            <.link
              patch={~p"/editor/tasks?view=team"}
              class={["btn btn-sm", @view == :team && "btn-primary", @view != :team && "btn-default"]}
            >
              {gettext("Team workload")}
            </.link>
          </div>
        </div>

        <%!-- The site default (#818). Stated for every editor, changeable by an
              admin — a task row's "stays open after publish" only makes sense
              next to what the default is. --%>
        <div class="card card-pad flex flex-wrap items-center justify-between gap-3">
          <div>
            <p class="text-sm font-medium">
              {gettext("Publishing completes open tasks")}
            </p>
            <p class="text-xs text-base-content/60">
              {if @auto_complete_default,
                do:
                  gettext(
                    "Open tasks on a piece of content are marked done when it publishes. Individual tasks can opt out."
                  ),
                else:
                  gettext(
                    "Open tasks stay open when their content publishes. Individual tasks can opt in."
                  )}
            </p>
          </div>
          <button
            :if={@is_admin}
            type="button"
            phx-click="set_auto_complete"
            phx-value-enabled={to_string(!@auto_complete_default)}
            class="btn btn-sm btn-default"
          >
            {if @auto_complete_default, do: gettext("Turn off"), else: gettext("Turn on")}
          </button>
        </div>

        <div :if={@view == :mine} class="card divide-y divide-base-content/10">
          <p :if={@my_tasks == []} class="p-4 text-sm text-base-content/60">
            {gettext("No open tasks assigned to you.")}
          </p>
          <.task_row
            :for={task <- @my_tasks}
            task={task}
            auto_complete_default={@auto_complete_default}
          />
        </div>

        <div :if={@view == :team} class="space-y-4">
          <p :if={@team_tasks == []} class="text-sm text-base-content/60">
            {gettext("No open tasks.")}
          </p>
          <div :for={{assignee, tasks} <- @team_tasks} class="card">
            <div class="border-b border-base-content/10 px-4 py-2 text-sm font-semibold">
              {assignee} <span class="text-base-content/50">({length(tasks)})</span>
            </div>
            <div class="divide-y divide-base-content/10">
              <.task_row
                :for={task <- tasks}
                task={task}
                auto_complete_default={@auto_complete_default}
              />
            </div>
          </div>
        </div>
      </div>
    </Layouts.console>
    """
  end

  attr :task, :map, required: true
  attr :auto_complete_default, :boolean, required: true

  defp task_row(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-x-3 gap-y-1 p-3 text-sm">
      <div class="min-w-0 flex-1">
        <.link
          navigate={~p"/editor/content/#{@task.content_type}/#{@task.content_id}"}
          class="font-medium hover:underline"
        >
          {@task.content_title}
        </.link>
        <p :if={@task.note} class="truncate text-xs text-base-content/60">{@task.note}</p>
        <%!-- Only when this task DISAGREES with the site (#818). The banner
              above states the site rule; repeating it on every row would be
              noise, but leaving a task that contradicts it unlabelled would
              make the banner wrong for the row directly beneath it. --%>
        <p :if={overrides_site?(@task, @auto_complete_default)} class="text-xs text-base-content/60">
          {if @task.auto_complete_on_publish,
            do: gettext("Completes when its content publishes"),
            else: gettext("Stays open when its content publishes")}
        </p>
      </div>
      <span :if={@task.due_on} class={["text-xs", overdue?(@task) && "font-semibold text-error"]}>
        {if overdue?(@task), do: gettext("Overdue"), else: gettext("Due")} {Date.to_iso8601(
          @task.due_on
        )}
      </span>
      <button
        type="button"
        phx-click="complete"
        phx-value-id={@task.id}
        class="btn btn-sm btn-default"
      >
        {gettext("Mark done")}
      </button>
    </div>
    """
  end
end
