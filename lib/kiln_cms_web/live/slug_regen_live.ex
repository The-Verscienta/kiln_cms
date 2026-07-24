defmodule KilnCMSWeb.SlugRegenLive do
  @moduledoc """
  Bulk slug regeneration (#455) at `/editor/slugs` — pathauto's "update all
  aliases" with a mandatory dry run. Pick a content type (or all), preview
  every old → new rename, then apply: renames run through each type's normal
  `:update` action in a background job, so published renames leave 301s
  behind, artifacts re-fire, and history records the change.

  By default slugs that look hand-picked (they don't match their own current
  derivation) are skipped; after a deliberate convention change — a new slug
  pattern, changed stop words — check "regenerate hand-picked too", since
  every pre-change slug necessarily looks hand-picked then. Admin-only.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.SlugRegeneration
  alias KilnCMS.CMS.Workers.SlugRegenerationWorker

  # Preview rows shown; the counts always cover the full scan.
  @preview_cap 200

  @impl true
  def mount(_params, _session, socket) do
    if KilnCMSWeb.LiveUserAuth.effective_tier(socket) == :admin do
      org = socket.assigns.current_org

      if connected?(socket) do
        Phoenix.PubSub.subscribe(KilnCMS.PubSub, SlugRegenerationWorker.topic(org_id(org)))
      end

      {:ok,
       socket
       |> assign(:actor, socket.assigns.current_user)
       |> assign(:page_title, gettext("Slugs"))
       |> assign(:kind, "all")
       |> assign(:include_pinned, false)
       |> assign(:preview, nil)
       |> assign(:running?, false)
       |> assign(:progress, nil)
       |> assign(:result, nil)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You need admin access to view that page."))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("preview", params, socket) do
    socket = read_options(socket, params)

    preview =
      SlugRegeneration.preview(
        parse_kind(socket.assigns.kind),
        socket.assigns.current_org,
        include_pinned: socket.assigns.include_pinned
      )

    {:noreply, socket |> assign(:preview, preview) |> assign(:result, nil)}
  end

  def handle_event("apply", _params, socket) do
    {:ok, _job} =
      SlugRegenerationWorker.enqueue(
        org_id(socket.assigns.current_org),
        socket.assigns.kind,
        socket.assigns.include_pinned,
        socket.assigns.actor
      )

    {:noreply,
     socket
     |> assign(:running?, true)
     |> assign(:progress, nil)
     |> put_flash(:info, gettext("Regeneration queued — renames apply in the background."))}
  end

  @impl true
  def handle_info({:slug_regen_progress, progress}, socket) do
    {:noreply, assign(socket, :progress, progress)}
  end

  def handle_info({:slug_regen_done, summary}, socket) do
    {:noreply,
     socket
     |> assign(:running?, false)
     |> assign(:progress, nil)
     |> assign(:result, summary)
     |> assign(:preview, nil)
     |> put_flash(
       :info,
       gettext("Slug regeneration finished: %{changed} renamed.", changed: summary.changed)
     )}
  end

  defp read_options(socket, params) do
    socket
    |> assign(:kind, params["kind"] || socket.assigns.kind)
    |> assign(:include_pinned, params["include_pinned"] == "true")
  end

  defp parse_kind("all"), do: :all
  defp parse_kind(kind), do: kind

  defp preview_cap, do: @preview_cap

  defp org_id(nil), do: KilnCMS.Accounts.default_org_id()
  defp org_id(org), do: org.id

  defp type_options(org) do
    [{gettext("All content types"), "all"}] ++
      Enum.map(ContentTypes.all() ++ ContentTypes.dynamic_all(org_id(org)), fn ct ->
        {ct.label, to_string(ct.type)}
      end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:slugs}
    >
      <.header>
        {gettext("Slug regeneration")}
        <:subtitle>
          {gettext(
            "Re-derive slugs through the current rules (patterns, keywords, stop words). Preview first; applying renames through the normal update flow, so published URLs leave 301 redirects behind."
          )}
        </:subtitle>
      </.header>

      <form id="slug-regen-options" phx-change="preview" class="card card-pad mt-6 space-y-3">
        <div class="flex flex-wrap items-end gap-4">
          <.input
            type="select"
            name="kind"
            value={@kind}
            label={gettext("Content type")}
            options={type_options(@current_org)}
          />
          <label class="flex items-center gap-2 pb-2 text-sm">
            <input type="hidden" name="include_pinned" value="false" />
            <input
              type="checkbox"
              name="include_pinned"
              value="true"
              checked={@include_pinned}
              class="size-4 rounded border border-base-content/30 accent-primary"
            />
            {gettext("Regenerate hand-picked slugs too")}
          </label>
        </div>
        <p class="text-xs text-base-content/60">
          {gettext(
            "After changing slug conventions, every existing slug looks hand-picked — check the box to migrate them all."
          )}
        </p>
      </form>

      <div :if={@running?} class="mt-6 rounded border border-base-content/15 p-3 text-sm">
        <span class="loading loading-spinner loading-xs mr-2"></span>
        {gettext("Applying renames…")}
        <span :if={@progress} class="text-base-content/60">
          {gettext("%{scanned} scanned, %{changes} renamed so far.",
            scanned: @progress.scanned,
            changes: length(@progress.changes)
          )}
        </span>
      </div>

      <div :if={@result} class="mt-6 rounded border border-base-content/15 p-3 text-sm">
        <p>
          {gettext("Done: %{changed} renamed, %{pinned} hand-picked skipped, %{scanned} scanned.",
            changed: @result.changed,
            pinned: @result.pinned_skipped,
            scanned: @result.scanned
          )}
        </p>
        <p :if={@result.failed != []} class="mt-1 text-error">
          {gettext("%{count} renames failed — re-run the preview to see what's left.",
            count: length(@result.failed)
          )}
        </p>
      </div>

      <section :if={@preview} class="mt-6">
        <div class="flex items-center justify-between">
          <h2 class="text-sm font-medium">
            {gettext("%{count} slugs would change (%{pinned} hand-picked skipped)",
              count: length(@preview.changes),
              pinned: @preview.pinned_skipped
            )}
          </h2>
          <.button
            :if={@preview.changes != [] and not @running?}
            variant="primary"
            size="sm"
            phx-click="apply"
            data-confirm={
              gettext("Rename these slugs? Published URLs will 301 to their new locations.")
            }
          >
            {gettext("Apply %{count} renames", count: length(@preview.changes))}
          </.button>
        </div>

        <.empty_state
          :if={@preview.changes == []}
          icon="hero-check-circle"
          title={gettext("Nothing to rename")}
        >
          {gettext("Every scanned slug already matches its derivation.")}
        </.empty_state>

        <div :if={@preview.changes != []} class="mt-3 overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>{gettext("Type")}</th>
                <th>{gettext("Title")}</th>
                <th>{gettext("Current")}</th>
                <th>{gettext("New")}</th>
                <th>{gettext("State")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={change <- Enum.take(@preview.changes, preview_cap())}>
                <td>{change.kind}</td>
                <td class="max-w-48 truncate">{change.title}</td>
                <td class="font-mono text-xs">{change.current}</td>
                <td class="font-mono text-xs">{change.new}</td>
                <td><.state_badge state={change.state} /></td>
              </tr>
            </tbody>
          </table>
          <p
            :if={length(@preview.changes) > preview_cap()}
            class="mt-2 text-xs text-base-content/60"
          >
            {gettext("Showing the first %{cap} of %{total} renames — applying covers all of them.",
              cap: preview_cap(),
              total: length(@preview.changes)
            )}
          </p>
        </div>
      </section>
    </Layouts.console>
    """
  end
end
