defmodule KilnCMSWeb.FunnelBuilderLive do
  @moduledoc """
  The funnel builder (`/editor/funnels/:id`, admin-only): funnel-level
  settings (name, slug, active) and its ordered content steps — add a step by
  picking a content type then a record of that type, reorder by drag (the
  shared `Sortable` hook persists `position`, same mechanism as
  `KilnCMSWeb.FormBuilderLive`), remove a step. The report itself (#622) is
  read-only and lives on the analytics dashboard editors already use.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Analytics
  alias KilnCMS.Analytics.FunnelStep
  alias KilnCMS.Analytics.Titles
  alias KilnCMS.CMS.ContentTypes

  # Same window cap as the content editor's own reference-field picker
  # (`ContentEditorLive.reference_options/3`) — a large library can't blow up
  # the mount or the type-change reload.
  @max_content_options 500

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    actor = socket.assigns.current_user

    with :admin <- KilnCMSWeb.LiveUserAuth.effective_tier(socket),
         {:ok, funnel} <-
           Analytics.get_funnel(id, actor: actor, tenant: socket.assigns.current_org) do
      type_options = type_options(org_id(socket.assigns.current_org))
      first_type = type_options |> List.first() |> then(&(&1 && elem(&1, 1)))

      {:ok,
       socket
       |> assign(:actor, actor)
       |> assign(:funnel, funnel)
       |> assign(:page_title, funnel.name)
       |> assign(:type_options, type_options)
       |> assign(:step_type, first_type)
       |> assign(:step_content_options, content_options(first_type, socket, actor))
       |> reload_steps()}
    else
      {:error, _error} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("That funnel doesn't exist."))
         |> push_navigate(to: ~p"/editor/funnels")}

      _tier ->
        {:ok,
         socket
         |> put_flash(:error, gettext("You need admin access to view that page."))
         |> push_navigate(to: ~p"/")}
    end
  end

  # --- settings ------------------------------------------------------------------

  @impl true
  def handle_event("save_funnel", %{"funnel" => params}, socket) do
    case Analytics.update_funnel(socket.assigns.funnel, params, actor_opts(socket)) do
      {:ok, funnel} ->
        {:noreply,
         socket
         |> assign(:funnel, funnel)
         |> assign(:page_title, funnel.name)
         |> put_flash(:info, gettext("Saved."))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  # --- steps -----------------------------------------------------------------

  def handle_event("pick_step_type", %{"type" => type}, socket) do
    {:noreply,
     socket
     |> assign(:step_type, type)
     |> assign(:step_content_options, content_options(type, socket, socket.assigns.actor))}
  end

  # `pick_step_type` and `add_step` are two separate round trips sharing one
  # form: a type switch that hasn't repainted `#step-content` yet could still
  # submit the PREVIOUS type's selected id against the NEW `step_type`. Since
  # `content_type`/`content_id` are FK-less (no DB constraint catches a
  # mismatched pair), re-checking the id actually belongs to `step_type` here
  # is the only guard — an undetected mismatch would silently resolve to
  # "(deleted)" forever (`Titles.title_for/3`) rather than erroring.
  def handle_event("add_step", %{"content_id" => content_id}, socket) when content_id != "" do
    type = socket.assigns.step_type

    case ContentTypes.get_record(type, content_id, actor_opts(socket)) do
      {:ok, _record} ->
        attrs = %{
          funnel_id: socket.assigns.funnel.id,
          content_type: type,
          content_id: content_id,
          position: next_position(socket.assigns.steps)
        }

        case Analytics.create_funnel_step(attrs, actor_opts(socket)) do
          {:ok, _step} -> {:noreply, reload_steps(socket)}
          {:error, error} -> {:noreply, put_flash(socket, :error, error_message(error))}
        end

      {:error, _error} ->
        {:noreply,
         put_flash(socket, :error, gettext("That item is no longer available — pick again."))}
    end
  end

  def handle_event("add_step", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Pick a content item first."))}
  end

  def handle_event("remove_step", %{"id" => id}, socket) do
    with %FunnelStep{} = step <- Enum.find(socket.assigns.steps, &(&1.id == id)) do
      Analytics.destroy_funnel_step(step, actor_opts(socket))
    end

    {:noreply, reload_steps(socket)}
  end

  # Pushed by the Sortable hook with the canvas' new data-sort-id order.
  def handle_event("reorder", %{"order" => order}, socket) when is_list(order) do
    {:noreply, socket |> apply_order(order) |> reload_steps()}
  end

  # --- data --------------------------------------------------------------------

  defp actor_opts(socket),
    do: [actor: socket.assigns.actor, tenant: socket.assigns.current_org]

  defp reload_steps(socket) do
    opts = actor_opts(socket)
    steps = Analytics.funnel_steps_for!(socket.assigns.funnel.id, opts)
    titles = Titles.resolve(steps, socket.assigns.current_org, socket.assigns.actor)

    socket
    |> assign(:steps, steps)
    |> assign(:titles, titles)
  end

  # Persist a full id ordering as 0-based positions, skipping no-op updates.
  defp apply_order(socket, order) do
    steps_by_id = Map.new(socket.assigns.steps, &{&1.id, &1})
    opts = actor_opts(socket)

    order
    |> Enum.with_index()
    |> Enum.each(fn {id, index} ->
      with %FunnelStep{} = step <- steps_by_id[id],
           true <- step.position != index do
        Analytics.update_funnel_step(step, %{position: index}, opts)
      end
    end)

    socket
  end

  defp next_position([]), do: 0
  defp next_position(steps), do: Enum.max_by(steps, & &1.position).position + 1

  defp type_options(org_id) do
    (ContentTypes.all() ++ ContentTypes.dynamic_all(org_id))
    |> Enum.map(&{&1.label, to_string(&1.type)})
  end

  defp content_options(nil, _socket, _actor), do: []

  defp content_options(type, socket, actor) do
    case ContentTypes.get(type, org_id(socket.assigns.current_org)) do
      nil ->
        []

      ct ->
        ct
        |> ContentTypes.list!(
          actor: actor,
          tenant: socket.assigns.current_org,
          query: [select: [:id, :title], sort: [title: :asc], limit: @max_content_options]
        )
        |> Enum.map(&{&1.title, &1.id})
    end
  end

  defp org_id(%{id: id}), do: id
  defp org_id(id) when is_binary(id), do: id

  defp step_title(step, titles, org), do: Titles.title_for(step, titles, org)

  defp error_message(%{errors: errors}) when is_list(errors) and errors != [] do
    errors
    |> Enum.map_join("; ", fn
      %{field: field, message: message} when not is_nil(field) -> "#{field} #{message}"
      %{message: message} when is_binary(message) -> message
      other -> inspect(other)
    end)
  end

  defp error_message(_error), do: gettext("Something went wrong.")

  # --- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:funnels}
    >
      <div class="space-y-8">
        <div>
          <.link navigate={~p"/editor/funnels"} class="text-sm text-base-content/60 hover:underline">
            &larr; {gettext("Funnels")}
          </.link>
          <h1 class="mt-1 text-2xl font-semibold">{@funnel.name}</h1>
        </div>

        <section class="space-y-3">
          <h2 class="text-lg font-medium">{gettext("Settings")}</h2>
          <form
            phx-submit="save_funnel"
            class="card card-pad grid gap-3 sm:grid-cols-2"
          >
            <div>
              <label for="funnel-name" class="text-sm font-medium">{gettext("Name")}</label>
              <input
                id="funnel-name"
                name="funnel[name]"
                value={@funnel.name}
                required
                class="field-input mt-1"
              />
            </div>
            <div>
              <label for="funnel-slug" class="text-sm font-medium">{gettext("Slug")}</label>
              <input
                id="funnel-slug"
                name="funnel[slug]"
                value={@funnel.slug}
                required
                class="field-input mt-1"
              />
            </div>
            <label class="flex items-center gap-2 text-sm sm:col-span-2">
              <input type="hidden" name="funnel[active]" value="false" />
              <input type="checkbox" name="funnel[active]" value="true" checked={@funnel.active} />
              {gettext("Active")}
            </label>
            <div class="sm:col-span-2">
              <.button type="submit" variant="primary">{gettext("Save")}</.button>
            </div>
          </form>
        </section>

        <section class="space-y-3">
          <h2 class="text-lg font-medium">{gettext("Steps")}</h2>

          <p
            :if={@steps == []}
            class="rounded border border-dashed border-base-300 p-6 text-center text-sm text-base-content/60"
          >
            {gettext("No steps yet — add one below.")}
          </p>

          <ol
            :if={@steps != []}
            id="funnel-steps"
            phx-hook="Sortable"
            class="card divide-y divide-base-content/10 overflow-hidden"
          >
            <li
              :for={{step, index} <- Enum.with_index(@steps, 1)}
              data-sort-id={step.id}
              class="flex items-center justify-between gap-3 p-3"
            >
              <span class="flex min-w-0 items-center gap-3">
                <button
                  type="button"
                  data-drag-handle
                  aria-label={
                    gettext("Reorder step %{title}", title: step_title(step, @titles, @current_org))
                  }
                  class="cursor-grab p-1 text-base-content/60 hover:text-base-content"
                >
                  <.icon name="hero-arrows-up-down" class="size-4" />
                </button>
                <span class="text-sm font-medium text-base-content/50">{index}.</span>
                <span class="min-w-0 truncate">{step_title(step, @titles, @current_org)}</span>
              </span>
              <button
                type="button"
                phx-click="remove_step"
                phx-value-id={step.id}
                aria-label={
                  gettext("Remove step %{title}", title: step_title(step, @titles, @current_org))
                }
                class="btn btn-sm btn-ghost hover:text-error"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </li>
          </ol>

          <form phx-submit="add_step" class="card card-pad grid gap-3 sm:grid-cols-3">
            <div>
              <label for="step-type" class="text-sm font-medium">{gettext("Content type")}</label>
              <select
                id="step-type"
                name="type"
                phx-change="pick_step_type"
                class="field-input mt-1"
              >
                <option
                  :for={{label, type} <- @type_options}
                  value={type}
                  selected={type == @step_type}
                >
                  {label}
                </option>
              </select>
            </div>
            <div class="sm:col-span-2">
              <label for="step-content" class="text-sm font-medium">{gettext("Content item")}</label>
              <select id="step-content" name="content_id" class="field-input mt-1">
                <option value="">{gettext("Choose…")}</option>
                <option :for={{title, id} <- @step_content_options} value={id}>{title}</option>
              </select>
            </div>
            <div class="sm:col-span-3">
              <.button type="submit" variant="primary">{gettext("Add step")}</.button>
            </div>
          </form>
        </section>
      </div>
    </Layouts.console>
    """
  end
end
