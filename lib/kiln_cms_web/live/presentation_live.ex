defmodule KilnCMSWeb.PresentationLive do
  @moduledoc """
  Visual-editing **Presentation console** (#355) — side-by-side editing of an
  external headless front end.

  The left pane iframes the front end's preview URL (see `KilnCMSWeb.Presentation`);
  the front end runs `bridge.js` in edit mode, so clicking a rendered region
  `postMessage`s `{source: "kiln-bridge", event: "edit", payload}` up to this
  console (relayed by the `PresentationFrame` hook, origin-validated). The console
  opens that block's field in the right-hand pane, edits it with the same
  contenteditable hooks the in-context editor uses, and Save writes through the
  shared `KilnCMSWeb.InlineEditing` engine (Ash `:update`, policies + PaperTrail
  native). On save it broadcasts on the `content_preview:<kind>:<id>` topic — the
  `/ws/bridge` socket forwards an update to `bridge.js`, which re-fetches — and
  also nudges the iframe to refresh directly.

  Kiln *enables* this; the external front end opts in (embed the SDK, render the
  annotated preview). For Kiln's own site, editing is in-app (#354).
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMSWeb.InlineEditing
  alias KilnCMSWeb.Presentation
  alias KilnCMSWeb.PreviewLive

  # Document scalars the console can edit inline (clicked when they have no block
  # in the stega payload). Whether a given scalar is actually editable for THIS
  # type is decided by `scalar_supported?/2` — `excerpt` only exists on types
  # declared with `excerpt?: true` (e.g. Post, not Page).
  @scalar_fields ~w(title excerpt)

  @impl true
  def mount(%{"type" => type, "slug" => slug} = params, _session, socket) do
    actor = socket.assigns.current_user
    locale = locale_param(params)

    with ct when not is_nil(ct) <- ContentTypes.get(type),
         record when not is_nil(record) <-
           fetch_by_slug(ct.type, slug, locale, actor, socket.assigns.current_org),
         # `{false, ct, record}` rather than a bare `false`: the else-branch
         # needs the record's ID to send the reader to the read-only surface,
         # and a `with` clause that fails hands on only what it matched.
         {true, _ct, _record} <-
           {may_write?(record, actor, socket.assigns.current_org), ct, record} do
      {:ok,
       socket
       # Decided once, re-asserted at the write — see `save` below.
       |> assign(:may_write?, true)
       |> assign(:kind, ct.type)
       |> assign(:ct, ct)
       |> assign(:actor, actor)
       |> assign(:preview_url, Presentation.preview_url(ct, record))
       |> assign(:frontend_origin, Presentation.frontend_origin())
       |> assign(:editing, nil)
       |> assign(:scalar_changes, %{})
       |> assign(:save_state, :saved)
       |> assign(:conflict, false)
       |> assign(:region_version, 0)
       |> assign_record(record)}
    else
      # Separated from "no such content" because it is a different answer, and
      # the reader gets the read-only surface rather than an editor that accepts
      # a page of typing and refuses all of it on Save (#1159).
      {false, ct, record} ->
        {:ok,
         socket
         |> put_flash(:info, gettext("You can view this content but not edit it."))
         |> push_navigate(to: ~p"/editor/preview/#{ct.type}/#{record.id}")}

      _ ->
        {:ok, redirect_to_editor(socket, gettext("No such content to edit."))}
    end
  end

  # Whether the actor may WRITE this record, the concept this console never had
  # (#1159). The editor-tier live_session is coarser than it looks:
  # `Checks.ReadableContentType` lets an editor restricted to other types read
  # this one as a signed-in consumer does, so they could open a published page
  # they may not author and find every inline field editable.
  #
  # Keyed on `:autosave`, the same action `ContentEditorLive` asks about, so the
  # consoles cannot disagree about who may edit a record.
  defp may_write?(record, actor, org), do: Ash.can?({record, :autosave}, actor, tenant: org)

  # Scope to the current site's org (epic #336) so the Presentation console on
  # one site's host only resolves that site's content.
  #
  # Locale is part of the identity (`[slug, locale]`). Absent `?locale=` falls
  # back to the default — an older bridge or a hand-typed URL (#1104).
  defp fetch_by_slug(kind, slug, locale, actor, org) do
    case ContentTypes.list!(kind,
           actor: actor,
           tenant: org,
           query: [
             filter: [slug: slug, locale: locale],
             select: [:id],
             limit: 1
           ]
         ) do
      [%{id: id} | _] ->
        ContentTypes.get_record!(kind, id, actor: actor, tenant: org, load: [:featured_image])

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp locale_param(params) do
    KilnCMSWeb.Params.string(params, "locale", KilnCMS.I18n.default_locale())
  end

  defp do_save(socket) do
    changes =
      socket.assigns.scalar_changes
      |> Map.new(fn {field, value} -> {String.to_existing_atom(field), value} end)
      |> Map.put(:blocks, socket.assigns.block_inputs)

    case InlineEditing.write_changes(
           socket.assigns.record,
           :update,
           changes,
           socket.assigns.actor
         ) do
      {:ok, record} ->
        {:noreply,
         socket
         |> assign_record(record)
         |> update(:region_version, &(&1 + 1))
         |> assign(:save_state, :saved)
         |> assign(:conflict, false)
         |> broadcast_preview()
         |> push_event("presentation:refresh", %{})
         |> put_flash(:info, gettext("Saved."))}

      :conflict ->
        {:noreply,
         socket
         |> assign(:conflict, true)
         |> assign(:save_state, :unsaved)
         |> put_flash(:error, gettext("This content changed elsewhere. Reload before saving."))}

      {:error, _error} ->
        {:noreply,
         socket
         |> assign(:save_state, :error)
         |> put_flash(:error, gettext("Could not save. Please try again."))}
    end
  end

  defp assign_record(socket, record) do
    typed = TypedBlocks.to_typed(record.blocks)

    socket
    |> assign(:record, record)
    |> assign(:page_title, gettext("Presentation: %{title}", title: record.title))
    |> assign(:scalar_changes, %{})
    |> assign(:block_inputs, InlineEditing.block_inputs(typed))
    |> assign(:blocks, InlineEditing.editable_blocks(typed))
  end

  # ── events ──────────────────────────────────────────────────────────────────

  @impl true
  # The bridge posts the stega payload `{type, id, slug, locale, field, block}`.
  # Open the clicked block in the pane when it's inline-editable; a document
  # scalar (no block — e.g. `title`) opens a scalar input; anything else offers
  # the full editor. A payload naming a different document is refused (#1104) —
  # shared block ids across locale variants must not write into the wrong one.
  def handle_event("edit_field", payload, socket) when is_map(payload) do
    if foreign_record_payload?(payload, socket) do
      {:noreply, assign(socket, :editing, {:unsupported, payload["field"] || "content"})}
    else
      open_edit_field(payload, socket)
    end
  end

  defp open_edit_field(%{"block" => block_id} = payload, socket) when is_binary(block_id) do
    case Enum.find(socket.assigns.blocks, &(&1.id == block_id and &1.field != nil)) do
      nil -> {:noreply, assign(socket, :editing, {:unsupported, payload["field"] || "content"})}
      block -> {:noreply, assign(socket, :editing, block)}
    end
  end

  defp open_edit_field(%{"field" => field}, socket) when field in @scalar_fields do
    if scalar_supported?(socket, field) do
      {:noreply, assign(socket, :editing, {:scalar, field, scalar_value(socket, field)})}
    else
      # e.g. clicking `excerpt` on a type without one — the `:update` action
      # wouldn't accept it, so offer the full editor instead of a panel that
      # can't save.
      {:noreply, assign(socket, :editing, {:unsupported, field})}
    end
  end

  defp open_edit_field(payload, socket) do
    {:noreply, assign(socket, :editing, {:unsupported, payload["field"] || "content"})}
  end

  defp foreign_record_payload?(%{"id" => id}, socket) when is_binary(id) do
    id != to_string(socket.assigns.record.id)
  end

  defp foreign_record_payload?(_payload, _socket), do: false

  # A document scalar input (title/excerpt) changed.
  def handle_event("update_scalar", %{"field" => field, "value" => value}, socket)
      when field in @scalar_fields and is_binary(value) do
    {:noreply,
     socket
     |> update(:scalar_changes, &Map.put(&1, field, value))
     |> update(:editing, fn
       {:scalar, ^field, _old} -> {:scalar, field, value}
       other -> other
     end)
     |> assign(:save_state, :unsaved)}
  end

  # A contenteditable region (InlineText/InlineRichText hook) pushed a new value.
  # Binary for a plain region, a TipTap document (a map) for a rich one — both
  # are the contract, a list is not. See `InContextEditLive.handle_event/3` for
  # why that one shape matters.
  def handle_event("update_block", %{"id" => id, "value" => value}, socket)
      when is_binary(id) and (is_binary(value) or is_map(value)) do
    case block_index(socket, id) do
      {:ok, index, field} ->
        inputs = InlineEditing.put_block_field(socket.assigns.block_inputs, index, field, value)

        {:noreply,
         socket
         |> assign(:block_inputs, inputs)
         |> assign(:save_state, :unsaved)}

      :error ->
        {:noreply, socket}
    end
  end

  # The mount decision, re-asserted at the write, for the reason
  # `InContextEditLive.persist/2` states: the mount refusal ends the LiveView,
  # so it holds only by accident of how it is spelled. Same caveat too — the
  # decision was taken from a mount-time actor, so this guards a future
  # refactor of that refusal, not a scope narrowed mid-session.
  #
  # It says so rather than returning silently: a Save button that does nothing
  # at all is indistinguishable from a broken one.
  def handle_event("save", _params, socket) do
    if socket.assigns.may_write? do
      do_save(socket)
    else
      {:noreply,
       socket
       |> assign(:save_state, :error)
       |> put_flash(:error, gettext("You can view this content but not edit it."))}
    end
  end

  def handle_event("close_panel", _params, socket), do: {:noreply, assign(socket, :editing, nil)}

  def handle_event("reload", _params, socket) do
    record =
      ContentTypes.get_record!(socket.assigns.kind, socket.assigns.record.id,
        actor: socket.assigns.actor
      )

    {:noreply,
     socket
     |> assign_record(record)
     |> update(:region_version, &(&1 + 1))
     |> assign(:conflict, false)
     |> assign(:save_state, :saved)
     |> assign(:editing, nil)}
  end

  # `title` is universal; `excerpt` exists only on types declared `excerpt?: true`.
  defp scalar_supported?(_socket, "title"), do: true
  defp scalar_supported?(socket, "excerpt"), do: socket.assigns.ct.excerpt?
  defp scalar_supported?(_socket, _field), do: false

  # The current value of a document scalar — a pending edit if any, else the record.
  defp scalar_value(socket, field) do
    case Map.fetch(socket.assigns.scalar_changes, field) do
      {:ok, pending} -> pending
      :error -> to_string(Map.get(socket.assigns.record, String.to_existing_atom(field)) || "")
    end
  end

  defp block_index(socket, id) do
    case Enum.find(socket.assigns.blocks, &(&1.id == id and &1.field != nil)) do
      %{index: index, field: field} -> {:ok, index, field}
      _ -> :error
    end
  end

  # Publish the working draft on the same topic the structured editor uses, so the
  # `/ws/bridge` socket forwards an update to bridge.js in the iframe.
  defp broadcast_preview(socket) do
    payload = %{
      title: socket.assigns.record.title,
      excerpt: Map.get(socket.assigns.record, :excerpt),
      blocks: socket.assigns.block_inputs
    }

    Phoenix.PubSub.broadcast(
      KilnCMS.PubSub,
      PreviewLive.topic(socket.assigns.kind, socket.assigns.record.id),
      {:preview_update, payload}
    )

    socket
  end

  defp redirect_to_editor(socket, message) do
    socket |> put_flash(:error, message) |> push_navigate(to: ~p"/editor")
  end

  # ── render ────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-[calc(100vh-4rem)] flex-col">
      <%!-- The presentation console wraps no layout component, so the console's
            environment strip can never reach it — it has to be drawn here (#469). --%>
      <KilnCMSWeb.Layouts.environment_banner />
      <div class="flex items-center justify-between border-b border-base-300 bg-base-100 px-4 py-2">
        <div class="flex items-center gap-3">
          <.link navigate={~p"/editor/content/#{@kind}/#{@record.id}"} class="text-sm underline">
            {gettext("Full editor")}
          </.link>
          <span class="text-sm font-medium">{@record.title}</span>
          <.state_badge state={@record.state} />
        </div>
        <span class="text-xs text-base-content/60">{save_label(@save_state)}</span>
      </div>

      <div class="flex min-h-0 flex-1">
        <%!-- Left: the external front end, framed. --%>
        <div class="min-w-0 flex-1 bg-base-200">
          <div :if={is_nil(@preview_url)} class="flex h-full items-center justify-center p-8">
            <div class="max-w-md text-center text-sm text-base-content/70">
              <p class="font-medium">{gettext("No preview URL configured.")}</p>
              <p class="mt-2">
                {gettext(
                  "Set PRESENTATION_PREVIEW_URL to your front end (e.g. https://site.example.com{path}) to enable side-by-side editing."
                )}
              </p>
            </div>
          </div>

          <iframe
            :if={@preview_url}
            id="presentation-frame"
            phx-hook="PresentationFrame"
            data-frontend-origin={@frontend_origin}
            src={@preview_url}
            title={gettext("Front-end preview")}
            class="h-full w-full border-0"
          ></iframe>
        </div>

        <%!-- Right: the field edit pane. --%>
        <aside class="flex w-96 flex-col border-l border-base-300 bg-base-100">
          <div :if={is_nil(@editing)} class="flex h-full items-center justify-center p-6 text-center">
            <p class="text-sm text-base-content/60">
              {gettext("Click a highlighted region in your site to edit it here.")}
            </p>
          </div>

          <div :if={match?({:unsupported, _}, @editing)} class="p-6 text-sm">
            <p class="text-base-content/70">
              {gettext("This field isn't inline-editable here.")}
            </p>
            <.link
              navigate={~p"/editor/content/#{@kind}/#{@record.id}"}
              class="mt-3 inline-block underline"
            >
              {gettext("Open the full editor")}
            </.link>
          </div>

          <div :if={match?({:scalar, _, _}, @editing)} class="flex min-h-0 flex-1 flex-col">
            <% {:scalar, field, value} = @editing %>
            <div class="flex items-center justify-between border-b border-base-300 px-4 py-2">
              <span class="text-xs font-medium uppercase tracking-wide text-base-content/60">
                {@kind} · {field}
              </span>
              <button type="button" phx-click="close_panel" class="text-xs underline">
                {gettext("Close")}
              </button>
            </div>
            <div class="min-h-0 flex-1 overflow-auto p-4">
              <form id="scalar-edit-form" phx-change="update_scalar" phx-submit="save">
                <input type="hidden" name="field" value={field} />
                <input
                  type="text"
                  name="value"
                  value={value}
                  phx-debounce="200"
                  class="field-input w-full"
                  aria-label={field}
                />
              </form>
            </div>
            <.save_footer conflict={@conflict} save_state={@save_state} />
          </div>

          <div :if={is_map(@editing)} class="flex min-h-0 flex-1 flex-col">
            <div class="flex items-center justify-between border-b border-base-300 px-4 py-2">
              <span class="text-xs font-medium uppercase tracking-wide text-base-content/60">
                {@editing.type} · {@editing.field}
              </span>
              <button
                type="button"
                phx-click="close_panel"
                class="text-xs underline"
                aria-label={gettext("Close")}
              >
                {gettext("Close")}
              </button>
            </div>

            <div class="min-h-0 flex-1 overflow-auto p-4">
              <.edit_region block={@editing} version={@region_version} />
            </div>

            <.save_footer conflict={@conflict} save_state={@save_state} />
          </div>
        </aside>
      </div>
    </div>
    """
  end

  # Shared Save/Reload footer for the edit pane.
  defp save_footer(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-2 border-t border-base-300 px-4 py-3">
      <button :if={@conflict} type="button" phx-click="reload" class="btn btn-sm btn-ghost">
        {gettext("Reload")}
      </button>
      <button
        type="button"
        phx-click="save"
        disabled={@save_state == :saved}
        class="btn btn-sm btn-primary ml-auto"
      >
        {gettext("Save")}
      </button>
    </div>
    """
  end

  # One editable region — the same contenteditable hooks the in-context editor
  # uses, so text/rich-text editing behaves identically.
  defp edit_region(%{block: %{mode: :html}} = assigns) do
    ~H"""
    <div
      id={InlineEditing.region_id(@block, @version)}
      phx-hook="InlineRichText"
      phx-update="ignore"
      data-kiln-block-id={@block.id}
      data-kiln-block-mode="html"
      data-content={@block.value}
      class="kiln-block min-h-24 rounded border border-base-300 p-2"
    >
      {Phoenix.HTML.raw(@block.value)}
    </div>
    """
  end

  defp edit_region(%{block: %{type: "quote"}} = assigns) do
    ~H"""
    <blockquote
      id={InlineEditing.region_id(@block, @version)}
      phx-hook="InlineText"
      phx-update="ignore"
      contenteditable="true"
      data-kiln-block-id={@block.id}
      class="min-h-16 rounded border border-base-300 p-2"
    >{@block.value}</blockquote>
    """
  end

  defp edit_region(assigns) do
    ~H"""
    <div
      id={InlineEditing.region_id(@block, @version)}
      phx-hook="InlineText"
      phx-update="ignore"
      contenteditable="true"
      data-kiln-block-id={@block.id}
      class="min-h-16 rounded border border-base-300 p-2 text-lg font-semibold"
    >{@block.value}</div>
    """
  end

  defp save_label(:saved), do: gettext("All changes saved")
  defp save_label(:unsaved), do: gettext("Unsaved changes")
  defp save_label(:error), do: gettext("Save failed")
  defp save_label(_), do: ""
end
