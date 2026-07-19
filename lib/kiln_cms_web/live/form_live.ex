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

    if KilnCMSWeb.LiveUserAuth.effective_tier(socket) == :admin do
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
    case CMS.create_form(params, actor: socket.assigns.actor, tenant: socket.assigns.current_org) do
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
    case CMS.update_form(socket.assigns.selected.form, params,
           actor: socket.assigns.actor,
           tenant: socket.assigns.current_org
         ) do
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
    org = socket.assigns.current_org

    with {:ok, form} <- CMS.get_form(id, actor: actor, tenant: org),
         :ok <- CMS.destroy_form(form, actor: actor, tenant: org) do
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

    case CMS.create_form_field(normalize_field(params),
           actor: socket.assigns.actor,
           tenant: socket.assigns.current_org
         ) do
      {:ok, _field} ->
        {:noreply, socket |> assign_selected(socket.assigns.selected.form.id)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("delete_field", %{"id" => id}, socket) do
    actor = socket.assigns.actor
    field = Enum.find(socket.assigns.selected.fields, &(&1.id == id))

    if field,
      do: CMS.destroy_form_field(field, actor: actor, tenant: socket.assigns.current_org)

    {:noreply, assign_selected(socket, socket.assigns.selected.form.id)}
  end

  # --- submissions ---------------------------------------------------------------

  def handle_event("delete_submission", %{"id" => id}, socket) do
    actor = socket.assigns.actor
    org = socket.assigns.current_org

    with {:ok, submission} <- CMS.get_form_submission(id, actor: actor, tenant: org) do
      CMS.destroy_form_submission(submission, actor: actor, tenant: org)
    end

    {:noreply, assign_selected(socket, socket.assigns.selected.form.id)}
  end

  # --- embed ---------------------------------------------------------------------

  def handle_event("copied", _params, socket),
    do: {:noreply, put_flash(socket, :info, gettext("Embed code copied to clipboard."))}

  # The one-line snippet an embedder pastes on their site. `/embed.js` injects an
  # auto-resizing iframe pointing at `/forms/<slug>/embed`. Absolute URL, since
  # it runs on someone else's domain.
  defp embed_snippet(slug) do
    ~s(<script src="#{KilnCMSWeb.Endpoint.url()}/embed.js" data-kiln-form="#{slug}"></script>)
  end

  # --- data --------------------------------------------------------------------

  defp load_forms(socket) do
    assign(
      socket,
      :forms,
      CMS.list_forms!(
        actor: socket.assigns.actor,
        tenant: socket.assigns.current_org,
        load: [:submission_count],
        query: [sort: [inserted_at: :asc]]
      )
    )
  end

  defp assign_selected(socket, id) do
    actor = socket.assigns.actor
    org = socket.assigns.current_org
    form = CMS.get_form!(id, actor: actor, tenant: org)

    assign(socket, :selected, %{
      form: form,
      fields: CMS.form_fields_for!(form.id, actor: actor, tenant: org),
      submissions: CMS.recent_form_submissions!(form.id, actor: actor, tenant: org)
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
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      page_title={@page_title}
      active={:forms}
    >
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
          <form phx-submit="create_form" class="card card-pad grid gap-3 sm:grid-cols-2">
            <div>
              <label for="form-name" class="text-sm font-medium">{gettext("Name")}</label>
              <input id="form-name" name="form[name]" required class="field-input mt-1" />
            </div>
            <div>
              <label for="form-slug" class="text-sm font-medium">{gettext("Slug")}</label>
              <input
                id="form-slug"
                name="form[slug]"
                required
                placeholder="contact"
                class="field-input mt-1"
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
          <ul :if={@forms != []} class="card divide-y divide-base-content/10 overflow-hidden">
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
                class="btn btn-sm btn-ghost hover:text-error"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </li>
          </ul>
        </section>

        <section :if={@selected} class="card card-pad space-y-6 border-primary/30">
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

          <%!-- Embed code: paste on any site to render this form in an iframe. --%>
          <div class="space-y-2">
            <label class="text-sm font-medium">{gettext("Embed on another site")}</label>

            <p :if={!@selected.form.active} class="text-xs text-warning">
              {gettext(
                "This form is inactive — the embed shows “Form not found” until you activate it."
              )}
            </p>

            <div class="flex items-center gap-2">
              <input
                type="text"
                value={embed_snippet(@selected.form.slug)}
                readonly
                aria-label={gettext("Embed code")}
                class="field-input min-w-0 flex-1 font-mono text-xs"
              />
              <button
                type="button"
                id="copy-embed-code"
                phx-hook="Clipboard"
                data-clipboard-text={embed_snippet(@selected.form.slug)}
                class="btn btn-sm btn-default shrink-0"
              >
                {gettext("Copy")}
              </button>
            </div>

            <p class="text-xs text-base-content/60">
              {gettext(
                "The iframe sizes itself to the form. Restrict which sites may embed it with the EMBED_ORIGINS environment variable."
              )}
            </p>
          </div>

          <form phx-submit="save_form" class="grid gap-3 sm:grid-cols-2">
            <div>
              <label class="text-sm font-medium">{gettext("Success message")}</label>
              <input
                name="form[success_message]"
                value={@selected.form.success_message}
                class="field-input mt-1"
              />
            </div>
            <div>
              <label class="text-sm font-medium">{gettext("Notify email")}</label>
              <input
                name="form[notify_email]"
                value={@selected.form.notify_email}
                placeholder="team@example.com"
                class="field-input mt-1"
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
                  class="btn btn-sm btn-ghost hover:text-error"
                >
                  <.icon name="hero-trash" class="size-3.5" />
                </button>
              </li>
            </ul>

            <form phx-submit="add_field" class="mt-3 grid gap-2 sm:grid-cols-5">
              <label for="new-field-label" class="sr-only">{gettext("Field label")}</label>
              <input
                id="new-field-label"
                name="field[label]"
                required
                placeholder={gettext("Label")}
                class="field-input"
              />
              <label for="new-field-name" class="sr-only">{gettext("Field machine name")}</label>
              <input
                id="new-field-name"
                name="field[name]"
                required
                placeholder="machine_name"
                class="field-input"
              />
              <label for="new-field-type" class="sr-only">{gettext("Field type")}</label>
              <select id="new-field-type" name="field[field_type]" class="field-select">
                <option :for={type <- @field_types} value={type}>{type}</option>
              </select>
              <label class="flex items-center gap-1 text-xs">
                <input type="hidden" name="field[required]" value="false" />
                <input type="checkbox" name="field[required]" value="true" /> {gettext("required")}
              </label>
              <.button type="submit">{gettext("Add field")}</.button>
              <label for="new-field-options" class="sr-only">
                {gettext("Select options, one per line")}
              </label>
              <textarea
                id="new-field-options"
                name="field[options]"
                placeholder={gettext("Select options — one per line (select fields only)")}
                class="field-input text-xs sm:col-span-5"
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
                    class="btn btn-sm btn-ghost hover:text-error"
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
    </Layouts.console>
    """
  end
end
