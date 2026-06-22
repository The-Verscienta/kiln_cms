defmodule KilnCMSWeb.ContentEditorLive do
  @moduledoc """
  Block editor for a single Page **or** Post (the `live_action` — `:page` /
  `:post` — selects which). Edit title/slug (+ excerpt for posts) and the
  embedded block tree (add/remove/reorder via the `Sortable` hook), with
  **TipTap rich text** for `rich_text` blocks, a **side-by-side live preview**
  (`KilnCMSWeb.BlockComponents`), SEO & scheduling, version history + restore,
  and the publishing workflow. Editor/admin only.

  Page/Post differences are dispatched through the uniform `*_page` / `*_post`
  domain code interfaces.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMSWeb.BlockComponents
  alias KilnCMSWeb.Presence

  @block_types ~w(rich_text heading quote image embed divider)

  # Stable per-collaborator colors for live focus cursors. Static class strings
  # so Tailwind keeps them.
  @cursor_colors ~w(
    bg-rose-500 bg-amber-500 bg-emerald-500 bg-sky-500 bg-violet-500 bg-pink-500
  )

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    kind = socket.assigns.live_action
    actor = socket.assigns.current_user
    record = fetch!(kind, id, actor)

    if connected?(socket) do
      topic = Presence.track_editor(self(), kind, id, actor)
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, topic)
    end

    {:ok,
     socket
     |> assign(:kind, kind)
     |> assign(:actor, actor)
     |> assign(:block_types, @block_types)
     |> assign(:editors, Presence.editors(kind, id))
     |> assign(:cursors, %{})
     |> assign_record(record)}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    editors = Presence.editors(socket.assigns.kind, socket.assigns.record.id)
    # Drop cursors for anyone who has left, so stale focus badges disappear.
    present = MapSet.new(editors, & &1.id)
    cursors = Map.filter(socket.assigns.cursors, fn {id, _} -> MapSet.member?(present, id) end)
    {:noreply, assign(socket, editors: editors, cursors: cursors)}
  end

  # A collaborator focused (field set) or left (field nil) a field. Ignore our
  # own echo — we only render *other* people's cursors.
  def handle_info({:cursor, %{id: id} = cursor}, socket) do
    cursors =
      cond do
        id == socket.assigns.actor.id -> socket.assigns.cursors
        is_nil(cursor.field) -> Map.delete(socket.assigns.cursors, id)
        true -> Map.put(socket.assigns.cursors, id, put_color(cursor))
      end

    {:noreply, assign(socket, :cursors, cursors)}
  end

  defp assign_record(socket, record) do
    socket
    |> assign(:record, record)
    |> assign(:form, build_form(record, socket.assigns.actor))
    |> load_versions()
  end

  defp load_versions(socket) do
    opts = [
      actor: socket.assigns.actor,
      query: [
        filter: [version_source_id: socket.assigns.record.id],
        sort: [version_inserted_at: :desc],
        limit: 15
      ]
    ]

    assign(socket, :versions, list_versions(socket.assigns.kind, opts))
  end

  defp build_form(record, actor) do
    record
    |> AshPhoenix.Form.for_update(:update, actor: actor, forms: [auto?: true])
    |> to_form()
  end

  # --- Page/Post dispatch to the per-kind code interfaces --------------------

  defp fetch!(:page, id, actor), do: CMS.get_page!(id, actor: actor)
  defp fetch!(:post, id, actor), do: CMS.get_post!(id, actor: actor)

  defp list_versions(:page, opts), do: CMS.list_page_versions!(opts)
  defp list_versions(:post, opts), do: CMS.list_post_versions!(opts)

  defp restore_version(:page, record, vid, actor),
    do: CMS.restore_page_version(record, %{version_id: vid}, actor: actor)

  defp restore_version(:post, record, vid, actor),
    do: CMS.restore_post_version(record, %{version_id: vid}, actor: actor)

  defp do_workflow(:page, "publish", r, a), do: CMS.publish_page(r, %{}, actor: a)
  defp do_workflow(:post, "publish", r, a), do: CMS.publish_post(r, %{}, actor: a)
  defp do_workflow(:page, "unpublish", r, a), do: CMS.unpublish_page(r, %{}, actor: a)
  defp do_workflow(:post, "unpublish", r, a), do: CMS.unpublish_post(r, %{}, actor: a)
  defp do_workflow(:page, "submit", r, a), do: CMS.submit_page_for_review(r, %{}, actor: a)
  defp do_workflow(:post, "submit", r, a), do: CMS.submit_post_for_review(r, %{}, actor: a)
  defp do_workflow(:page, "archive", r, a), do: CMS.archive_page(r, %{}, actor: a)
  defp do_workflow(:post, "archive", r, a), do: CMS.archive_post(r, %{}, actor: a)

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    socket = assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, params))
    broadcast_preview(socket)
    {:noreply, socket}
  end

  def handle_event("field_focus", %{"field" => field}, socket) do
    broadcast_cursor(socket, field)
    {:noreply, socket}
  end

  def handle_event("field_blur", _params, socket) do
    broadcast_cursor(socket, nil)
    {:noreply, socket}
  end

  def handle_event("add_block", %{"type" => type}, socket) do
    form =
      AshPhoenix.Form.add_form(socket.assigns.form, socket.assigns.form.name <> "[blocks]",
        params: %{"type" => type, "content" => ""}
      )

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("remove_block", %{"path" => path}, socket) do
    {:noreply, assign(socket, :form, AshPhoenix.Form.remove_form(socket.assigns.form, path))}
  end

  def handle_event("reorder", %{"order" => order}, socket) do
    form = AshPhoenix.Form.sort_forms(socket.assigns.form, [:blocks], order)
    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, record} ->
        {:noreply, socket |> assign_record(record) |> put_flash(:info, "Saved.")}

      {:error, form} ->
        {:noreply,
         socket |> assign(:form, form) |> put_flash(:error, "Please fix the errors below.")}
    end
  end

  def handle_event("workflow", %{"action" => action}, socket) do
    {:noreply, run_workflow(socket, action)}
  end

  def handle_event("restore", %{"version_id" => version_id}, socket) do
    result =
      restore_version(
        socket.assigns.kind,
        socket.assigns.record,
        version_id,
        socket.assigns.actor
      )

    case result do
      {:ok, record} ->
        {:noreply, socket |> assign_record(record) |> put_flash(:info, "Restored that version.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Couldn't restore that version.")}
    end
  end

  defp run_workflow(socket, action) when action in ~w(submit publish unpublish archive) do
    result =
      do_workflow(socket.assigns.kind, action, socket.assigns.record, socket.assigns.actor)

    case result do
      {:ok, record} ->
        socket |> assign_record(record) |> put_flash(:info, "Updated to #{record.state}.")

      _ ->
        put_flash(socket, :error, "That action isn't allowed right now.")
    end
  end

  defp run_workflow(socket, _action), do: socket

  # Push the current title + blocks to any open decoupled preview windows.
  defp broadcast_preview(socket) do
    payload = %{
      title: AshPhoenix.Form.value(socket.assigns.form, :title) || "",
      blocks: preview_blocks(socket.assigns.form)
    }

    Phoenix.PubSub.broadcast(
      KilnCMS.PubSub,
      KilnCMSWeb.PreviewLive.topic(socket.assigns.kind, socket.assigns.record.id),
      {:preview_update, payload}
    )

    socket
  end

  # Tell other editors of this item which field we just focused (or left, when
  # `field` is nil). Reuses the Presence editing topic.
  defp broadcast_cursor(socket, field) do
    Phoenix.PubSub.broadcast(
      KilnCMS.PubSub,
      Presence.topic(socket.assigns.kind, socket.assigns.record.id),
      {:cursor,
       %{
         id: socket.assigns.actor.id,
         name: Presence.display_name(socket.assigns.actor),
         field: field
       }}
    )
  end

  defp put_color(%{} = cursor), do: Map.put(cursor, :color, color_for(cursor.id))

  defp color_for(id),
    do: Enum.at(@cursor_colors, rem(:erlang.phash2(id), length(@cursor_colors)))

  # Focus-tracking attributes for an input; `field` keys the cursor badge.
  defp field_attrs(field) do
    %{"phx-focus" => "field_focus", "phx-blur" => "field_blur", "phx-value-field" => field}
  end

  # Effective blocks (data + unsaved edits) from the form, for the live preview.
  defp preview_blocks(form) do
    case AshPhoenix.Form.value(form, :blocks) do
      forms when is_list(forms) -> Enum.map(forms, &block_map/1)
      _ -> []
    end
  end

  defp block_map(%AshPhoenix.Form{} = subform) do
    %{
      type: to_string(AshPhoenix.Form.value(subform, :type) || "rich_text"),
      content: AshPhoenix.Form.value(subform, :content) || ""
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.form
        for={@form}
        phx-change="validate"
        phx-submit="save"
        id={"#{@kind}-editor"}
        class="space-y-6"
      >
        <div class="flex items-start justify-between gap-4">
          <div>
            <.link navigate={~p"/editor"} class="text-sm text-base-content/60 hover:underline">
              &larr; All content
            </.link>
            <h1 class="mt-1 text-2xl font-semibold">Edit {@kind}</h1>
            <p class="text-sm text-base-content/60">
              State: <span class="font-medium">{@record.state}</span>
            </p>
            <.editing_indicator editors={@editors} current_id={@actor.id} />
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <.link
              href={~p"/editor/preview/#{@kind}/#{@record.id}"}
              target="_blank"
              class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
            >
              Preview &nearr;
            </.link>
            <.workflow_buttons state={@record.state} />
            <.button type="submit" variant="primary">Save</.button>
          </div>
        </div>

        <div class="grid gap-6 lg:grid-cols-2">
          <div class="space-y-6">
            <div class="grid gap-4 sm:grid-cols-2">
              <div class="relative">
                <.input field={@form[:title]} label="Title" {field_attrs("title")} />
                <.field_cursors field="title" cursors={@cursors} />
              </div>
              <div class="relative">
                <.input field={@form[:slug]} label="Slug" {field_attrs("slug")} />
                <.field_cursors field="slug" cursors={@cursors} />
              </div>
            </div>

            <div :if={@kind == :post} class="relative">
              <.input
                field={@form[:excerpt]}
                type="textarea"
                label="Excerpt"
                {field_attrs("excerpt")}
              />
              <.field_cursors field="excerpt" cursors={@cursors} />
            </div>

            <div class="space-y-3">
              <h2 class="text-lg font-medium">Blocks</h2>

              <div id="blocks-sortable" phx-hook="Sortable" class="space-y-3">
                <.inputs_for :let={bf} field={@form[:blocks]}>
                  <div
                    id={"block-#{bf.index}"}
                    data-sort-id={bf.index}
                    class="rounded border border-base-content/15 p-3"
                  >
                    <div class="mb-2 flex items-center justify-between gap-3">
                      <div class="flex items-center gap-2">
                        <span
                          data-drag-handle
                          aria-label="Drag to reorder"
                          class="cursor-grab text-base-content/40 hover:text-base-content/70"
                        >
                          <.icon name="hero-bars-3" class="size-5" />
                        </span>
                        <.input
                          field={bf[:type]}
                          type="select"
                          options={@block_types}
                          class="max-w-40"
                        />
                      </div>
                      <button
                        type="button"
                        phx-click="remove_block"
                        phx-value-path={bf.name}
                        aria-label="Remove block"
                        class="text-base-content/50 hover:text-error"
                      >
                        <.icon name="hero-trash" class="size-5" />
                      </button>
                    </div>
                    <div
                      :if={to_string(bf[:type].value) == "rich_text"}
                      id={"rt-#{bf.index}"}
                      phx-hook="RichText"
                      phx-update="ignore"
                      data-content={bf[:content].value || ""}
                    >
                      <div data-toolbar class="mb-1 flex flex-wrap gap-1"></div>
                      <div data-editor></div>
                      <input
                        type="hidden"
                        name={bf[:content].name}
                        value={bf[:content].value}
                        data-input
                      />
                    </div>
                    <div :if={to_string(bf[:type].value) != "rich_text"} class="relative">
                      <.input
                        field={bf[:content]}
                        type="textarea"
                        placeholder="Block content…"
                        {field_attrs(bf[:content].name)}
                      />
                      <.field_cursors field={bf[:content].name} cursors={@cursors} />
                    </div>
                  </div>
                </.inputs_for>
              </div>

              <div class="flex flex-wrap gap-2">
                <button
                  :for={type <- @block_types}
                  type="button"
                  phx-click="add_block"
                  phx-value-type={type}
                  class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
                >
                  <.icon name="hero-plus" class="mr-1 size-4" />{type}
                </button>
              </div>
            </div>

            <details class="rounded border border-base-content/15 p-3">
              <summary class="cursor-pointer text-sm font-medium">SEO &amp; scheduling</summary>
              <div class="mt-3 space-y-3">
                <div class="relative">
                  <.input field={@form[:seo_title]} label="SEO title" {field_attrs("seo_title")} />
                  <.field_cursors field="seo_title" cursors={@cursors} />
                </div>
                <div class="relative">
                  <.input
                    field={@form[:seo_description]}
                    type="textarea"
                    label="SEO description"
                    {field_attrs("seo_description")}
                  />
                  <.field_cursors field="seo_description" cursors={@cursors} />
                </div>
                <div class="relative">
                  <.input field={@form[:seo_image]} label="OG image URL" {field_attrs("seo_image")} />
                  <.field_cursors field="seo_image" cursors={@cursors} />
                </div>
                <div class="relative">
                  <.input
                    field={@form[:canonical_url]}
                    label="Canonical URL"
                    {field_attrs("canonical_url")}
                  />
                  <.field_cursors field="canonical_url" cursors={@cursors} />
                </div>
                <.input field={@form[:locale]} label="Locale" />
                <.input
                  field={@form[:scheduled_at]}
                  type="datetime-local"
                  label="Scheduled publish at"
                />
              </div>
            </details>

            <details class="rounded border border-base-content/15 p-3">
              <summary class="cursor-pointer text-sm font-medium">
                Version history ({length(@versions)})
              </summary>
              <p :if={@versions == []} class="mt-3 text-sm text-base-content/60">
                No saved versions yet.
              </p>
              <ul :if={@versions != []} class="mt-3 space-y-2">
                <li
                  :for={version <- @versions}
                  class="flex items-center justify-between gap-3 text-sm"
                >
                  <span class="text-base-content/70">
                    {version.version_action_name} · {Calendar.strftime(
                      version.version_inserted_at,
                      "%Y-%m-%d %H:%M"
                    )}
                  </span>
                  <button
                    type="button"
                    phx-click="restore"
                    phx-value-version_id={version.id}
                    data-confirm="Restore content to this version?"
                    class="rounded border border-base-content/20 px-2 py-0.5 text-xs hover:bg-base-200"
                  >
                    Restore
                  </button>
                </li>
              </ul>
            </details>
          </div>

          <div class="lg:sticky lg:top-4 lg:self-start">
            <h2 class="mb-2 text-lg font-medium">Preview</h2>
            <article class="space-y-3 rounded border border-base-content/15 p-5">
              <h1 class="text-2xl font-bold">{@form[:title].value}</h1>
              <BlockComponents.render_block :for={block <- preview_blocks(@form)} block={block} />
            </article>
          </div>
        </div>
      </.form>
    </Layouts.app>
    """
  end

  attr :editors, :list, required: true
  attr :current_id, :string, required: true

  # Live "who's editing" indicator. Shows the *other* editors currently on this
  # item (the current user is omitted — they know they're here).
  defp editing_indicator(assigns) do
    assigns =
      assign(assigns, :others, Enum.reject(assigns.editors, &(&1.id == assigns.current_id)))

    ~H"""
    <div :if={@others != []} class="mt-2 flex items-center gap-2 text-xs text-warning">
      <span class="relative flex h-2 w-2">
        <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-warning opacity-75"></span>
        <span class="relative inline-flex h-2 w-2 rounded-full bg-warning"></span>
      </span>
      <span>
        Also editing: <span class="font-medium">{Enum.map_join(@others, ", ", & &1.name)}</span>
      </span>
    </div>
    """
  end

  attr :field, :string, required: true
  attr :cursors, :map, required: true

  # Floating badges naming the collaborators currently focused on `field`.
  defp field_cursors(assigns) do
    others = for {_id, c} <- assigns.cursors, c.field == assigns.field, do: c
    assigns = assign(assigns, :others, others)

    ~H"""
    <div
      :if={@others != []}
      class="pointer-events-none absolute right-1 top-0 z-10 flex gap-1"
    >
      <span
        :for={c <- @others}
        class={["rounded px-1.5 py-0.5 text-[10px] font-medium text-white shadow", c.color]}
      >
        {c.name}
      </span>
    </div>
    """
  end

  attr :state, :atom, required: true

  defp workflow_buttons(assigns) do
    ~H"""
    <button
      :if={@state in [:draft, :in_review]}
      type="button"
      phx-click="workflow"
      phx-value-action="publish"
      class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
    >
      Publish
    </button>
    <button
      :if={@state == :draft}
      type="button"
      phx-click="workflow"
      phx-value-action="submit"
      class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
    >
      Submit for review
    </button>
    <button
      :if={@state == :published}
      type="button"
      phx-click="workflow"
      phx-value-action="unpublish"
      class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
    >
      Unpublish
    </button>
    """
  end
end
