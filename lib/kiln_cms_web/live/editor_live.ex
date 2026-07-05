defmodule KilnCMSWeb.EditorLive do
  @moduledoc """
  Content list / editor home (`/editor`) — browse pages and posts with their
  workflow state, create new content, jump into the block editor, and
  publish/unpublish inline, with status + title filtering. Editor/admin only.
  """
  use KilnCMSWeb, :live_view

  import Ash.Expr, only: [expr: 1]

  alias KilnCMS.CMS.ContentTypes

  @statuses ~w(all draft in_review published archived)

  # Server-side page size. Each page pulls at most @page_size rows per content
  # type from the DB (status/search filtered there too — audit U-M2) and keeps
  # the merged newest @page_size, so any item is reachable via Load more.
  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:actor, socket.assigns.current_user)
     |> assign(:page_title, gettext("Content"))
     |> assign(:content_types, editable_types())
     |> assign(:statuses, @statuses)
     |> assign(:selected, MapSet.new())
     |> assign(:confirming_bulk, nil)}
  end

  # Only what the list renders — without a select, every row drags its whole
  # blocks JSONB tree (plus search_text and embedding) into the LiveView heap.
  # Workflow/destroy actions re-fetch the full record by id before acting.
  @list_fields [:id, :title, :slug, :state, :updated_at, :scheduled_at, :unpublish_at]

  # (Re)load the first page under the active status/search/custom-field filter.
  defp load_items(socket) do
    {items, more?} = fetch_page(socket, nil)

    socket
    |> assign(:items, items)
    |> assign(:more?, more?)
  end

  # One page of `{kind, record}` tuples, from `cursor` (exclusive) downwards.
  #
  # Unscoped, this merges every content type newest-updated first; keeping the
  # merged newest @page_size is exact: the true next page can't contain more
  # than @page_size rows of any single type. Scoped to one type (the
  # custom-field filter requires that — field definitions are per type), it's a
  # single list, and with a custom sort the `cursor` is a plain row offset
  # because the order no longer follows `updated_at`.
  defp fetch_page(socket, cursor) do
    actor = socket.assigns.actor
    query = page_query(socket.assigns, cursor)
    args = custom_query_args(socket.assigns)

    types =
      case socket.assigns.scoped_type do
        nil -> editable_types()
        scoped -> [scoped]
      end

    per_type =
      Enum.map(types, fn ct ->
        # Dispatch on the descriptor itself so a type archived between listing
        # and dispatch can't turn into a registry-lookup miss.
        ct
        |> ContentTypes.list!(actor: actor, query: query, args: args)
        |> Enum.map(&{ct.type, &1})
      end)

    merged = List.flatten(per_type)

    # Under a custom sort the (single-type) rows already arrive in field
    # order from the DB — re-sorting by updated_at would undo it.
    merged =
      if custom_sort?(socket.assigns),
        do: merged,
        else: Enum.sort_by(merged, fn {_kind, r} -> r.updated_at end, {:desc, DateTime})

    {page, rest} = Enum.split(merged, @page_size)

    # More pages exist if we dropped merged rows, or any type filled its
    # window (it may have more behind it even when everything merged fit).
    {page, rest != [] or Enum.any?(per_type, &(length(&1) >= @page_size))}
  end

  defp page_query(assigns, cursor) do
    csort? = custom_sort?(assigns)

    # The displayed custom-field chip needs the map; everything else renders
    # from the slim @list_fields select.
    select = @list_fields ++ if(assigns.show_def, do: [:custom_fields], else: [])

    [
      assigns.status != "all" && {:filter, [state: String.to_existing_atom(assigns.status)]},
      assigns.query != "" && {:filter, search_filter(assigns.query)},
      # With a custom sort the CustomFieldQuery preparation owns the order (a
      # sort set here would outrank it), so page by row offset instead of the
      # updated_at keyset. Equal field values have no tiebreak across pages —
      # acceptable for an admin list.
      not csort? && cursor && {:filter, expr(updated_at < ^cursor)},
      not csort? && {:sort, [updated_at: :desc]},
      csort? && {:offset, cursor || 0}
    ]
    |> Enum.filter(&is_tuple/1)
    |> Kernel.++(select: select, limit: @page_size)
  end

  # Case-insensitive title/slug match; %, _ and \ in the input match literally.
  defp search_filter(q) do
    pattern = "%" <> escape_like(q) <> "%"
    expr(ilike(title, ^pattern) or ilike(slug, ^pattern))
  end

  defp escape_like(text), do: String.replace(text, ~r/([\\%_])/, "\\\\\\1")

  # --- custom-field filter/sort (scoped to one content type) -----------------

  defp custom_sort?(assigns), do: assigns.custom_sort != ""

  # The `custom_filter`/`custom_sort` action arguments for the current filter
  # state (see `Preparations.CustomFieldQuery`) — %{} when inactive.
  defp custom_query_args(assigns) do
    args =
      case active_condition(assigns) do
        nil -> %{}
        {name, condition} -> %{custom_filter: %{name => condition}}
      end

    if custom_sort?(assigns), do: Map.put(args, :custom_sort, assigns.custom_sort), else: args
  end

  # The validated {field name, condition} for the active filter, or nil when
  # incomplete (no field, blank value) or the value can't be of the field's
  # type — a half-typed date shouldn't error the list, just not filter yet.
  defp active_condition(%{filter_def: nil}), do: nil

  defp active_condition(%{filter_def: definition, filter_op: op, filter_value: value}) do
    case op_condition(definition, op, String.trim(value)) do
      nil -> nil
      condition -> {definition.name, condition}
    end
  end

  defp op_condition(_definition, "set", _value), do: %{"null" => "false"}
  defp op_condition(_definition, "unset", _value), do: %{"null" => "true"}
  defp op_condition(_definition, _op, ""), do: nil

  defp op_condition(_definition, "contains", text),
    do: %{"ilike" => "%" <> escape_like(text) <> "%"}

  defp op_condition(definition, op, text) do
    case normalize_value(definition.field_type, text) do
      {:ok, normalized} when op == "eq" -> normalized
      {:ok, normalized} -> %{op => normalized}
      :error -> nil
    end
  end

  # Pre-validate (and normalize) the raw input so an unparsable value never
  # reaches the query as an error; values stay strings — the preparation casts.
  defp normalize_value(:integer, text) do
    case Integer.parse(text) do
      {_n, ""} -> {:ok, text}
      _ -> :error
    end
  end

  defp normalize_value(:float, text) do
    case Float.parse(text) do
      {_n, ""} -> {:ok, text}
      _ -> :error
    end
  end

  defp normalize_value(:boolean, text) when text in ["true", "false"], do: {:ok, text}
  defp normalize_value(:boolean, _text), do: :error

  defp normalize_value(:date, text) do
    case Date.from_iso8601(text) do
      {:ok, _} -> {:ok, text}
      _ -> :error
    end
  end

  # datetime-local inputs omit seconds; the stored ISO-8601 (and the cast)
  # carries them.
  defp normalize_value(:datetime, text) do
    padded = if byte_size(text) == 16, do: text <> ":00", else: text

    case NaiveDateTime.from_iso8601(padded) do
      {:ok, _} -> {:ok, padded}
      _ -> :error
    end
  end

  defp normalize_value(_type, text), do: {:ok, text}

  # Operators offered per field type (mirrors what the value's type can
  # meaningfully do; media/reference only carry presence here — filter by id
  # belongs to the API).
  defp ops_for(:boolean), do: ~w(eq set unset)

  defp ops_for(type) when type in [:integer, :float, :date, :datetime],
    do: ~w(eq gt gte lt lte set unset)

  defp ops_for(:select), do: ~w(eq not_eq set unset)
  defp ops_for(type) when type in [:media, :reference], do: ~w(set unset)
  defp ops_for(_type), do: ~w(eq contains not_eq set unset)

  defp op_label("eq"), do: gettext("is")
  defp op_label("not_eq"), do: gettext("is not")
  defp op_label("gt"), do: ">"
  defp op_label("gte"), do: "≥"
  defp op_label("lt"), do: "<"
  defp op_label("lte"), do: "≤"
  defp op_label("contains"), do: gettext("contains")
  defp op_label("set"), do: gettext("is set")
  defp op_label("unset"), do: gettext("is not set")

  defp sortable?(definition), do: definition.field_type not in [:media, :reference]

  # Which input the filter value renders as. `:select` becomes a dropdown
  # (options for select fields, true/false for booleans); everything else maps
  # to the matching HTML input type, defaulting to text.
  defp value_input_kind(%{field_type: type}) when type in [:select, :boolean], do: :select
  defp value_input_kind(%{field_type: type}) when type in [:integer, :float], do: "number"
  defp value_input_kind(%{field_type: :date}), do: "date"
  defp value_input_kind(%{field_type: :datetime}), do: "datetime-local"
  defp value_input_kind(_definition), do: "text"

  defp value_options(%{field_type: :boolean}), do: ~w(true false)
  defp value_options(%{options: options}), do: options

  # The custom-field definitions of the scoped type ([] otherwise — the merged
  # multi-type list can't filter on per-type fields).
  defp custom_defs(nil, _actor), do: []

  defp custom_defs(%{source: :dynamic, definition: definition}, actor),
    do: KilnCMS.CMS.field_definitions_for_definition!(definition.id, actor: actor)

  defp custom_defs(%{type: type}, actor),
    do: KilnCMS.CMS.field_definitions_for!(type, actor: actor)

  defp find_type(nil), do: nil
  defp find_type(""), do: nil
  defp find_type(param), do: Enum.find(editable_types(), &(to_string(&1.type) == param))

  # The chip value shown per row when a custom field is filtered/sorted on.
  defp display_custom_value(record, definition) do
    case Map.get(record.custom_fields || %{}, definition.name) do
      nil -> "—"
      %{} = snapshot -> snapshot["title"] || snapshot["alt"] || snapshot["url"] || snapshot["id"]
      value -> to_string(value)
    end
  end

  # Everything editable here: compiled content types plus admin-defined dynamic
  # ones (D17) — the descriptors share a shape, and `ContentTypes` dispatch
  # routes dynamic kinds (name strings) to the generic entry tier.
  defp editable_types, do: ContentTypes.all() ++ ContentTypes.dynamic_all()

  @impl true
  def handle_event("new", %{"kind" => kind}, socket) do
    attrs = %{
      title: "Untitled #{kind}",
      slug: "untitled-#{System.unique_integer([:positive])}"
    }

    record = create!(kind, attrs, socket.assigns.actor)
    {:noreply, push_navigate(socket, to: edit_path(kind, record.id))}
  end

  # Filter state lives in the URL (audit U-M3): refresh, back button, and
  # shared links keep the active status/search/field filter. Typing replaces
  # the history entry so a search doesn't leave one entry per debounced
  # keystroke.
  def handle_event("filter", %{"status" => status}, socket) do
    {:noreply, push_patch(socket, to: list_path(%{path_params(socket.assigns) | status: status}))}
  end

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply,
     push_patch(socket, to: list_path(%{path_params(socket.assigns) | q: q}), replace: true)}
  end

  # The type-scope + custom-field controls, one form.
  def handle_event("refine", params, socket) do
    next = refine_params(path_params(socket.assigns), params)
    {:noreply, push_patch(socket, to: list_path(next), replace: true)}
  end

  def handle_event("toggle_select", %{"key" => key}, socket) do
    selected = socket.assigns.selected

    selected =
      if MapSet.member?(selected, key),
        do: MapSet.delete(selected, key),
        else: MapSet.put(selected, key)

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("toggle_select_all", _params, socket) do
    keys = visible_keys(socket)
    all_selected? = MapSet.size(keys) > 0 and MapSet.subset?(keys, socket.assigns.selected)

    selected =
      if all_selected?,
        do: MapSet.difference(socket.assigns.selected, keys),
        else: MapSet.union(socket.assigns.selected, keys)

    {:noreply, assign(socket, :selected, selected)}
  end

  # Every bulk verb goes through the same two-step confirmation (audit
  # U-H3/U-M2): "Select all" can hold hundreds of items, and a single stray
  # click could otherwise publish, unpublish or archive all of them instantly.
  def handle_event("bulk", %{"action" => verb}, socket)
      when verb in ~w(publish unpublish archive unarchive delete) do
    confirming = if MapSet.size(socket.assigns.selected) > 0, do: verb
    {:noreply, assign(socket, :confirming_bulk, confirming)}
  end

  def handle_event("cancel_bulk", _params, socket),
    do: {:noreply, assign(socket, :confirming_bulk, nil)}

  def handle_event("confirm_bulk", _params, socket) do
    verb = socket.assigns.confirming_bulk
    actor = socket.assigns.actor

    {ok, skipped} =
      Enum.reduce(socket.assigns.selected, {0, 0}, fn key, {ok, skipped} ->
        [kind, id] = String.split(key, ":", parts: 2)

        result =
          if verb == "delete",
            do: destroy(kind, id, actor),
            else: do_transition(kind, verb, get!(kind, id, actor), actor)

        case result do
          :ok -> {ok + 1, skipped}
          {:ok, _} -> {ok + 1, skipped}
          _ -> {ok, skipped + 1}
        end
      end)

    {:noreply,
     socket
     |> load_items()
     |> assign(:selected, MapSet.new())
     |> assign(:confirming_bulk, nil)
     |> put_flash(:info, bulk_flash(verb, ok, skipped))}
  end

  def handle_event("publish", params, socket),
    do: {:noreply, transition(socket, params, "publish")}

  def handle_event("submit", params, socket),
    do: {:noreply, transition(socket, params, "submit")}

  def handle_event("return", params, socket),
    do: {:noreply, transition(socket, params, "return")}

  def handle_event("unpublish", params, socket),
    do: {:noreply, transition(socket, params, "unpublish")}

  def handle_event("unarchive", params, socket),
    do: {:noreply, transition(socket, params, "unarchive")}

  def handle_event("load_more", _params, socket) do
    items = socket.assigns.items

    case List.last(items) do
      nil ->
        {:noreply, assign(socket, :more?, false)}

      {_kind, last} ->
        # Offset paging under a custom sort (see fetch_page), keyset otherwise.
        cursor = if custom_sort?(socket.assigns), do: length(items), else: last.updated_at
        {page, more?} = fetch_page(socket, cursor)

        {:noreply,
         socket
         |> assign(:items, items ++ page)
         |> assign(:more?, more?)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    status = if params["status"] in @statuses, do: params["status"], else: "all"

    # Everything below the type scope is validated against that type's field
    # definitions — a stale or hand-edited URL degrades to "no field filter",
    # never to a query error.
    scoped_type = find_type(params["type"])
    defs = custom_defs(scoped_type, socket.assigns.actor)

    filter_def = Enum.find(defs, &(&1.name == params["field"]))

    filter_op =
      case filter_def do
        nil -> "eq"
        definition -> validate_op(params["op"], ops_for(definition.field_type))
      end

    custom_sort = validate_custom_sort(params["csort"], defs)
    sort_def = Enum.find(defs, &(&1.name == String.trim_leading(custom_sort, "-")))

    {:noreply,
     socket
     |> assign(:status, status)
     |> assign(:query, params["q"] || "")
     |> assign(:scoped_type, scoped_type)
     |> assign(:custom_defs, defs)
     |> assign(:filter_def, filter_def)
     |> assign(:filter_op, filter_op)
     |> assign(:filter_value, (filter_def && params["value"]) || "")
     |> assign(:custom_sort, custom_sort)
     |> assign(:show_def, filter_def || sort_def)
     |> load_items()}
  end

  defp validate_op(op, allowed), do: if(op in allowed, do: op, else: hd(allowed))

  defp validate_custom_sort(nil, _defs), do: ""

  defp validate_custom_sort(csort, defs) do
    name = String.trim_leading(csort, "-")

    case Enum.find(defs, &(&1.name == name)) do
      %{} = definition -> if sortable?(definition), do: csort, else: ""
      nil -> ""
    end
  end

  # Fold a "refine" form change into the current URL params. Switching type
  # resets the field state (definitions differ per type); switching field
  # resets the operator and value (their meaning is per field type).
  defp refine_params(current, params) do
    type = Map.get(params, "type", "")
    field = Map.get(params, "field", "")
    csort = Map.get(params, "csort", "")

    cond do
      type != current.type ->
        %{current | type: type, field: "", op: "eq", value: "", csort: ""}

      field != current.field ->
        %{current | field: field, op: "eq", value: "", csort: csort}

      true ->
        %{
          current
          | op: Map.get(params, "op", "eq"),
            value: Map.get(params, "value", ""),
            csort: csort
        }
    end
  end

  # The current filter state as URL params (the single source of truth for
  # every push_patch).
  defp path_params(assigns) do
    %{
      status: assigns.status,
      q: assigns.query,
      type: (assigns.scoped_type && to_string(assigns.scoped_type.type)) || "",
      field: (assigns.filter_def && assigns.filter_def.name) || "",
      op: assigns.filter_op,
      value: assigns.filter_value,
      csort: assigns.custom_sort
    }
  end

  defp list_path(p) do
    # Field/op/value only mean something under a type scope, and op/value only
    # under a field — drop dependents of an empty parent along with defaults.
    p =
      cond do
        p.type == "" -> %{p | field: "", op: "eq", value: "", csort: ""}
        p.field == "" -> %{p | op: "eq", value: ""}
        true -> p
      end

    params =
      p
      |> Enum.reject(fn {k, v} ->
        v in [nil, ""] or (k == :status and v == "all") or (k == :op and p.field == "")
      end)
      |> Map.new()

    ~p"/editor?#{params}"
  end

  defp transition(socket, %{"kind" => kind, "id" => id}, verb) do
    actor = socket.assigns.actor
    record = get!(kind, id, actor)

    case do_transition(kind, verb, record, actor) do
      {:ok, _} -> socket |> load_items() |> put_flash(:info, gettext("Updated."))
      _ -> put_flash(socket, :error, gettext("That action isn't allowed right now."))
    end
  end

  defp create!(kind, attrs, actor), do: ContentTypes.create!(kind, attrs, actor: actor)

  defp get!(kind, id, actor), do: ContentTypes.get_record!(kind, id, actor: actor)

  defp do_transition(kind, verb, record, actor),
    do: ContentTypes.transition(kind, verb, record, actor: actor)

  # Hard delete (soft via archival). Admin-only; the policy rejects others, in
  # which case the item is counted as skipped.
  defp destroy(kind, id, actor),
    do: ContentTypes.destroy(kind, get!(kind, id, actor), actor: actor)

  # The set of selection keys ("kind:id") for the currently loaded items (the
  # status/search filter already ran server-side).
  defp visible_keys(socket) do
    MapSet.new(socket.assigns.items, fn {kind, r} -> "#{kind}:#{r.id}" end)
  end

  defp edit_path(type, id), do: ~p"/editor/content/#{type}/#{id}"

  defp bulk_actions(%{role: :admin}) do
    [
      {"publish", gettext("Publish")},
      {"unpublish", gettext("Unpublish")},
      {"archive", gettext("Archive")},
      {"unarchive", gettext("Unarchive")}
    ]
  end

  defp bulk_actions(_actor) do
    [
      {"unpublish", gettext("Unpublish")},
      {"archive", gettext("Archive")},
      {"unarchive", gettext("Unarchive")}
    ]
  end

  defp bulk_verb_label("publish"), do: gettext("Publish")
  defp bulk_verb_label("unpublish"), do: gettext("Unpublish")
  defp bulk_verb_label("archive"), do: gettext("Archive")
  defp bulk_verb_label("unarchive"), do: gettext("Unarchive")
  defp bulk_verb_label("delete"), do: gettext("Delete")

  # What the user is about to do, spelled out with its consequence. The delete
  # copy tells the truth about soft-delete (audit U-M1): items go to the trash,
  # restorable for 30 days — the old "This can't be undone" scared editors off
  # a recoverable action.
  defp bulk_confirm_prompt("publish", n),
    do:
      gettext("Publish %{count} selected item(s)? They go live on the site immediately.",
        count: n
      )

  defp bulk_confirm_prompt("unpublish", n),
    do:
      gettext("Unpublish %{count} selected item(s)? They come off the site and return to draft.",
        count: n
      )

  defp bulk_confirm_prompt("archive", n),
    do:
      gettext(
        "Archive %{count} selected item(s)? Archived content leaves the site; you can unarchive it later.",
        count: n
      )

  defp bulk_confirm_prompt("unarchive", n),
    do: gettext("Unarchive %{count} selected item(s)? They return to draft.", count: n)

  defp bulk_confirm_prompt("delete", n),
    do:
      gettext(
        "Move %{count} selected item(s) to trash? Admins can restore them from Trash for 30 days.",
        count: n
      )

  defp bulk_flash("delete", ok, skipped) do
    if skipped > 0,
      do:
        gettext("Moved %{count} item(s) to trash, %{skipped} skipped",
          count: ok,
          skipped: skipped
        ),
      else: gettext("Moved %{count} item(s) to trash", count: ok)
  end

  defp bulk_flash(verb, ok, skipped) do
    if skipped > 0,
      do:
        gettext("%{action}: %{count} updated, %{skipped} skipped",
          action: bulk_verb_label(verb),
          count: ok,
          skipped: skipped
        ),
      else: gettext("%{action}: %{count} updated", action: bulk_verb_label(verb), count: ok)
  end

  @impl true
  def render(assigns) do
    visible_keys = MapSet.new(assigns.items, fn {kind, r} -> "#{kind}:#{r.id}" end)

    assigns =
      assigns
      |> assign(
        :filtering?,
        assigns.status != "all" or assigns.query != "" or assigns.scoped_type != nil
      )
      |> assign(:selected_count, MapSet.size(assigns.selected))
      |> assign(
        :all_selected?,
        MapSet.size(visible_keys) > 0 and MapSet.subset?(visible_keys, assigns.selected)
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_user={@current_user}>
      <div class="space-y-6">
        <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <h1 class="text-2xl font-semibold">{gettext("Content")}</h1>
          <div class="flex flex-wrap items-center gap-2">
            <%!-- Media library discoverability from the editor (#156). --%>
            <.link
              navigate={~p"/media"}
              class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
            >
              {gettext("Media")}
            </.link>
            <.link
              navigate={~p"/editor/taxonomy"}
              class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
            >
              {gettext("Taxonomy")}
            </.link>
            <.link
              navigate={~p"/editor/analytics"}
              class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
            >
              {gettext("Analytics")}
            </.link>
            <.link
              :if={@actor.role == :admin}
              navigate={~p"/editor/webhooks"}
              class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
            >
              {gettext("Webhooks")}
            </.link>
            <.link
              :if={@actor.role == :admin}
              navigate={~p"/editor/mail"}
              class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
            >
              {gettext("Mail")}
            </.link>
            <.link
              :if={@actor.role == :admin}
              navigate={~p"/editor/trash"}
              class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
            >
              {gettext("Trash")}
            </.link>
            <.button
              :for={ct <- @content_types}
              type="button"
              phx-click="new"
              phx-value-kind={ct.type}
              variant="primary"
            >
              {gettext("New %{type}", type: String.downcase(ct.label))}
            </.button>
          </div>
        </div>

        <div :if={@items != [] or @filtering?} class="flex flex-wrap items-center gap-3">
          <form id="content-filter" phx-change="filter">
            <label for="content-status-filter" class="sr-only">{gettext("Filter by status")}</label>
            <select
              id="content-status-filter"
              name="status"
              aria-label={gettext("Filter by status")}
              class="rounded border border-base-content/20 bg-transparent px-2 py-1.5 text-sm"
            >
              <option :for={status <- @statuses} value={status} selected={status == @status}>
                {status_filter_label(status)}
              </option>
            </select>
          </form>
          <form id="content-search" phx-change="search" class="flex-1">
            <label for="content-search-input" class="sr-only">{gettext("Search by title")}</label>
            <input
              id="content-search-input"
              type="text"
              name="q"
              value={@query}
              placeholder={gettext("Search by title")}
              aria-label={gettext("Search by title")}
              phx-debounce="200"
              autocomplete="off"
              class="w-full max-w-xs rounded border border-base-content/20 bg-transparent px-3 py-1.5 text-sm"
            />
          </form>
          <form id="content-refine" phx-change="refine" class="flex flex-wrap items-center gap-2">
            <label for="content-type-filter" class="sr-only">{gettext("Filter by type")}</label>
            <select
              id="content-type-filter"
              name="type"
              aria-label={gettext("Filter by type")}
              class="rounded border border-base-content/20 bg-transparent px-2 py-1.5 text-sm"
            >
              <option value="" selected={@scoped_type == nil}>{gettext("All types")}</option>
              <option
                :for={ct <- @content_types}
                value={to_string(ct.type)}
                selected={@scoped_type && @scoped_type.type == ct.type}
              >
                {ct.label}
              </option>
            </select>

            <%= if @scoped_type && @custom_defs != [] do %>
              <label for="content-field-filter" class="sr-only">
                {gettext("Filter by custom field")}
              </label>
              <select
                id="content-field-filter"
                name="field"
                aria-label={gettext("Filter by custom field")}
                class="rounded border border-base-content/20 bg-transparent px-2 py-1.5 text-sm"
              >
                <option value="" selected={@filter_def == nil}>{gettext("Any field")}</option>
                <option
                  :for={d <- @custom_defs}
                  value={d.name}
                  selected={@filter_def && @filter_def.name == d.name}
                >
                  {d.label}
                </option>
              </select>

              <%= if @filter_def do %>
                <label for="content-op-filter" class="sr-only">{gettext("Filter operator")}</label>
                <select
                  id="content-op-filter"
                  name="op"
                  aria-label={gettext("Filter operator")}
                  class="rounded border border-base-content/20 bg-transparent px-2 py-1.5 text-sm"
                >
                  <option
                    :for={op <- ops_for(@filter_def.field_type)}
                    value={op}
                    selected={op == @filter_op}
                  >
                    {op_label(op)}
                  </option>
                </select>

                <%= if @filter_op not in ["set", "unset"] do %>
                  <label for="content-value-filter" class="sr-only">{gettext("Filter value")}</label>
                  <%= case value_input_kind(@filter_def) do %>
                    <% :select -> %>
                      <select
                        id="content-value-filter"
                        name="value"
                        aria-label={gettext("Filter value")}
                        class="rounded border border-base-content/20 bg-transparent px-2 py-1.5 text-sm"
                      >
                        <option value="" selected={@filter_value == ""}>{gettext("Choose…")}</option>
                        <option
                          :for={opt <- value_options(@filter_def)}
                          value={opt}
                          selected={@filter_value == opt}
                        >
                          {opt}
                        </option>
                      </select>
                    <% input_type -> %>
                      <input
                        id="content-value-filter"
                        type={input_type}
                        step={@filter_def.field_type == :float && "any"}
                        name="value"
                        value={@filter_value}
                        aria-label={gettext("Filter value")}
                        phx-debounce="300"
                        autocomplete="off"
                        class="w-40 rounded border border-base-content/20 bg-transparent px-2 py-1.5 text-sm"
                      />
                  <% end %>
                <% end %>
              <% end %>

              <label for="content-custom-sort" class="sr-only">{gettext("Sort by")}</label>
              <select
                id="content-custom-sort"
                name="csort"
                aria-label={gettext("Sort by")}
                class="rounded border border-base-content/20 bg-transparent px-2 py-1.5 text-sm"
              >
                <option value="" selected={@custom_sort == ""}>
                  {gettext("Sort: last updated")}
                </option>
                <%= for d <- @custom_defs, sortable?(d) do %>
                  <option value={d.name} selected={@custom_sort == d.name}>{d.label} ↑</option>
                  <option value={"-" <> d.name} selected={@custom_sort == "-" <> d.name}>
                    {d.label} ↓
                  </option>
                <% end %>
              </select>
            <% end %>
          </form>
        </div>

        <div
          :if={@items != []}
          class="flex flex-wrap items-center gap-3 rounded border border-base-content/10 bg-base-200/40 px-3 py-2"
        >
          <label class="flex items-center gap-2 text-sm">
            <input type="checkbox" checked={@all_selected?} phx-click="toggle_select_all" />
            {gettext("Select all")}
          </label>
          <span class="text-sm text-base-content/60">
            {if @selected_count > 0,
              do: gettext("%{count} selected", count: @selected_count),
              else: gettext("None selected")}
          </span>
          <div class="ml-auto flex gap-2">
            <button
              :for={{verb, label} <- bulk_actions(@actor)}
              type="button"
              phx-click="bulk"
              phx-value-action={verb}
              disabled={@selected_count == 0}
              class="rounded border border-base-content/20 px-3 py-1 text-xs hover:bg-base-200 disabled:cursor-not-allowed disabled:opacity-40"
            >
              {label}
            </button>
            <button
              :if={@actor.role == :admin}
              type="button"
              phx-click="bulk"
              phx-value-action="delete"
              disabled={@selected_count == 0}
              class="rounded border border-error/40 px-3 py-1 text-xs text-error hover:bg-error/10 disabled:cursor-not-allowed disabled:opacity-40"
            >
              {gettext("Delete")}
            </button>
          </div>
        </div>

        <div
          :if={@confirming_bulk}
          class={[
            "flex flex-wrap items-center gap-3 rounded border px-3 py-2 text-sm",
            (@confirming_bulk == "delete" && "border-error/40 bg-error/10") ||
              "border-warning/40 bg-warning/10"
          ]}
        >
          <span>{bulk_confirm_prompt(@confirming_bulk, @selected_count)}</span>
          <div class="ml-auto flex gap-2">
            <button
              type="button"
              phx-click="confirm_bulk"
              class={[
                "rounded px-3 py-1 text-xs font-medium hover:opacity-90",
                (@confirming_bulk == "delete" && "bg-error text-error-content") ||
                  "bg-warning text-warning-content"
              ]}
            >
              {bulk_verb_label(@confirming_bulk)}
            </button>
            <button
              type="button"
              phx-click="cancel_bulk"
              class="rounded border border-base-content/20 px-3 py-1 text-xs hover:bg-base-200"
            >
              {gettext("Cancel")}
            </button>
          </div>
        </div>

        <.empty_state
          :if={@items == [] and not @filtering?}
          icon="hero-document-text"
          title={gettext("No content yet")}
        >
          {gettext("Create your first page or post to get started.")}
        </.empty_state>
        <p :if={@items == [] and @filtering?} class="text-sm text-base-content/60" role="status">
          {gettext("Nothing matches the current filter.")}
        </p>

        <ul
          :if={@items != []}
          class="divide-y divide-base-content/10 rounded border border-base-content/10"
        >
          <li
            :for={{kind, record} <- @items}
            id={"#{kind}-#{record.id}"}
            class="flex flex-wrap items-center gap-x-3 gap-y-2 p-3"
          >
            <input
              type="checkbox"
              checked={MapSet.member?(@selected, "#{kind}:#{record.id}")}
              phx-click="toggle_select"
              phx-value-key={"#{kind}:#{record.id}"}
              aria-label={gettext("Select %{title}", title: record.title)}
              class="size-4 shrink-0 rounded border border-base-content/30 accent-primary"
            />
            <span class="shrink-0 text-xs uppercase text-base-content/70">{kind}</span>
            <div class="min-w-0 flex-1">
              <.link navigate={edit_path(kind, record.id)} class="font-medium hover:underline">
                {record.title}
              </.link>
              <p class="truncate text-xs text-base-content/70">/{record.slug}</p>
            </div>
            <.state_badge state={record.state} />
            <span
              :if={@show_def}
              class="rounded bg-base-200 px-2 py-0.5 text-xs text-base-content/70"
              title={@show_def.label}
            >
              {@show_def.label}: {display_custom_value(record, @show_def)}
            </span>
            <span
              :if={record.scheduled_at && record.state in [:draft, :in_review]}
              class="flex items-center gap-1 text-xs text-base-content/60"
              title={gettext("Scheduled to publish")}
            >
              <.icon name="hero-clock" class="size-3.5" />
              <time
                id={"scheduled-#{kind}-#{record.id}"}
                phx-hook="LocalTime"
                datetime={DateTime.to_iso8601(record.scheduled_at)}
              >{Calendar.strftime(record.scheduled_at, "%Y-%m-%d %H:%M")} UTC</time>
            </span>
            <span
              :if={record.unpublish_at && record.state == :published}
              class="flex items-center gap-1 text-xs text-base-content/60"
              title={gettext("Scheduled to unpublish")}
            >
              <.icon name="hero-clock" class="size-3.5" />
              <time
                id={"unpublish-#{kind}-#{record.id}"}
                phx-hook="LocalTime"
                datetime={DateTime.to_iso8601(record.unpublish_at)}
              >{Calendar.strftime(record.unpublish_at, "%Y-%m-%d %H:%M")} UTC</time>
            </span>
            <div class="flex w-full items-center justify-end gap-2 sm:w-auto">
              <button
                :if={record.state == :draft and @actor.role == :editor}
                type="button"
                phx-click="submit"
                phx-value-kind={kind}
                phx-value-id={record.id}
                class="rounded border border-base-content/20 px-2 py-1 text-xs hover:bg-base-200"
              >
                {gettext("Submit")}
              </button>
              <button
                :if={record.state in [:draft, :in_review] and @actor.role == :admin}
                type="button"
                phx-click="publish"
                phx-value-kind={kind}
                phx-value-id={record.id}
                class="rounded border border-base-content/20 px-2 py-1 text-xs hover:bg-base-200"
              >
                {if record.state == :in_review, do: gettext("Approve"), else: gettext("Publish")}
              </button>
              <button
                :if={record.state == :in_review and @actor.role == :admin}
                type="button"
                phx-click="return"
                phx-value-kind={kind}
                phx-value-id={record.id}
                class="rounded border border-base-content/20 px-2 py-1 text-xs hover:bg-base-200"
              >
                {gettext("Return")}
              </button>
              <button
                :if={record.state == :published}
                type="button"
                phx-click="unpublish"
                phx-value-kind={kind}
                phx-value-id={record.id}
                class="rounded border border-base-content/20 px-2 py-1 text-xs hover:bg-base-200"
              >
                {gettext("Unpublish")}
              </button>
              <button
                :if={record.state == :archived}
                type="button"
                phx-click="unarchive"
                phx-value-kind={kind}
                phx-value-id={record.id}
                class="rounded border border-base-content/20 px-2 py-1 text-xs hover:bg-base-200"
              >
                {gettext("Unarchive")}
              </button>
              <.link
                navigate={edit_path(kind, record.id)}
                class="rounded border border-base-content/20 px-2 py-1 text-xs hover:bg-base-200"
              >
                {gettext("Edit")}
              </.link>
            </div>
          </li>
        </ul>

        <div :if={@more?} class="flex justify-center">
          <button
            type="button"
            phx-click="load_more"
            phx-disable-with={gettext("Loading…")}
            class="rounded border border-base-content/20 px-4 py-1.5 text-sm hover:bg-base-200"
          >
            {gettext("Load more")}
          </button>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Humanized, localized labels for the status-filter <select> (#155). Accepts a
  # filter value string, including the "all" pseudo-state, or a workflow-state
  # atom. The content-state badge itself uses CoreComponents.state_badge/1.
  defp status_filter_label("all"), do: gettext("All")

  defp status_filter_label(state) when is_binary(state),
    do: status_filter_label(String.to_existing_atom(state))

  defp status_filter_label(:draft), do: gettext("Draft")
  defp status_filter_label(:in_review), do: gettext("In review")
  defp status_filter_label(:published), do: gettext("Published")
  defp status_filter_label(:archived), do: gettext("Archived")

  defp status_filter_label(other) when is_atom(other),
    do: other |> to_string() |> String.replace("_", " ") |> String.capitalize()
end
