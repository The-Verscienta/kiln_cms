defmodule KilnCMSWeb.FormLive do
  @moduledoc """
  The form builder (`/editor/forms`, admin-only like webhooks): create public
  forms, manage their typed fields, and review submissions. Public rendering
  happens through the `:form` content block; submissions arrive via
  `POST /forms/:slug` (see `KilnCMS.Forms`).
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FormField

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if actor.role == :admin do
      {:ok,
       socket
       |> assign(:actor, actor)
       |> assign(:page_title, gettext("Forms"))
       |> assign(:field_types, FormField.field_types())
       |> assign(:selected, nil)
       |> load_forms()}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You need admin access to view that page."))
       |> push_navigate(to: ~p"/")}
    end
  end

  # --- forms -------------------------------------------------------------------

  @impl true
  def handle_event("create_form", %{"form" => params}, socket) do
    case CMS.create_form(params, actor: socket.assigns.actor) do
      {:ok, form} ->
        {:noreply,
         socket
         |> load_forms()
         |> assign_selected(form.id)
         |> put_flash(:info, gettext("Form created — add its fields below."))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("select_form", %{"id" => id}, socket) do
    {:noreply, assign_selected(socket, id)}
  end

  def handle_event("close_form", _params, socket) do
    {:noreply, assign(socket, :selected, nil)}
  end

  def handle_event("save_form", %{"form" => params}, socket) do
    case CMS.update_form(socket.assigns.selected.form, params, actor: socket.assigns.actor) do
      {:ok, form} ->
        {:noreply,
         socket
         |> load_forms()
         |> assign_selected(form.id)
         |> put_flash(:info, gettext("Saved."))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("delete_form", %{"id" => id}, socket) do
    actor = socket.assigns.actor

    with {:ok, form} <- CMS.get_form(id, actor: actor),
         :ok <- CMS.destroy_form(form, actor: actor) do
      {:noreply,
       socket
       |> assign(:selected, nil)
       |> load_forms()
       |> put_flash(:info, gettext("Form deleted."))}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Couldn't delete that form."))}
    end
  end

  # --- fields ------------------------------------------------------------------

  def handle_event("add_field", %{"field" => params}, socket) do
    params = Map.put(params, "form_id", socket.assigns.selected.form.id)

    case CMS.create_form_field(normalize_field(params), actor: socket.assigns.actor) do
      {:ok, _field} ->
        {:noreply, socket |> assign_selected(socket.assigns.selected.form.id)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("delete_field", %{"id" => id}, socket) do
    actor = socket.assigns.actor
    field = Enum.find(socket.assigns.selected.fields, &(&1.id == id))

    if field, do: CMS.destroy_form_field(field, actor: actor)
    {:noreply, assign_selected(socket, socket.assigns.selected.form.id)}
  end

  # --- submissions ---------------------------------------------------------------

  def handle_event("delete_submission", %{"id" => id}, socket) do
    actor = socket.assigns.actor

    with {:ok, submission} <- CMS.get_form_submission(id, actor: actor) do
      CMS.destroy_form_submission(submission, actor: actor)
    end

    {:noreply, assign_selected(socket, socket.assigns.selected.form.id)}
  end

  # --- data --------------------------------------------------------------------

  defp load_forms(socket) do
    assign(
      socket,
      :forms,
      CMS.list_forms!(
        actor: socket.assigns.actor,
        load: [:submission_count],
        query: [sort: [inserted_at: :asc]]
      )
    )
  end

  defp assign_selected(socket, id) do
    actor = socket.assigns.actor
    form = CMS.get_form!(id, actor: actor)

    assign(socket, :selected, %{
      form: form,
      fields: CMS.form_fields_for!(form.id, actor: actor),
      submissions: CMS.recent_form_submissions!(form.id, actor: actor)
    })
  end

  # Select options arrive newline-separated, like the field-definition admin.
  defp normalize_field(params) do
    options =
      params
      |> Map.get("options", "")
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Map.put(params, "options", options)
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
    <Layouts.app flash={@flash} current_scope={@current_scope} current_user={@current_user}>
      <div class="space-y-8">
        <div>
          <.link navigate={~p"/editor"} class="text-sm text-base-content/60 hover:underline">
            &larr; {gettext("All content")}
          </.link>
          <h1 class="mt-1 text-2xl font-semibold">{gettext("Forms")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext(
              "Build public forms, place them on content with the form block, and review submissions here."
            )}
          </p>
        </div>

        <section class="space-y-3">
          <h2 class="text-lg font-medium">{gettext("Add a form")}</h2>
          <form
            phx-submit="create_form"
            class="grid gap-3 rounded-lg border border-base-content/15 p-4 sm:grid-cols-2"
          >
            <div>
              <label for="form-name" class="text-sm font-medium">{gettext("Name")}</label>
              <input
                id="form-name"
                name="form[name]"
                required
                class="mt-1 w-full rounded border border-base-content/20 bg-transparent px-3 py-1.5 text-sm"
              />
            </div>
            <div>
              <label for="form-slug" class="text-sm font-medium">{gettext("Slug")}</label>
              <input
                id="form-slug"
                name="form[slug]"
                required
                placeholder="contact"
                class="mt-1 w-full rounded border border-base-content/20 bg-transparent px-3 py-1.5 text-sm"
              />
            </div>
            <div class="sm:col-span-2">
              <.button type="submit" variant="primary">{gettext("Create form")}</.button>
            </div>
          </form>
        </section>

        <section class="space-y-3">
          <h2 class="text-lg font-medium">{gettext("Your forms")} ({length(@forms)})</h2>
          <p :if={@forms == []} class="text-sm text-base-content/60">{gettext("No forms yet.")}</p>
          <ul
            :if={@forms != []}
            class="divide-y divide-base-content/10 rounded-lg border border-base-content/15"
          >
            <li :for={form <- @forms} class="flex items-center justify-between gap-3 p-3">
              <button
                type="button"
                phx-click="select_form"
                phx-value-id={form.id}
                class="min-w-0 flex-1 text-left hover:underline"
              >
                <span class="font-medium">{form.name}</span>
                <code class="ml-2 text-xs text-base-content/60">/forms/{form.slug}</code>
              </button>
              <span :if={!form.active} class="rounded bg-base-200 px-1.5 py-0.5 text-xs">
                {gettext("Inactive")}
              </span>
              <span class="text-xs text-base-content/60">
                {gettext("%{count} submissions", count: form.submission_count)}
              </span>
              <button
                type="button"
                phx-click="delete_form"
                phx-value-id={form.id}
                data-confirm={gettext("Delete this form and all its submissions?")}
                aria-label={gettext("Delete form")}
                class="rounded px-2 py-1 text-xs text-base-content/60 hover:bg-base-200 hover:text-error"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </li>
          </ul>
        </section>

        <section :if={@selected} class="space-y-6 rounded-lg border border-primary/30 p-4">
          <div class="flex items-start justify-between gap-3">
            <h2 class="text-lg font-medium">{@selected.form.name}</h2>
            <button
              type="button"
              phx-click="close_form"
              aria-label={gettext("Close")}
              class="text-base-content/70 hover:text-base-content"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </div>

          <form phx-submit="save_form" class="grid gap-3 sm:grid-cols-2">
            <div>
              <label class="text-sm font-medium">{gettext("Success message")}</label>
              <input
                name="form[success_message]"
                value={@selected.form.success_message}
                class="mt-1 w-full rounded border border-base-content/20 bg-transparent px-3 py-1.5 text-sm"
              />
            </div>
            <div>
              <label class="text-sm font-medium">{gettext("Notify email")}</label>
              <input
                name="form[notify_email]"
                value={@selected.form.notify_email}
                placeholder="team@example.com"
                class="mt-1 w-full rounded border border-base-content/20 bg-transparent px-3 py-1.5 text-sm"
              />
            </div>
            <label class="flex items-center gap-2 text-sm">
              <input type="hidden" name="form[active]" value="false" />
              <input
                type="checkbox"
                name="form[active]"
                value="true"
                checked={@selected.form.active}
                class="size-4 rounded border border-base-content/30 accent-primary"
              />
              {gettext("Active (accepting submissions)")}
            </label>
            <div>
              <.button type="submit" variant="primary">{gettext("Save")}</.button>
            </div>
          </form>

          <div>
            <h3 class="text-sm font-semibold uppercase tracking-wide text-base-content/70">
              {gettext("Fields")} ({length(@selected.fields)})
            </h3>
            <ul :if={@selected.fields != []} class="mt-2 space-y-1">
              <li
                :for={field <- @selected.fields}
                class="flex items-center justify-between gap-2 text-sm"
              >
                <span>
                  <span class="font-medium">{field.label}</span>
                  <code class="ml-1 text-xs text-base-content/60">{field.name}</code>
                  <span class="ml-1 text-xs uppercase text-base-content/50">{field.field_type}</span>
                  <span :if={field.required} class="ml-1 text-xs text-error">
                    {gettext("required")}
                  </span>
                </span>
                <button
                  type="button"
                  phx-click="delete_field"
                  phx-value-id={field.id}
                  aria-label={gettext("Delete field")}
                  class="rounded px-1.5 py-0.5 text-xs text-base-content/60 hover:bg-base-200 hover:text-error"
                >
                  <.icon name="hero-trash" class="size-3.5" />
                </button>
              </li>
            </ul>

            <form phx-submit="add_field" class="mt-3 grid gap-2 sm:grid-cols-5">
              <input
                name="field[label]"
                required
                placeholder={gettext("Label")}
                class="rounded border border-base-content/20 bg-transparent px-2 py-1 text-sm"
              />
              <input
                name="field[name]"
                required
                placeholder="machine_name"
                class="rounded border border-base-content/20 bg-transparent px-2 py-1 text-sm"
              />
              <select
                name="field[field_type]"
                class="rounded border border-base-content/20 bg-base-100 px-2 py-1 text-sm"
              >
                <option :for={type <- @field_types} value={type}>{type}</option>
              </select>
              <label class="flex items-center gap-1 text-xs">
                <input type="hidden" name="field[required]" value="false" />
                <input type="checkbox" name="field[required]" value="true" /> {gettext("required")}
              </label>
              <.button type="submit">{gettext("Add field")}</.button>
              <textarea
                name="field[options]"
                placeholder={gettext("Select options — one per line (select fields only)")}
                class="rounded border border-base-content/20 bg-transparent px-2 py-1 text-xs sm:col-span-5"
              ></textarea>
            </form>
          </div>

          <div>
            <h3 class="text-sm font-semibold uppercase tracking-wide text-base-content/70">
              {gettext("Recent submissions")} ({length(@selected.submissions)})
            </h3>
            <p :if={@selected.submissions == []} class="mt-1 text-sm text-base-content/60">
              {gettext("None yet.")}
            </p>
            <ul :if={@selected.submissions != []} class="mt-2 space-y-2">
              <li
                :for={submission <- @selected.submissions}
                class="rounded border border-base-content/10 p-2 text-sm"
              >
                <div class="flex items-center justify-between gap-2">
                  <time
                    id={"submission-#{submission.id}"}
                    phx-hook="LocalTime"
                    datetime={DateTime.to_iso8601(submission.inserted_at)}
                    class="text-xs text-base-content/60"
                  >
                    {Calendar.strftime(submission.inserted_at, "%Y-%m-%d %H:%M")} UTC
                  </time>
                  <button
                    type="button"
                    phx-click="delete_submission"
                    phx-value-id={submission.id}
                    data-confirm={gettext("Delete this submission?")}
                    aria-label={gettext("Delete submission")}
                    class="rounded px-1.5 py-0.5 text-xs text-base-content/60 hover:bg-base-200 hover:text-error"
                  >
                    <.icon name="hero-trash" class="size-3.5" />
                  </button>
                </div>
                <dl class="mt-1 grid gap-x-4 gap-y-0.5 sm:grid-cols-2">
                  <div :for={{key, value} <- submission.data} class="flex gap-2">
                    <dt class="font-medium">{key}</dt>
                    <dd class="min-w-0 break-words text-base-content/80">{to_string(value)}</dd>
                  </div>
                </dl>
              </li>
            </ul>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
