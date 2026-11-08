defmodule KilnCMSWeb.SafetyFieldsLive do
  @moduledoc """
  Per-site safety fields: which fields of which content types are
  *safety-relevant* (`KilnCMS.CMS.SiteSafetyFields`). An edit to a live document
  that changes a listed field carries a severity (critical, notable or routine);
  the editor asks for it when publishing, and a write that does not know about
  severity records `notable`.

  Shaped after `KilnCMSWeb.FeedSettingsLive`: one row per content type over a
  single settings row, the stored map derived on save. It sits in the
  `:admin_routes` live session, and `KilnCMS.CMS.SiteSafetyFields` refuses a
  non-admin write by policy, so the router guard and the resource agree.

  ## What the page offers

  Per type: an "every field" switch (stored as `"*"`), otherwise a checkbox per
  editorial attribute and per custom field. Computed custom fields are not
  offered: the daily refresh rewrites them, and a listed one would record a
  `notable` edit every time its value moved.

  An empty selection clears the type. Types the form did not offer (an archived
  dynamic type) keep what the row said, so a stale save cannot silently drop
  them.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Severity
  alias KilnCMS.CMS.VersionFields

  # Workflow columns move on every publish, and the working copy is a draft
  # buffer: neither is content a safety edit is about.
  @workflow ~w(state published_at scheduled_at proposed_publish_at unpublish_at last_reviewed_at)a

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Safety fields"))
     |> load_settings()}
  end

  @impl true
  def handle_event("save", params, socket) do
    actor = socket.assigns.current_user
    org = socket.assigns.current_org

    if CMS.can_save_site_safety_fields?(actor, %{fields: %{}}, tenant: org) do
      case CMS.save_site_safety_fields(%{fields: build_fields(socket, params)},
             actor: actor,
             tenant: org,
             context: socket.assigns.security_context
           ) do
        {:ok, _row} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Safety fields saved."))
           |> load_settings()}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, error_message(error))}
      end
    else
      {:noreply, put_flash(socket, :error, error_message(:forbidden))}
    end
  end

  # The stored map from the form. Each checkbox carries `"type:name"` as its
  # *value* so no user-supplied string becomes a param key, and a pair the page
  # did not offer is ignored. A type left with nothing is simply absent.
  defp build_fields(socket, params) do
    offered =
      Map.new(
        socket.assigns.types,
        &{&1.name, MapSet.new(Enum.map(&1.fields, fn f -> f.name end))}
      )

    all = checked(params, "all")

    named =
      params
      |> checked("field")
      |> Enum.flat_map(fn value ->
        case String.split(value, ":", parts: 2) do
          [type, name] -> [{type, name}]
          _other -> []
        end
      end)
      |> Enum.filter(fn {type, name} ->
        match?(%MapSet{}, offered[type]) and MapSet.member?(offered[type], name)
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    chosen = chosen(offered, all, named)
    carried = carried(socket.assigns.row, offered)

    Map.merge(carried, chosen)
  end

  defp chosen(offered, all, named) do
    Enum.reduce(offered, %{}, fn {type, _names}, acc ->
      cond do
        type in all -> Map.put(acc, type, ["*"])
        names = named[type] -> Map.put(acc, type, Enum.uniq(names))
        true -> acc
      end
    end)
  end

  defp carried(nil, _offered), do: %{}

  defp carried(row, offered),
    do: Map.reject(row.fields, fn {type, _names} -> Map.has_key?(offered, type) end)

  # `params["safety"]` is client-controlled, so it is not necessarily a map.
  defp checked(params, key) do
    case params do
      %{"safety" => %{^key => names}} when is_list(names) -> Enum.filter(names, &is_binary/1)
      _absent -> []
    end
  end

  defp load_settings(socket) do
    org = socket.assigns.current_org
    actor = socket.assigns.current_user
    row = current_row(socket)

    types =
      for descriptor <- ContentTypes.all_for_org(org) do
        %{
          name: to_string(descriptor.type),
          label: descriptor.label,
          source: descriptor.source,
          fields: offered_fields(descriptor, actor, org)
        }
      end

    socket
    |> assign(:row, row)
    |> assign(:types, types)
    |> assign(:selected, (row && row.fields) || %{})
    |> assign(:severities, Severity.severities())
    |> assign(:form, to_form(%{}, as: :safety))
  end

  defp current_row(socket) do
    case CMS.list_site_safety_fields(
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, [row | _rest]} -> row
      _other -> nil
    end
  end

  # Editorial attributes, then the type's own custom fields, by the names the
  # change that records the severity matches against.
  defp offered_fields(descriptor, actor, org) do
    attributes =
      case descriptor.resource do
        nil ->
          []

        resource ->
          resource
          |> VersionFields.content_fields()
          |> Enum.reject(
            &(&1 in @workflow or &1 == :custom_fields or
                String.starts_with?(to_string(&1), "working_"))
          )
          |> Enum.map(&%{name: to_string(&1), label: humanize(&1), custom?: false})
      end

    attributes ++ custom_fields(descriptor, actor, org)
  end

  defp custom_fields(descriptor, actor, org) do
    opts = [actor: actor, tenant: org]

    definitions =
      case descriptor do
        %{source: :dynamic, definition: %{id: id}} ->
          CMS.field_definitions_for_definition(id, opts)

        %{type: type} when is_atom(type) ->
          CMS.field_definitions_for(type, opts)
      end

    case definitions do
      {:ok, list} ->
        list
        |> Enum.reject(&(&1.field_type == :computed))
        |> Enum.map(&%{name: &1.name, label: &1.label || humanize(&1.name), custom?: true})

      _error ->
        []
    end
  end

  defp humanize(name), do: name |> to_string() |> Phoenix.Naming.humanize()

  defp every_field?(selected, type), do: "*" in Map.get(selected, type.name, [])

  defp listed?(selected, type, field), do: field.name in Map.get(selected, type.name, [])

  defp source_label(%{source: :dynamic}), do: gettext("Custom")
  defp source_label(_type), do: gettext("Built-in")

  defp severity_label(:critical), do: gettext("Critical")
  defp severity_label(:notable), do: gettext("Notable")
  defp severity_label(:routine), do: gettext("Routine")

  defp error_message(error) do
    ash_error_message(error,
      forbidden: gettext("You don't have permission to change this site's safety fields."),
      fallback: gettext("Safety fields could not be saved.")
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:safety_fields}
    >
      <.header>
        {gettext("Safety fields")}
        <:subtitle>
          {gettext(
            "Fields whose edits must say how much they matter. Nothing is listed until you choose."
          )}
        </:subtitle>
      </.header>

      <div class="mt-6 rounded-lg border border-base-300 bg-base-200 p-4 text-sm">
        <p>
          {gettext(
            "A change to a listed field of published content needs a severity: %{levels}. The editor asks for it when an editor publishes the change. A change made through the API, or by any other automated writer, is recorded as notable.",
            levels: Enum.map_join(@severities, ", ", &severity_label/1)
          )}
        </p>
        <p class="mt-2 text-base-content/70">
          {gettext(
            "Do not list computed fields. The daily refresh rewrites them, and each new value would be recorded as a notable edit."
          )}
        </p>
      </div>

      <.form for={@form} id="safety-fields-form" phx-submit="save" class="mt-8 space-y-6">
        <section
          :for={type <- @types}
          id={"safety-type-#{type.name}"}
          class="rounded-lg border border-base-300 p-4"
        >
          <div class="flex flex-wrap items-center gap-2">
            <span class="font-medium">{type.label}</span>
            <span class="font-mono text-xs text-base-content/50">{type.name}</span>
            <span class="text-xs text-base-content/60">{source_label(type)}</span>
          </div>

          <label class="mt-3 flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              name="safety[all][]"
              value={type.name}
              checked={every_field?(@selected, type)}
              class="size-4 rounded border border-base-content/30 accent-primary"
            />
            {gettext("Every field")}
          </label>

          <fieldset class="mt-3">
            <legend class="text-xs text-base-content/60">
              {gettext("Or only these fields")}
            </legend>
            <div class="mt-2 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
              <label :for={field <- type.fields} class="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  name="safety[field][]"
                  value={"#{type.name}:#{field.name}"}
                  checked={listed?(@selected, type, field)}
                  class="size-4 rounded border border-base-content/30 accent-primary"
                />
                <span>{field.label}</span>
                <span :if={field.custom?} class="text-xs text-base-content/50">
                  {gettext("custom")}
                </span>
              </label>
            </div>
          </fieldset>
        </section>

        <.button phx-disable-with={gettext("Saving…")}>{gettext("Save")}</.button>
      </.form>
    </Layouts.console>
    """
  end
end
