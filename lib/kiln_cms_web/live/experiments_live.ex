defmodule KilnCMSWeb.ExperimentsLive do
  @moduledoc """
  `/editor/experiments` (#982, #499 phase 2): every experiment on this site,
  and a form to create one against a document picked from the site's content —
  the same content-type + document pickers the funnel builder uses, rather
  than a uuid typed by hand.

  Admin-only, like the funnel and automation pages: `KilnCMS.Experiments`'
  write policy is `OrgAdmin`, and this sits in the `:admin_routes` live
  session so the router guard and the resource policy agree. Reads are
  `OrgEditor`, so the list itself would render for an editor, but there is
  nothing on it an editor may do.

  A new experiment is created as a **draft with a control variant** already in
  place — the control's patch is empty, and it exists as a row so results have
  something to compare against (see `KilnCMS.Experiments.Variant`). Everything
  after that — variants, start, results, conclude, promote — is
  `KilnCMSWeb.ExperimentLive`.

  The deployment switch (`config :kiln_cms, KilnCMS.Experiments, enabled: true`) is
  reported at the top rather than gating the page: an admin can author an
  experiment on a deployment that will not serve one yet, and needs to know
  that is why nothing runs.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Analytics
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Experiments
  alias KilnCMSWeb.ExperimentPhrases

  @max_content_options 500

  @impl true
  def mount(_params, _session, socket) do
    type_options = ContentTypes.options(socket.assigns.current_org)
    first_type = type_options |> List.first() |> then(&(&1 && elem(&1, 1)))

    {:ok,
     socket
     |> assign(:page_title, gettext("Experiments"))
     |> assign(:type_options, type_options)
     |> assign(:new_type, first_type)
     |> assign(:new_content_options, content_options(first_type, socket))
     |> assign(:new_goal, "form_submission")
     |> assign(:form_options, form_options(socket))
     |> assign(:funnel_options, funnel_options(socket))
     |> assign(:enabled?, Experiments.enabled?())
     |> assign(:sticky?, KilnCMS.Experiments.Sticky.enabled?())
     |> load_experiments()}
  end

  @impl true
  def handle_event("pick_type", %{"experiment" => %{"content_type" => type}}, socket)
      when is_binary(type) do
    {:noreply,
     socket
     |> assign(:new_type, type)
     |> assign(:new_content_options, content_options(type, socket))
     |> assign(:new_goal, socket.assigns.new_goal)}
  end

  def handle_event("pick_type", %{"experiment" => %{"goal" => goal}}, socket)
      when is_binary(goal) do
    {:noreply, assign(socket, :new_goal, goal)}
  end

  def handle_event("pick_type", _params, socket), do: {:noreply, socket}

  def handle_event("create", %{"experiment" => params}, socket) when is_map(params) do
    attrs = create_attrs(params)

    case Experiments.create_experiment(attrs, actor_opts(socket)) do
      {:ok, experiment} ->
        # The control, so the experiment can be started (RequireVariants) and
        # results have a baseline. Its patch is empty by definition.
        case Experiments.create_variant(
               %{
                 experiment_id: experiment.id,
                 name: gettext("Control"),
                 weight: 1,
                 control: true
               },
               actor_opts(socket)
             ) do
          {:ok, _control} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Experiment created. Add a variant, then start it."))
             |> push_navigate(to: ~p"/editor/experiments/#{experiment.id}")}

          {:error, error} ->
            {:noreply, put_flash(socket, :error, experiment_error(error))}
        end

      {:error, error} ->
        {:noreply, put_flash(socket, :error, experiment_error(error))}
    end
  end

  def handle_event("create", _params, socket),
    do: {:noreply, put_flash(socket, :error, gettext("Something went wrong."))}

  # `goal`-specific ids only travel for the goal picked; the others are cleared
  # so a form that was toggled between goals does not save a stale target.
  defp create_attrs(params) do
    goal = Map.get(params, "goal", "form_submission")

    base = %{
      name: Map.get(params, "name", ""),
      content_type: Map.get(params, "content_type"),
      document_id: Map.get(params, "document_id"),
      goal: goal
    }

    case goal do
      "form_submission" ->
        Map.put(base, :goal_form_id, blank_to_nil(params["goal_form_id"]))

      "funnel_completion" ->
        Map.put(base, :goal_funnel_id, blank_to_nil(params["goal_funnel_id"]))

      "content_view" ->
        base
        |> Map.put(:goal_content_type, blank_to_nil(params["goal_content_type"]))
        |> Map.put(:goal_document_id, blank_to_nil(params["goal_document_id"]))

      _other ->
        base
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp load_experiments(socket) do
    experiments =
      Experiments.list_experiments!(
        Keyword.put(actor_opts(socket), :query, load: [:variants], sort: [inserted_at: :desc])
      )

    # Only the name and the reason atom reach the socket, as the overview strip
    # does — never the struct with every variant's patch in a render loop.
    blocked =
      Map.new(Experiments.blocked(socket.assigns.current_org.id), fn {e, {r, _}} -> {e.id, r} end)

    socket
    |> assign(:experiments, experiments)
    |> assign(:blocked, blocked)
    |> assign(:titles, titles_for(experiments, socket))
  end

  # Document titles for the list, one read per content type used.
  defp titles_for(experiments, socket) do
    experiments
    |> Enum.group_by(& &1.content_type, & &1.document_id)
    |> Enum.flat_map(fn {type, ids} ->
      case ContentTypes.get(type, socket.assigns.current_org) do
        nil ->
          []

        ct ->
          ct
          |> ContentTypes.list!(
            actor: socket.assigns.current_user,
            tenant: socket.assigns.current_org,
            query: [select: [:id, :title], filter: [id: [in: Enum.uniq(ids)]]]
          )
          |> Enum.map(&{{type, &1.id}, &1.title})
      end
    end)
    |> Map.new()
  end

  defp content_options(nil, _socket), do: []

  defp content_options(type, socket) do
    case ContentTypes.get(type, socket.assigns.current_org) do
      nil ->
        []

      ct ->
        ct
        |> ContentTypes.list!(
          actor: socket.assigns.current_user,
          tenant: socket.assigns.current_org,
          query: [select: [:id, :title], sort: [title: :asc], limit: @max_content_options]
        )
        |> Enum.map(&{&1.title, &1.id})
    end
  end

  defp form_options(socket) do
    CMS.list_forms!(
      Keyword.put(actor_opts(socket), :query, select: [:id, :name], sort: [name: :asc])
    )
    |> Enum.map(&{&1.name, &1.id})
  end

  defp funnel_options(socket) do
    Analytics.list_funnels!(
      Keyword.put(actor_opts(socket), :query, select: [:id, :name], sort: [name: :asc])
    )
    |> Enum.map(&{&1.name, &1.id})
  rescue
    _ -> []
  end

  defp actor_opts(socket),
    do: [actor: socket.assigns.current_user, tenant: socket.assigns.current_org]

  # The generic `KilnCMSWeb.CoreComponents.ash_error_message/2` (#1080) covers
  # this write error-to-flash-sentence translation now; only the Forbidden
  # sentence is page-specific.
  defp experiment_error(error) do
    ash_error_message(error,
      forbidden: gettext("You don't have permission to change experiments on this site.")
    )
  end

  defp document_title(titles, experiment),
    do:
      Map.get(titles, {experiment.content_type, experiment.document_id}) || experiment.document_id

  defp experiment_badge(:draft), do: {gettext("Draft"), "badge-ghost"}
  defp experiment_badge(:running), do: {gettext("Running"), "badge-success"}
  defp experiment_badge(:concluded), do: {gettext("Concluded"), "badge-info"}
  defp experiment_badge(:archived), do: {gettext("Archived"), "badge-neutral"}
  defp experiment_badge(_other), do: {gettext("Unknown"), "badge-ghost"}

  defp goal_label(:form_submission), do: gettext("Form submission")
  defp goal_label(:content_view), do: gettext("Reaches a page")
  defp goal_label(:funnel_completion), do: gettext("Completes a funnel")
  defp goal_label(other), do: to_string(other)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:experiments}
    >
      <div class="space-y-8">
        <div>
          <h1 class="text-2xl font-semibold">{gettext("Experiments")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext(
              "Test a headline, an excerpt or a block against a variant, measure which converts, and promote the winner into the document."
            )}
          </p>
        </div>

        <div :if={not @enabled?} class="rounded-lg border border-warning/40 bg-warning/10 p-4 text-sm">
          <p class="font-medium">{gettext("Experiments are switched off on this deployment.")}</p>
          <p class="mt-1 text-base-content/70">
            {gettext(
              "You can author and start one, but no variant is served and nothing is measured until the operator turns experiments on."
            )}
          </p>
        </div>

        <section class="space-y-3">
          <h2 class="text-lg font-medium">{gettext("New experiment")}</h2>
          <form
            id="new-experiment"
            phx-change="pick_type"
            phx-submit="create"
            class="card card-pad grid gap-3 sm:grid-cols-2"
          >
            <div class="sm:col-span-2">
              <label for="experiment-name" class="text-sm font-medium">{gettext("Name")}</label>
              <input id="experiment-name" name="experiment[name]" required class="field-input mt-1" />
            </div>
            <div>
              <label for="experiment-type" class="text-sm font-medium">{gettext("Content type")}</label>
              <select id="experiment-type" name="experiment[content_type]" class="field-input mt-1">
                <option
                  :for={{label, type} <- @type_options}
                  value={type}
                  selected={type == @new_type}
                >
                  {label}
                </option>
              </select>
            </div>
            <div>
              <label for="experiment-document" class="text-sm font-medium">{gettext("Document")}</label>
              <select
                id="experiment-document"
                name="experiment[document_id]"
                class="field-input mt-1"
                required
              >
                <option value="">{gettext("Pick a document…")}</option>
                <option :for={{title, id} <- @new_content_options} value={id}>{title}</option>
              </select>
            </div>
            <div>
              <label for="experiment-goal" class="text-sm font-medium">{gettext(
                "Counts as a conversion"
              )}</label>
              <select id="experiment-goal" name="experiment[goal]" class="field-input mt-1">
                <option value="form_submission" selected={@new_goal == "form_submission"}>
                  {gettext("A form is submitted")}
                </option>
                <option value="content_view" selected={@new_goal == "content_view"}>
                  {gettext("A page is reached")}
                </option>
                <option value="funnel_completion" selected={@new_goal == "funnel_completion"}>
                  {gettext("A funnel is completed")}
                </option>
              </select>
              <p
                :if={@new_goal != "form_submission" and not @sticky?}
                class="mt-1 text-xs text-warning-ink"
              >
                {gettext(
                  "This goal converts on a later page, which needs sticky assignment — off on this deployment, so the experiment will not start."
                )}
              </p>
            </div>
            <div :if={@new_goal == "form_submission"}>
              <label for="experiment-goal-form" class="text-sm font-medium">{gettext("Goal form")}</label>
              <select
                id="experiment-goal-form"
                name="experiment[goal_form_id]"
                class="field-input mt-1"
              >
                <option value="">{gettext("Pick a form…")}</option>
                <option :for={{name, id} <- @form_options} value={id}>{name}</option>
              </select>
            </div>
            <div :if={@new_goal == "funnel_completion"}>
              <label for="experiment-goal-funnel" class="text-sm font-medium">{gettext("Goal funnel")}</label>
              <select
                id="experiment-goal-funnel"
                name="experiment[goal_funnel_id]"
                class="field-input mt-1"
              >
                <option value="">{gettext("Pick a funnel…")}</option>
                <option :for={{name, id} <- @funnel_options} value={id}>{name}</option>
              </select>
            </div>
            <div :if={@new_goal == "content_view"} class="grid gap-3 sm:col-span-2 sm:grid-cols-2">
              <div>
                <label for="experiment-goal-type" class="text-sm font-medium">{gettext(
                  "Goal content type"
                )}</label>
                <select
                  id="experiment-goal-type"
                  name="experiment[goal_content_type]"
                  class="field-input mt-1"
                >
                  <option :for={{label, type} <- @type_options} value={type}>{label}</option>
                </select>
              </div>
              <div>
                <label for="experiment-goal-document" class="text-sm font-medium">{gettext(
                  "Goal document id"
                )}</label>
                <input
                  id="experiment-goal-document"
                  name="experiment[goal_document_id]"
                  class="field-input mt-1 font-mono text-xs"
                  placeholder={gettext("the id of the page reaching which converts")}
                />
              </div>
            </div>
            <div class="sm:col-span-2">
              <.button type="submit" variant="primary">{gettext("Create experiment")}</.button>
            </div>
          </form>
        </section>

        <section class="space-y-3">
          <h2 class="text-lg font-medium">{gettext("Experiments")} ({length(@experiments)})</h2>
          <p :if={@experiments == []} class="text-sm text-base-content/60">
            {gettext("No experiments yet.")}
          </p>
          <ul :if={@experiments != []} class="card divide-y divide-base-content/10 overflow-hidden">
            <li
              :for={experiment <- @experiments}
              class="flex flex-wrap items-center justify-between gap-3 p-3"
            >
              <.link
                navigate={~p"/editor/experiments/#{experiment.id}"}
                class="min-w-0 flex-1 hover:underline"
              >
                <span class="font-medium">{experiment.name}</span>
                <span class="ml-2 text-xs text-base-content/60">
                  {document_title(@titles, experiment)} · {goal_label(experiment.goal)} · {ngettext(
                    "%{count} variant",
                    "%{count} variants",
                    length(experiment.variants)
                  )}
                </span>
                <p
                  :if={reason = Map.get(@blocked, experiment.id)}
                  class="mt-1 text-xs text-warning-ink"
                >
                  {gettext("Blocked — %{reason}", reason: ExperimentPhrases.blocked_headline(reason))}
                </p>
              </.link>
              <% {label, class} = experiment_badge(experiment.state) %>
              <span class={["badge badge-sm", class]}>{label}</span>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.console>
    """
  end
end
