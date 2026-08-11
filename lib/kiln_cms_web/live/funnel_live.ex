defmodule KilnCMSWeb.FunnelLive do
  @moduledoc """
  The funnels index (`/editor/funnels`, admin-only): create, list, and delete
  funnel definitions. Picking a funnel's ordered content steps happens in
  `KilnCMSWeb.FunnelBuilderLive` (`/editor/funnels/:id`). The report itself —
  each step's derived traffic and conversion — is #622, on the analytics
  dashboard editors already read.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Analytics

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if KilnCMSWeb.LiveUserAuth.effective_tier(socket) == :admin do
      {:ok,
       socket
       |> assign(:actor, actor)
       |> assign(:page_title, gettext("Funnels"))
       |> load_funnels()}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You need admin access to view that page."))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("create_funnel", %{"funnel" => params}, socket) when is_map(params) do
    case Analytics.create_funnel(params, actor_opts(socket)) do
      {:ok, funnel} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Funnel created — add its steps."))
         |> push_navigate(to: ~p"/editor/funnels/#{funnel.id}")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("delete_funnel", %{"id" => id}, socket) when is_binary(id) do
    opts = actor_opts(socket)

    with {:ok, funnel} <- Analytics.get_funnel(id, opts),
         :ok <- Analytics.destroy_funnel(funnel, opts) do
      {:noreply,
       socket
       |> load_funnels()
       |> put_flash(:info, gettext("Funnel deleted."))}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Couldn't delete that funnel."))}
    end
  end

  # --- data --------------------------------------------------------------------

  defp actor_opts(socket),
    do: [actor: socket.assigns.actor, tenant: socket.assigns.current_org]

  defp load_funnels(socket) do
    assign(
      socket,
      :funnels,
      Analytics.list_funnels!(
        actor: socket.assigns.actor,
        tenant: socket.assigns.current_org,
        load: [:steps],
        query: [sort: [inserted_at: :asc]]
      )
    )
  end

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
          <.link navigate={~p"/editor/analytics"} class="text-sm text-base-content/60 hover:underline">
            &larr; {gettext("Analytics")}
          </.link>
          <h1 class="mt-1 text-2xl font-semibold">{gettext("Funnels")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext(
              "Define an ordered list of content steps (landing → pricing → signup); the report derives each step's traffic from view counts already recorded."
            )}
          </p>
        </div>

        <section class="space-y-3">
          <h2 class="text-lg font-medium">{gettext("Add a funnel")}</h2>
          <form phx-submit="create_funnel" class="card card-pad grid gap-3 sm:grid-cols-2">
            <div>
              <label for="funnel-name" class="text-sm font-medium">{gettext("Name")}</label>
              <input id="funnel-name" name="funnel[name]" required class="field-input mt-1" />
            </div>
            <div>
              <label for="funnel-slug" class="text-sm font-medium">{gettext("Slug")}</label>
              <input
                id="funnel-slug"
                name="funnel[slug]"
                required
                placeholder="signup"
                class="field-input mt-1"
              />
            </div>
            <div class="sm:col-span-2">
              <.button type="submit" variant="primary">{gettext("Create funnel")}</.button>
            </div>
          </form>
        </section>

        <section class="space-y-3">
          <h2 class="text-lg font-medium">{gettext("Your funnels")} ({length(@funnels)})</h2>
          <p :if={@funnels == []} class="text-sm text-base-content/60">
            {gettext("No funnels yet.")}
          </p>
          <ul :if={@funnels != []} class="card divide-y divide-base-content/10 overflow-hidden">
            <li :for={funnel <- @funnels} class="flex items-center justify-between gap-3 p-3">
              <.link
                navigate={~p"/editor/funnels/#{funnel.id}"}
                class="min-w-0 flex-1 text-left hover:underline"
              >
                <span class="font-medium">{funnel.name}</span>
                <code class="ml-2 text-xs text-base-content/60">{funnel.slug}</code>
              </.link>
              <span :if={!funnel.active} class="rounded bg-base-200 px-1.5 py-0.5 text-xs">
                {gettext("Inactive")}
              </span>
              <span class="text-xs text-base-content/60">
                {gettext("%{count} steps", count: length(funnel.steps))}
              </span>
              <button
                type="button"
                phx-click="delete_funnel"
                phx-value-id={funnel.id}
                data-confirm={gettext("Delete this funnel?")}
                aria-label={gettext("Delete funnel")}
                class="btn btn-sm btn-ghost hover:text-error"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.console>
    """
  end
end
