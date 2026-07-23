defmodule KilnCMSWeb.FormBuilderLive do
  @moduledoc """
  The visual form builder (`/editor/forms/:id`, admin-only): a field palette,
  a live canvas rendering the exact public-form markup
  (`BlockComponents.public_form_field/1`), and an options panel for editing the
  selected field in place — the WPForms/Formidable builder model
  (see `docs/form-builder-plan.md`, phase 1).

  Fields are added from the palette, reordered by drag (the shared `Sortable`
  hook persists `position`), and edited live via the options panel. Form-level
  settings live in tabs alongside the canvas: General, Notifications,
  Confirmations, Embed, and Entries (recent submissions).
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FormField

  import KilnCMSWeb.BlockComponents, only: [public_form_field: 1, field_width_class: 1]

  @tabs %{
    "fields" => :fields,
    "general" => :general,
    "notifications" => :notifications,
    "confirmations" => :confirmations,
    "embed" => :embed,
    "entries" => :entries
  }

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    actor = socket.assigns.current_user

    with :admin <- KilnCMSWeb.LiveUserAuth.effective_tier(socket),
         {:ok, form} <-
           CMS.get_form(id, actor: actor, tenant: socket.assigns.current_org) do
      {:ok,
       socket
       |> assign(:actor, actor)
       |> assign(:form, form)
       |> assign(:page_title, form.name)
       |> assign(:tab, :fields)
       |> assign(:selected_id, nil)
       |> assign(:submissions, [])
       |> reload_fields()}
    else
      {:error, _error} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("That form doesn't exist."))
         |> push_navigate(to: ~p"/editor/forms")}

      _tier ->
        {:ok,
         socket
         |> put_flash(:error, gettext("You need admin access to view that page."))
         |> push_navigate(to: ~p"/")}
    end
  end

  # The palette: every field type with a friendly label + icon, grouped the
  # way WPForms groups its "Add Fields" panel. A function (not an attribute)
  # so gettext resolves per-request locale.
  defp palette do
    [
      %{
        title: gettext("Standard"),
        entries: [
          %{type: :string, label: gettext("Single line text"), icon: "hero-pencil"},
          %{type: :text, label: gettext("Paragraph text"), icon: "hero-bars-3-bottom-left"},
          %{type: :email, label: gettext("Email"), icon: "hero-at-symbol"},
          %{type: :phone, label: gettext("Phone"), icon: "hero-phone"},
          %{type: :url, label: gettext("Website / URL"), icon: "hero-link"},
          %{type: :integer, label: gettext("Number"), icon: "hero-hashtag"},
          %{type: :number, label: gettext("Decimal number"), icon: "hero-calculator"},
          %{type: :date, label: gettext("Date"), icon: "hero-calendar"}
        ]
      },
      %{
        title: gettext("Choices"),
        entries: [
          %{type: :select, label: gettext("Dropdown"), icon: "hero-chevron-up-down"},
          %{type: :radio, label: gettext("Multiple choice"), icon: "hero-list-bullet"},
          %{type: :checkboxes, label: gettext("Checkboxes"), icon: "hero-queue-list"},
          %{type: :boolean, label: gettext("Checkbox"), icon: "hero-check-circle"},
          %{type: :rating, label: gettext("Rating (1–5)"), icon: "hero-star"},
          %{type: :consent, label: gettext("Consent"), icon: "hero-shield-check"}
        ]
      },
      %{
        title: gettext("Layout"),
        entries: [
          %{type: :heading, label: gettext("Heading"), icon: "hero-bars-3-center-left"},
          %{type: :divider, label: gettext("Divider"), icon: "hero-minus"},
          %{type: :hidden, label: gettext("Hidden"), icon: "hero-eye-slash"}
        ]
      }
    ]
  end

  defp palette_entries, do: Enum.flat_map(palette(), & &1.entries)

  # Which options-panel sections apply per type.
  defp choice_type?(type), do: type in FormField.choice_types()
  defp length_types, do: [:string, :text, :email, :phone, :url]
  defp range_types, do: [:integer, :number]
  defp pattern_types, do: [:string, :phone, :url]
  defp placeholder_types, do: [:string, :text, :email, :phone, :url, :integer, :number]
  defp no_required_types, do: [:heading, :divider, :hidden]
  defp no_default_types, do: [:checkboxes, :heading, :divider, :consent]

  # --- tabs --------------------------------------------------------------------

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    tab = Map.get(@tabs, tab, :fields)
    socket = assign(socket, :tab, tab)
    socket = if tab == :entries, do: reload_submissions(socket), else: socket
    {:noreply, socket}
  end

  # --- fields ------------------------------------------------------------------

  def handle_event("add_field", %{"type" => type}, socket) do
    fields = socket.assigns.fields
    entry = Enum.find(palette_entries(), &(Atom.to_string(&1.type) == type))

    if entry do
      attrs = %{
        form_id: socket.assigns.form.id,
        name: unique_name(Atom.to_string(entry.type), fields),
        label: entry.label,
        field_type: entry.type,
        options:
          if(choice_type?(entry.type),
            do: [gettext("Option 1"), gettext("Option 2")],
            else: []
          ),
        position: next_position(fields)
      }

      case CMS.create_form_field(attrs, actor_opts(socket)) do
        {:ok, field} ->
          {:noreply, socket |> reload_fields() |> assign(:selected_id, field.id)}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, error_message(error))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_field", %{"id" => id}, socket) do
    if Enum.any?(socket.assigns.fields, &(&1.id == id)) do
      {:noreply, assign(socket, :selected_id, id)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("deselect_field", _params, socket) do
    {:noreply, assign(socket, :selected_id, nil)}
  end

  def handle_event("update_field", %{"field" => %{"id" => id} = params}, socket) do
    field = Enum.find(socket.assigns.fields, &(&1.id == id))

    case field && CMS.update_form_field(field, field_params(params, field), actor_opts(socket)) do
      nil -> {:noreply, socket}
      {:ok, _field} -> {:noreply, reload_fields(socket)}
      {:error, error} -> {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("duplicate_field", %{"id" => id}, socket) do
    fields = socket.assigns.fields

    case Enum.find(fields, &(&1.id == id)) do
      nil -> {:noreply, socket}
      field -> copy_field(socket, field, fields)
    end
  end

  def handle_event("delete_field", %{"id" => id}, socket) do
    with %FormField{} = field <- Enum.find(socket.assigns.fields, &(&1.id == id)) do
      CMS.destroy_form_field(field, actor_opts(socket))
    end

    selected = if socket.assigns.selected_id == id, do: nil, else: socket.assigns.selected_id
    {:noreply, socket |> reload_fields() |> assign(:selected_id, selected)}
  end

  # Pushed by the Sortable hook with the canvas' new data-sort-id order.
  def handle_event("reorder", %{"order" => order}, socket) when is_list(order) do
    {:noreply, socket |> apply_order(order) |> reload_fields()}
  end

  # --- form settings -----------------------------------------------------------

  def handle_event("save_form", %{"form" => params}, socket) do
    case CMS.update_form(socket.assigns.form, params, actor_opts(socket)) do
      {:ok, form} ->
        {:noreply,
         socket
         |> assign(:form, form)
         |> assign(:page_title, form.name)
         |> put_flash(:info, gettext("Saved."))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  # --- submissions -------------------------------------------------------------

  def handle_event("delete_submission", %{"id" => id}, socket) do
    opts = actor_opts(socket)

    with {:ok, submission} <- CMS.get_form_submission(id, opts) do
      CMS.destroy_form_submission(submission, opts)
    end

    {:noreply, reload_submissions(socket)}
  end

  # --- embed -------------------------------------------------------------------

  def handle_event("copied", _params, socket),
    do: {:noreply, put_flash(socket, :info, gettext("Embed code copied to clipboard."))}

  # The one-line snippet an embedder pastes on their site (see `/embed.js`).
  defp embed_snippet(slug) do
    ~s(<script src="#{KilnCMSWeb.Endpoint.url()}/embed.js" data-kiln-form="#{slug}"></script>)
  end

  # --- data --------------------------------------------------------------------

  defp copy_field(socket, field, fields) do
    attrs = %{
      form_id: field.form_id,
      name: unique_name(field.name, fields),
      label: field.label,
      field_type: field.field_type,
      required: field.required,
      options: field.options,
      help_text: field.help_text,
      placeholder: field.placeholder,
      default_value: field.default_value,
      width: field.width,
      validation: field.validation,
      position: field.position
    }

    case CMS.create_form_field(attrs, actor_opts(socket)) do
      {:ok, copy} ->
        # Slot the copy right after its original, then renumber everything.
        order = fields |> Enum.map(& &1.id) |> insert_after(field.id, copy.id)

        {:noreply,
         socket |> apply_order(order) |> reload_fields() |> assign(:selected_id, copy.id)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  defp insert_after(ids, target, new_id),
    do: Enum.flat_map(ids, &if(&1 == target, do: [&1, new_id], else: [&1]))

  defp actor_opts(socket),
    do: [actor: socket.assigns.actor, tenant: socket.assigns.current_org]

  defp reload_fields(socket) do
    assign(
      socket,
      :fields,
      CMS.form_fields_for!(socket.assigns.form.id, actor_opts(socket))
    )
  end

  defp reload_submissions(socket) do
    assign(
      socket,
      :submissions,
      CMS.recent_form_submissions!(socket.assigns.form.id, actor_opts(socket))
    )
  end

  # Persist a full id ordering as 0-based positions, skipping no-op updates.
  defp apply_order(socket, order) do
    fields_by_id = Map.new(socket.assigns.fields, &{&1.id, &1})

    order
    |> Enum.with_index()
    |> Enum.each(fn {id, index} ->
      with %FormField{} = field <- fields_by_id[id],
           true <- field.position != index do
        CMS.update_form_field(field, %{position: index}, actor_opts(socket))
      end
    end)

    socket
  end

  defp next_position([]), do: 0
  defp next_position(fields), do: Enum.max_by(fields, & &1.position).position + 1

  # A machine name not yet taken on this form: `email`, `email_2`, `email_3`, …
  defp unique_name(base, fields) do
    taken = MapSet.new(fields, & &1.name)

    [base | Enum.map(2..1000, &"#{base}_#{&1}")]
    |> Enum.find(&(!MapSet.member?(taken, &1)))
  end

  # Options-panel params → update attrs. Options arrive newline-separated
  # (only while the textarea is rendered, i.e. the field is a choice type);
  # switching a field *to* a choice type seeds starter options so it stays
  # valid. Validation rules arrive as strings and are normalized to the typed
  # map `KilnCMS.Forms` enforces (blank/unparsable entries drop the rule).
  defp field_params(params, field) do
    params
    |> Map.drop(["id", "_target"])
    |> normalize_options(field)
    |> normalize_validation()
  end

  defp normalize_options(params, field) do
    params =
      case Map.fetch(params, "options") do
        {:ok, raw} ->
          Map.put(
            params,
            "options",
            raw |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
          )

        :error ->
          params
      end

    if params["field_type"] in ["select", "radio", "checkboxes"] and field.options == [] and
         params["options"] in [nil, []] do
      Map.put(params, "options", [gettext("Option 1"), gettext("Option 2")])
    else
      params
    end
  end

  defp normalize_validation(%{"validation" => rules} = params) when is_map(rules) do
    normalized =
      rules
      |> Enum.flat_map(fn {key, value} -> normalize_rule(key, String.trim(value)) end)
      |> Map.new()

    Map.put(params, "validation", normalized)
  end

  defp normalize_validation(params), do: params

  defp normalize_rule(_key, ""), do: []

  defp normalize_rule(key, value) when key in ["min_length", "max_length"] do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> [{key, n}]
      _invalid -> []
    end
  end

  defp normalize_rule(key, value) when key in ["min", "max"] do
    case Integer.parse(value) do
      {n, ""} ->
        [{key, n}]

      _not_integer ->
        case Float.parse(value) do
          {n, ""} -> [{key, n}]
          _invalid -> []
        end
    end
  end

  defp normalize_rule(key, value), do: [{key, value}]

  # Checkboxes store a list — join it; `to_string/1` would concatenate the
  # entries as chardata ("ab" from ["a", "b"]).
  defp display_value(value) when is_list(value), do: Enum.join(value, ", ")
  defp display_value(value), do: to_string(value)

  defp error_message(%{errors: errors}) when is_list(errors) and errors != [] do
    errors
    |> Enum.map_join("; ", fn
      %{field: field, message: message} when not is_nil(field) -> "#{field} #{message}"
      %{message: message} when is_binary(message) -> message
      other -> inspect(other)
    end)
  end

  defp error_message(_error), do: gettext("Something went wrong.")

  defp tab_label(:fields), do: gettext("Fields")
  defp tab_label(:general), do: gettext("General")
  defp tab_label(:notifications), do: gettext("Notifications")
  defp tab_label(:confirmations), do: gettext("Confirmations")
  defp tab_label(:embed), do: gettext("Embed")
  defp tab_label(:entries), do: gettext("Entries")

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
      <div class="space-y-4">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div class="min-w-0">
            <.link navigate={~p"/editor/forms"} class="text-sm text-base-content/60 hover:underline">
              &larr; {gettext("All forms")}
            </.link>
            <h1 class="mt-1 flex items-center gap-2 text-2xl font-semibold">
              <span class="truncate">{@form.name}</span>
              <span :if={!@form.active} class="rounded bg-base-200 px-1.5 py-0.5 text-xs font-normal">
                {gettext("Inactive")}
              </span>
            </h1>
            <code class="text-xs text-base-content/60">/forms/{@form.slug}</code>
          </div>
          <a
            :if={@form.active}
            href={"/forms/" <> @form.slug <> "/embed"}
            target="_blank"
            rel="noopener"
            class="btn btn-sm btn-default"
          >
            {gettext("Preview")}
          </a>
        </div>

        <nav class="flex flex-wrap gap-1 border-b border-base-content/10" role="tablist">
          <button
            :for={tab <- [:fields, :general, :notifications, :confirmations, :embed, :entries]}
            type="button"
            role="tab"
            aria-selected={to_string(@tab == tab)}
            phx-click="set_tab"
            phx-value-tab={tab}
            class={[
              "rounded-t px-3 py-2 text-sm",
              @tab == tab && "border-b-2 border-primary font-medium text-primary",
              @tab != tab && "text-base-content/70 hover:text-base-content"
            ]}
          >
            {tab_label(tab)}
          </button>
        </nav>

        <div :if={@tab == :fields} class="grid gap-4 lg:grid-cols-[13rem_minmax(0,1fr)_19rem]">
          <%!-- Palette: click a type to append it to the form. --%>
          <aside class="card card-pad h-fit space-y-3" aria-label={gettext("Add a field")}>
            <div :for={group <- palette()} class="space-y-1">
              <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
                {group.title}
              </h2>
              <button
                :for={entry <- group.entries}
                type="button"
                phx-click="add_field"
                phx-value-type={entry.type}
                class="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-sm hover:bg-base-200"
              >
                <.icon name={entry.icon} class="size-4 text-base-content/60" />
                {entry.label}
              </button>
            </div>
          </aside>

          <%!-- Canvas: the real public-form markup, one selectable card per field. --%>
          <section class="card card-pad" aria-label={gettext("Form preview")}>
            <p :if={@form.description} class="mb-3 text-sm text-base-content/70">
              {@form.description}
            </p>

            <p
              :if={@fields == []}
              class="rounded border border-dashed border-base-300 p-6 text-center text-sm text-base-content/60"
            >
              {gettext("No fields yet — add one from the palette.")}
            </p>

            <div id="builder-canvas" phx-hook="Sortable" class="grid grid-cols-1 gap-3 sm:grid-cols-6">
              <div
                :for={field <- @fields}
                data-sort-id={field.id}
                class={[
                  field_width_class(field),
                  "group relative rounded-lg border p-3",
                  @selected_id == field.id && "border-primary ring-1 ring-primary",
                  @selected_id != field.id && "border-base-300 hover:border-primary/40"
                ]}
              >
                <button
                  type="button"
                  phx-click="select_field"
                  phx-value-id={field.id}
                  aria-label={gettext("Edit field %{label}", label: field.label)}
                  class="absolute inset-0 z-[5] cursor-pointer rounded-lg"
                ></button>

                <div class={[
                  "absolute -top-2.5 right-2 z-10 gap-0.5 rounded border border-base-300 bg-base-100 px-0.5 shadow-sm",
                  @selected_id == field.id && "flex",
                  @selected_id != field.id && "hidden group-hover:flex"
                ]}>
                  <button
                    type="button"
                    data-drag-handle
                    aria-label={gettext("Reorder field %{label}", label: field.label)}
                    class="cursor-grab p-1 text-base-content/60 hover:text-base-content"
                  >
                    <.icon name="hero-arrows-up-down" class="size-3.5" />
                  </button>
                  <button
                    type="button"
                    phx-click="duplicate_field"
                    phx-value-id={field.id}
                    aria-label={gettext("Duplicate field %{label}", label: field.label)}
                    class="p-1 text-base-content/60 hover:text-base-content"
                  >
                    <.icon name="hero-square-2-stack" class="size-3.5" />
                  </button>
                  <button
                    type="button"
                    phx-click="delete_field"
                    phx-value-id={field.id}
                    data-confirm={gettext("Delete this field?")}
                    aria-label={gettext("Delete field %{label}", label: field.label)}
                    class="p-1 text-base-content/60 hover:text-error"
                  >
                    <.icon name="hero-trash" class="size-3.5" />
                  </button>
                </div>

                <%!-- A hidden input renders nothing — show a chip so it stays
                      visible (and selectable) on the canvas. --%>
                <div
                  :if={field.field_type == :hidden}
                  class="flex items-center gap-1.5 text-xs text-base-content/60"
                >
                  <.icon name="hero-eye-slash" class="size-3.5" />
                  {gettext("Hidden field")} <code>{field.name}</code>
                </div>

                <fieldset
                  :if={field.field_type != :hidden}
                  disabled
                  class="pointer-events-none select-none"
                >
                  <.public_form_field field={field} />
                </fieldset>
              </div>
            </div>

            <div :if={@fields != []} class="mt-4">
              <button
                type="button"
                disabled
                class="rounded bg-primary px-4 py-2 text-sm font-medium text-primary-content opacity-70"
              >
                {@form.submit_label || gettext("Submit")}
              </button>
            </div>
          </section>

          <%!-- Options panel: edit the selected field in place. --%>
          <aside class="card card-pad h-fit" aria-label={gettext("Field settings")}>
            <% selected = Enum.find(@fields, &(&1.id == @selected_id)) %>
            <p :if={!selected} class="text-sm text-base-content/60">
              {gettext("Select a field on the canvas to edit it, or add one from the palette.")}
            </p>

            <div :if={selected} class="space-y-3">
              <div class="flex items-center justify-between gap-2">
                <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
                  {gettext("Field settings")}
                </h2>
                <button
                  type="button"
                  phx-click="deselect_field"
                  aria-label={gettext("Close field settings")}
                  class="text-base-content/70 hover:text-base-content"
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
              </div>

              <form
                id={"field-settings-#{selected.id}"}
                phx-change="update_field"
                class="space-y-3 text-sm"
              >
                <input type="hidden" name="field[id]" value={selected.id} />

                <div>
                  <label for="fs-label" class="font-medium">
                    {if selected.field_type == :heading,
                      do: gettext("Heading text"),
                      else: gettext("Label")}
                  </label>
                  <input
                    id="fs-label"
                    name="field[label]"
                    value={selected.label}
                    phx-debounce="300"
                    class="field-input mt-1"
                  />
                </div>

                <div :if={selected.field_type not in [:heading, :divider]}>
                  <label for="fs-name" class="font-medium">{gettext("Machine name")}</label>
                  <input
                    id="fs-name"
                    name="field[name]"
                    value={selected.name}
                    phx-debounce="blur"
                    class="field-input mt-1 font-mono text-xs"
                  />
                  <p class="mt-1 text-xs text-base-content/60">
                    {gettext("Keys this field's value in submissions — renaming orphans old entries.")}
                  </p>
                </div>

                <div class="grid grid-cols-2 gap-2">
                  <div>
                    <label for="fs-type" class="font-medium">{gettext("Type")}</label>
                    <select id="fs-type" name="field[field_type]" class="field-select mt-1">
                      <option
                        :for={entry <- palette_entries()}
                        value={entry.type}
                        selected={entry.type == selected.field_type}
                      >
                        {entry.label}
                      </option>
                    </select>
                  </div>
                  <div>
                    <label for="fs-width" class="font-medium">{gettext("Width")}</label>
                    <select id="fs-width" name="field[width]" class="field-select mt-1">
                      <option value="full" selected={selected.width == :full}>
                        {gettext("Full")}
                      </option>
                      <option value="half" selected={selected.width == :half}>
                        {gettext("Half")}
                      </option>
                      <option value="third" selected={selected.width == :third}>
                        {gettext("Third")}
                      </option>
                    </select>
                  </div>
                </div>

                <label
                  :if={selected.field_type not in no_required_types()}
                  class="flex items-center gap-2"
                >
                  <input type="hidden" name="field[required]" value="false" />
                  <input
                    type="checkbox"
                    name="field[required]"
                    value="true"
                    checked={selected.required}
                    class="size-4 rounded border border-base-content/30 accent-primary"
                  />
                  {if selected.field_type == :consent,
                    do: gettext("Required (must be accepted to submit)"),
                    else: gettext("Required")}
                </label>

                <div :if={choice_type?(selected.field_type)}>
                  <label for="fs-options" class="font-medium">
                    {gettext("Options — one per line")}
                  </label>
                  <textarea
                    id="fs-options"
                    name="field[options]"
                    phx-debounce="300"
                    rows="4"
                    class="field-input mt-1 text-xs"
                  >{Enum.join(selected.options, "\n")}</textarea>
                </div>

                <div :if={selected.field_type in placeholder_types()}>
                  <label for="fs-placeholder" class="font-medium">{gettext("Placeholder")}</label>
                  <input
                    id="fs-placeholder"
                    name="field[placeholder]"
                    value={selected.placeholder}
                    phx-debounce="300"
                    class="field-input mt-1"
                  />
                </div>

                <div :if={selected.field_type not in no_default_types()}>
                  <label for="fs-default" class="font-medium">
                    {if selected.field_type == :hidden,
                      do: gettext("Value"),
                      else: gettext("Default value")}
                  </label>
                  <input
                    id="fs-default"
                    name="field[default_value]"
                    value={selected.default_value}
                    phx-debounce="300"
                    class="field-input mt-1"
                  />
                  <p :if={selected.field_type == :boolean} class="mt-1 text-xs text-base-content/60">
                    {gettext("Use \"true\" to pre-check the box.")}
                  </p>
                  <p :if={selected.field_type == :rating} class="mt-1 text-xs text-base-content/60">
                    {gettext("A number from 1 to 5.")}
                  </p>
                </div>

                <div :if={selected.field_type != :divider}>
                  <label for="fs-help" class="font-medium">{gettext("Help text")}</label>
                  <input
                    id="fs-help"
                    name="field[help_text]"
                    value={selected.help_text}
                    phx-debounce="300"
                    class="field-input mt-1"
                  />
                </div>

                <div
                  :if={
                    selected.field_type in length_types() or
                      selected.field_type in range_types()
                  }
                  class="space-y-3 border-t border-base-content/10 pt-3"
                >
                  <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
                    {gettext("Validation")}
                  </h3>

                  <div :if={selected.field_type in length_types()} class="grid grid-cols-2 gap-2">
                    <div>
                      <label for="fs-min-length" class="font-medium">{gettext("Min length")}</label>
                      <input
                        id="fs-min-length"
                        type="number"
                        min="0"
                        name="field[validation][min_length]"
                        value={selected.validation["min_length"]}
                        phx-debounce="300"
                        class="field-input mt-1"
                      />
                    </div>
                    <div>
                      <label for="fs-max-length" class="font-medium">{gettext("Max length")}</label>
                      <input
                        id="fs-max-length"
                        type="number"
                        min="0"
                        name="field[validation][max_length]"
                        value={selected.validation["max_length"]}
                        phx-debounce="300"
                        class="field-input mt-1"
                      />
                    </div>
                  </div>

                  <div :if={selected.field_type in range_types()} class="grid grid-cols-2 gap-2">
                    <div>
                      <label for="fs-min" class="font-medium">{gettext("Min value")}</label>
                      <input
                        id="fs-min"
                        type="number"
                        step="any"
                        name="field[validation][min]"
                        value={selected.validation["min"]}
                        phx-debounce="300"
                        class="field-input mt-1"
                      />
                    </div>
                    <div>
                      <label for="fs-max" class="font-medium">{gettext("Max value")}</label>
                      <input
                        id="fs-max"
                        type="number"
                        step="any"
                        name="field[validation][max]"
                        value={selected.validation["max"]}
                        phx-debounce="300"
                        class="field-input mt-1"
                      />
                    </div>
                  </div>

                  <div :if={selected.field_type in pattern_types()}>
                    <label for="fs-pattern" class="font-medium">{gettext("Pattern (regex)")}</label>
                    <input
                      id="fs-pattern"
                      name="field[validation][pattern]"
                      value={selected.validation["pattern"]}
                      phx-debounce="500"
                      class="field-input mt-1 font-mono text-xs"
                    />
                    <p class="mt-1 text-xs text-base-content/60">
                      {gettext("Matched against the whole value.")}
                    </p>
                  </div>

                  <div>
                    <label for="fs-message" class="font-medium">
                      {gettext("Custom error message")}
                    </label>
                    <input
                      id="fs-message"
                      name="field[validation][message]"
                      value={selected.validation["message"]}
                      phx-debounce="300"
                      class="field-input mt-1"
                    />
                  </div>
                </div>
              </form>
            </div>
          </aside>
        </div>

        <section :if={@tab == :general} class="card card-pad max-w-2xl">
          <form phx-submit="save_form" class="grid gap-3 sm:grid-cols-2">
            <div>
              <label for="gf-name" class="text-sm font-medium">{gettext("Name")}</label>
              <input
                id="gf-name"
                name="form[name]"
                value={@form.name}
                required
                class="field-input mt-1"
              />
            </div>
            <div>
              <label for="gf-slug" class="text-sm font-medium">{gettext("Slug")}</label>
              <input
                id="gf-slug"
                name="form[slug]"
                value={@form.slug}
                required
                class="field-input mt-1"
              />
            </div>
            <div class="sm:col-span-2">
              <label for="gf-description" class="text-sm font-medium">{gettext("Description")}</label>
              <textarea id="gf-description" name="form[description]" rows="2" class="field-input mt-1">{@form.description}</textarea>
            </div>
            <div>
              <label for="gf-submit-label" class="text-sm font-medium">
                {gettext("Submit button label")}
              </label>
              <input
                id="gf-submit-label"
                name="form[submit_label]"
                value={@form.submit_label}
                placeholder={gettext("Submit")}
                class="field-input mt-1"
              />
            </div>
            <label class="flex items-center gap-2 self-end text-sm">
              <input type="hidden" name="form[active]" value="false" />
              <input
                type="checkbox"
                name="form[active]"
                value="true"
                checked={@form.active}
                class="size-4 rounded border border-base-content/30 accent-primary"
              />
              {gettext("Active (accepting submissions)")}
            </label>
            <div class="sm:col-span-2">
              <.button type="submit" variant="primary">{gettext("Save")}</.button>
            </div>
          </form>
        </section>

        <section :if={@tab == :notifications} class="card card-pad max-w-2xl">
          <form phx-submit="save_form" class="space-y-3">
            <div>
              <label for="nf-email" class="text-sm font-medium">{gettext("Notify email")}</label>
              <input
                id="nf-email"
                name="form[notify_email]"
                value={@form.notify_email}
                placeholder="team@example.com"
                class="field-input mt-1"
              />
              <p class="mt-1 text-xs text-base-content/60">
                {gettext("Each submission is mailed here. Leave blank for no notification.")}
              </p>
            </div>
            <.button type="submit" variant="primary">{gettext("Save")}</.button>
          </form>
        </section>

        <section :if={@tab == :confirmations} class="card card-pad max-w-2xl">
          <form phx-submit="save_form" class="space-y-3">
            <div>
              <label for="cf-success" class="text-sm font-medium">{gettext("Success message")}</label>
              <input
                id="cf-success"
                name="form[success_message]"
                value={@form.success_message}
                class="field-input mt-1"
              />
              <p class="mt-1 text-xs text-base-content/60">
                {gettext("Shown on the thank-you page after a successful submission.")}
              </p>
            </div>
            <.button type="submit" variant="primary">{gettext("Save")}</.button>
          </form>
        </section>

        <section :if={@tab == :embed} class="card card-pad max-w-2xl space-y-2">
          <label class="text-sm font-medium">{gettext("Embed on another site")}</label>

          <p :if={!@form.active} class="text-xs text-warning">
            {gettext(
              "This form is inactive — the embed shows “Form not found” until you activate it."
            )}
          </p>

          <div class="flex items-center gap-2">
            <input
              type="text"
              value={embed_snippet(@form.slug)}
              readonly
              aria-label={gettext("Embed code")}
              class="field-input min-w-0 flex-1 font-mono text-xs"
            />
            <button
              type="button"
              id="copy-embed-code"
              phx-hook="Clipboard"
              data-clipboard-text={embed_snippet(@form.slug)}
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
        </section>

        <section :if={@tab == :entries} class="max-w-3xl">
          <p :if={@submissions == []} class="text-sm text-base-content/60">
            {gettext("None yet.")}
          </p>
          <ul :if={@submissions != []} class="space-y-2">
            <li
              :for={submission <- @submissions}
              class="card rounded border border-base-content/10 p-3 text-sm"
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
                  <dd class="min-w-0 break-words text-base-content/80">{display_value(value)}</dd>
                </div>
              </dl>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.console>
    """
  end
end
