defmodule KilnCMSWeb.FormLive do
  @moduledoc """
  The forms index (`/editor/forms`, admin-only like webhooks): create, list,
  duplicate, and delete public forms. Building a form — its fields, settings,
  embed code, and entries — happens in the visual builder
  (`KilnCMSWeb.FormBuilderLive`, `/editor/forms/:id`). Public rendering
  happens through the `:form` content block; submissions arrive via
  `POST /forms/:slug` (see `KilnCMS.Forms`).
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.Forms.Templates

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if KilnCMSWeb.LiveUserAuth.effective_tier(socket) == :admin do
      {:ok,
       socket
       |> assign(:actor, actor)
       |> assign(:page_title, gettext("Forms"))
       |> assign(:templates, Templates.list())
       |> assign(:template_key, nil)
       |> load_forms()}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You need admin access to view that page."))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("pick_template", %{"key" => key}, socket) do
    {:noreply, assign(socket, :template_key, if(key == "", do: nil, else: key))}
  end

  def handle_event("create_form", %{"form" => params}, socket) do
    template = socket.assigns.template_key && Templates.get(socket.assigns.template_key)

    result =
      if template,
        do: Templates.instantiate(template, params["name"], params["slug"], actor_opts(socket)),
        else: CMS.create_form(params, actor_opts(socket))

    case result do
      {:ok, form} ->
        message =
          if template,
            do: gettext("Form created from the template — review its fields."),
            else: gettext("Form created — add its fields.")

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> push_navigate(to: ~p"/editor/forms/#{form.id}")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  # A full copy — settings and fields — created inactive so the duplicate
  # doesn't instantly render publicly under its new slug.
  def handle_event("duplicate_form", %{"id" => id}, socket) do
    opts = actor_opts(socket)

    with {:ok, form} <- CMS.get_form(id, opts),
         {:ok, copy} <-
           CMS.create_form(
             %{
               name: gettext("%{name} (copy)", name: form.name),
               slug: unique_slug(form.slug, socket.assigns.forms),
               description: form.description,
               active: false,
               success_message: form.success_message,
               notify_email: form.notify_email,
               submit_label: form.submit_label
             },
             opts
           ) do
      for field <- CMS.form_fields_for!(form.id, opts) do
        CMS.create_form_field(
          %{
            form_id: copy.id,
            name: field.name,
            label: field.label,
            field_type: field.field_type,
            required: field.required,
            options: field.options,
            help_text: field.help_text,
            placeholder: field.placeholder,
            default_value: field.default_value,
            width: field.width,
            validation: field.validation,
            conditions: field.conditions,
            position: field.position
          },
          opts
        )
      end

      {:noreply,
       socket
       |> load_forms()
       |> put_flash(:info, gettext("Form duplicated (inactive until you activate it)."))}
    else
      {:error, error} -> {:noreply, put_flash(socket, :error, error_message(error))}
      _other -> {:noreply, put_flash(socket, :error, gettext("Couldn't duplicate that form."))}
    end
  end

  def handle_event("delete_form", %{"id" => id}, socket) do
    opts = actor_opts(socket)

    with {:ok, form} <- CMS.get_form(id, opts),
         :ok <- CMS.destroy_form(form, opts) do
      {:noreply,
       socket
       |> load_forms()
       |> put_flash(:info, gettext("Form deleted."))}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Couldn't delete that form."))}
    end
  end

  # --- data --------------------------------------------------------------------

  defp actor_opts(socket),
    do: [actor: socket.assigns.actor, tenant: socket.assigns.current_org]

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

  # A slug not yet taken by any listed form: `contact-copy`, `contact-copy-2`, …
  defp unique_slug(slug, forms) do
    taken = MapSet.new(forms, & &1.slug)
    base = "#{slug}-copy"

    [base | Enum.map(2..1000, &"#{base}-#{&1}")]
    |> Enum.find(&(!MapSet.member?(taken, &1)))
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
              <span class="text-sm font-medium">{gettext("Start from")}</span>
              <div class="mt-1 grid gap-2 sm:grid-cols-3">
                <button
                  type="button"
                  phx-click="pick_template"
                  phx-value-key=""
                  class={[
                    "rounded-lg border p-3 text-left",
                    @template_key == nil && "border-primary ring-1 ring-primary",
                    @template_key != nil && "border-base-300 hover:border-primary/40"
                  ]}
                >
                  <span class="text-sm font-medium">{gettext("Blank form")}</span>
                  <span class="mt-0.5 block text-xs text-base-content/60">
                    {gettext("Build from scratch in the builder.")}
                  </span>
                </button>
                <button
                  :for={template <- @templates}
                  type="button"
                  phx-click="pick_template"
                  phx-value-key={template.key}
                  class={[
                    "rounded-lg border p-3 text-left",
                    @template_key == template.key && "border-primary ring-1 ring-primary",
                    @template_key != template.key && "border-base-300 hover:border-primary/40"
                  ]}
                >
                  <span class="text-sm font-medium">{template.name}</span>
                  <span class="mt-0.5 block text-xs text-base-content/60">
                    {template.description}
                  </span>
                  <span class="mt-1 block text-xs text-base-content/50">
                    {gettext("%{count} fields", count: length(template.fields))}
                  </span>
                </button>
              </div>
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
              <.link
                navigate={~p"/editor/forms/#{form.id}"}
                class="min-w-0 flex-1 text-left hover:underline"
              >
                <span class="font-medium">{form.name}</span>
                <code class="ml-2 text-xs text-base-content/60">/forms/{form.slug}</code>
              </.link>
              <span :if={!form.active} class="rounded bg-base-200 px-1.5 py-0.5 text-xs">
                {gettext("Inactive")}
              </span>
              <span class="text-xs text-base-content/60">
                {gettext("%{count} submissions", count: form.submission_count)}
              </span>
              <button
                type="button"
                phx-click="duplicate_form"
                phx-value-id={form.id}
                aria-label={gettext("Duplicate form")}
                class="btn btn-sm btn-ghost"
              >
                <.icon name="hero-square-2-stack" class="size-4" />
              </button>
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
      </div>
    </Layouts.console>
    """
  end
end
