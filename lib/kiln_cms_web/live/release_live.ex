defmodule KilnCMSWeb.ReleaseLive do
  @moduledoc """
  Content releases (`/editor/releases`, #500): plan a bundle of publishes and
  unpublishes, see what it would do, ship it in one atomic go-live — and undo it.

  Two surfaces on one LiveView:

    * **index** — the release list by state, plus "new release".
    * **show** — one release: its items with the content resolved, a *readiness*
      panel (`KilnCMS.CMS.Releases.readiness/2` — the same classifier go-live
      itself uses, so the panel can never disagree with what happens), the
      shareable preview link, and the ship/rollback controls.

  Editor-gated by the `:editor_routes` live session, but composing and shipping
  are different privileges: an editor creates releases and fills them, while
  scheduling, publishing and rolling back are admin-only, mirroring "editors
  submit for review, admins publish". The resource policies enforce that; this
  view only decides which buttons to draw.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentRelease
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.ReleasePreview
  alias KilnCMS.CMS.Releases

  # State groups the list offers. "Planned" is where the work happens; the other
  # two are history.
  @views %{
    "planned" => [:open, :scheduled, :publishing, :failed],
    "published" => [:published, :rolling_back],
    "closed" => [:rolled_back, :archived]
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:actor, socket.assigns.current_user)
     |> assign(:tier, KilnCMSWeb.LiveUserAuth.effective_tier(socket))
     |> assign(:page_title, gettext("Releases"))
     |> assign(:new, to_form(%{"name" => "", "description" => ""}, as: :release))
     |> assign(:preview_url, nil)
     |> assign(:subscribed_to, nil)}
  end

  # The go-live / rollback worker finished — re-read so the page shows the
  # outcome rather than the claim state it started in.
  @impl true
  def handle_info({:release_finished, id}, %{assigns: %{release: %{id: id}}} = socket) do
    {:noreply, reload(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, params) do
    view = if params["view"] in Map.keys(@views), do: params["view"], else: "planned"

    socket
    |> assign(:view, view)
    |> assign(:page_title, gettext("Releases"))
    |> load_releases()
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    case CMS.get_release(id, actor: socket.assigns.actor, tenant: socket.assigns.current_org) do
      {:ok, release} ->
        socket
        |> assign(:page_title, release.name)
        |> assign(:preview_url, nil)
        |> load_release(release)

      _ ->
        socket
        |> put_flash(:error, gettext("That release no longer exists."))
        |> push_navigate(to: ~p"/editor/releases")
    end
  end

  # --- data ------------------------------------------------------------------

  defp load_releases(socket) do
    opts = [actor: socket.assigns.actor, tenant: socket.assigns.current_org]
    states = Map.fetch!(@views, socket.assigns.view)

    releases =
      states
      |> Enum.flat_map(&CMS.list_releases_by_state!(&1, opts))
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})

    socket |> assign(:releases, releases) |> assign(:counts, item_counts(releases, opts))
  end

  # One read for every release on the page, not one per release.
  defp item_counts([], _opts), do: %{}

  defp item_counts(releases, opts) do
    ids = Enum.map(releases, & &1.id)

    counts =
      ids
      |> CMS.list_release_items_for_releases!(opts)
      |> Enum.frequencies_by(& &1.release_id)

    Map.new(ids, &{&1, Map.get(counts, &1, 0)})
  end

  defp load_release(socket, release) do
    opts = [actor: socket.assigns.actor, tenant: socket.assigns.current_org]
    items = CMS.list_release_items_for!(release.id, opts)

    socket
    |> assign(:release, release)
    |> assign(:items, items)
    |> assign(:titles, resolve_titles(items, opts))
    |> assign(:readiness, readiness(release, opts))
    |> assign(:schedule_form, to_form(schedule_params(release), as: :schedule))
    |> subscribe_to(release)
  end

  # A go-live runs off-request, so without this the page that started it renders
  # "Publishing" and stays there — the re-read after the claim happens
  # microseconds later, long before the worker has done anything. The worker
  # broadcasts when it finishes and the page reloads itself.
  defp subscribe_to(socket, release) do
    if connected?(socket) and socket.assigns[:subscribed_to] != release.id do
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, KilnCMS.CMS.Releases.topic(release.id))
      assign(socket, :subscribed_to, release.id)
    else
      socket
    end
  end

  # Only pending items have a readiness verdict — everything else already
  # happened. Skipped for a release that isn't going anywhere, so the show page
  # of an archived release doesn't run N content reads for nothing.
  defp readiness(%{state: state} = release, opts) do
    if state in ContentRelease.editable_states() do
      release
      |> Releases.readiness(opts)
      |> Map.new(fn {item, class} -> {item.id, class} end)
    else
      %{}
    end
  end

  # One read per content type rather than one per item: a release of fifty posts
  # would otherwise be fifty queries to draw a table of titles.
  defp resolve_titles(items, opts) do
    items
    |> Enum.group_by(& &1.content_type)
    |> Enum.flat_map(fn {type, rows} -> titles_for_type(type, rows, opts) end)
    |> Map.new()
  end

  defp titles_for_type(type, rows, opts) do
    ids = rows |> Enum.map(& &1.content_id) |> Enum.uniq()

    found =
      type
      |> ContentTypes.list!(
        Keyword.put(opts, :query, filter: [id: [in: ids]], select: [:id, :title, :state])
      )
      |> Map.new(&{&1.id, &1})

    Enum.map(rows, &{&1.id, found[&1.content_id]})
  rescue
    # The content type was retired since the item was added.
    _error -> Enum.map(rows, &{&1.id, nil})
  end

  defp schedule_params(%{scheduled_at: nil}), do: %{"scheduled_at" => ""}

  defp schedule_params(%{scheduled_at: at}),
    do: %{"scheduled_at" => DateTime.to_iso8601(at)}

  # --- events ----------------------------------------------------------------

  @impl true
  def handle_event("create", %{"release" => params}, socket) do
    attrs = %{
      name: String.trim(params["name"] || ""),
      description: blank_to_nil(params["description"])
    }

    case CMS.create_release(attrs,
           actor: socket.assigns.actor,
           tenant: socket.assigns.current_org
         ) do
      {:ok, release} ->
        {:noreply, push_navigate(socket, to: ~p"/editor/releases/#{release.id}")}

      {:error, _error} ->
        {:noreply,
         socket
         |> assign(:new, to_form(params, as: :release))
         |> put_flash(:error, gettext("A release needs a name."))}
    end
  end

  def handle_event("schedule", %{"schedule" => %{"scheduled_at" => value}}, socket) do
    case parse_datetime(value) do
      {:ok, at} ->
        socket.assigns.release
        |> CMS.schedule_release(%{scheduled_at: at}, act(socket))
        |> respond(socket, gettext("Release scheduled."))

      :error ->
        {:noreply, put_flash(socket, :error, gettext("Enter a valid go-live date and time."))}
    end
  end

  def handle_event("unschedule", _params, socket) do
    socket.assigns.release
    |> CMS.unschedule_release(%{}, act(socket))
    |> respond(socket, gettext("Go-live date removed; the release is manual again."))
  end

  def handle_event("publish_now", _params, socket) do
    socket.assigns.release
    |> CMS.start_release(%{}, act(socket))
    |> respond(socket, gettext("Publishing the release…"))
  end

  def handle_event("roll_back", _params, socket) do
    socket.assigns.release
    |> CMS.start_release_rollback(%{}, act(socket))
    |> respond(socket, gettext("Rolling the release back…"))
  end

  def handle_event("abandon", _params, socket) do
    socket.assigns.release
    |> CMS.abandon_release(%{}, act(socket))
    |> respond(socket, gettext("Claim released; the release can be retried."))
  end

  def handle_event("reopen", _params, socket) do
    socket.assigns.release
    |> CMS.reopen_release(%{}, act(socket))
    |> respond(socket, gettext("Release reopened."))
  end

  def handle_event("archive", _params, socket) do
    socket.assigns.release
    |> CMS.archive_release(%{}, act(socket))
    |> respond(socket, gettext("Release archived."))
  end

  def handle_event("delete", _params, socket) do
    case CMS.destroy_release(socket.assigns.release, act(socket)) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Release deleted."))
         |> push_navigate(to: ~p"/editor/releases")}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, gettext("That release can't be deleted."))}
    end
  end

  def handle_event("remove_item", %{"id" => id}, socket) do
    opts = act(socket)

    with {:ok, item} <- CMS.get_release_item(id, opts),
         {:ok, _} <- CMS.cancel_release_item(item, %{}, opts) do
      {:noreply,
       socket
       |> reload()
       |> put_flash(:info, gettext("Removed from the release."))}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Couldn't remove that item."))}
    end
  end

  # Minted on demand rather than rendered on every page load: the link grants a
  # read of every unpublished document in the release, so it should exist because
  # somebody asked to share it.
  def handle_event("share_preview", _params, socket) do
    token = ReleasePreview.sign(socket.assigns.release)
    {:noreply, assign(socket, :preview_url, url(~p"/preview/release/#{token}"))}
  end

  # --- helpers ---------------------------------------------------------------

  defp act(socket), do: [actor: socket.assigns.actor, tenant: socket.assigns.current_org]

  defp respond({:ok, release}, socket, message) do
    {:noreply,
     socket
     |> load_release(reload_release(release, socket))
     |> put_flash(:info, message)}
  end

  defp respond({:error, %Ash.Error.Forbidden{}}, socket, _message) do
    {:noreply, put_flash(socket, :error, gettext("Shipping a release needs admin access."))}
  end

  defp respond({:error, _error}, socket, _message) do
    {:noreply, put_flash(socket, :error, gettext("That didn't work — try again."))}
  end

  # The go-live worker runs off-request, so the record we just claimed is
  # already stale by the time the flash renders. Re-read so the page shows the
  # outcome rather than `:publishing` forever.
  defp reload_release(release, socket) do
    case CMS.get_release(release.id, act(socket)) do
      {:ok, fresh} -> fresh
      _ -> release
    end
  end

  defp reload(socket), do: load_release(socket, reload_release(socket.assigns.release, socket))

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(String.replace(value, " ", "T")) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp parse_datetime(_value), do: :error

  defp stamp(nil), do: "—"
  defp stamp(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M")

  defp admin?(tier), do: tier == :admin

  # Mid-flight is never archivable (a worker owns those rows), and once a
  # release has shipped or been scheduled, closing it out is an admin decision —
  # the resource policy enforces the same split. Mirrored here only so an editor
  # isn't offered a button that always errors.
  defp archivable?(%{state: state}, _tier) when state in [:archived, :publishing, :rolling_back],
    do: false

  defp archivable?(_release, :admin), do: true

  defp archivable?(%{state: state, published_at: published_at}, _tier),
    do: is_nil(published_at) and state != :scheduled

  defp deletable?(%{state: state}, _tier) when state in [:publishing, :rolling_back], do: false
  defp deletable?(%{published_at: published_at}, _tier) when not is_nil(published_at), do: false
  defp deletable?(_release, :admin), do: true
  defp deletable?(%{state: state}, _tier), do: state != :scheduled

  # Archiving a *published* release is the end of its rollback, because there is
  # no transition out of `:archived`. Say that, rather than the generic prompt.
  defp archive_prompt(%{published_at: nil}),
    do: gettext("Archive this release? Its pending items are freed for other releases.")

  defp archive_prompt(_release),
    do: gettext("Archive this published release? It can no longer be rolled back as a group.")

  defp state_variant(:published), do: "success"
  defp state_variant(:scheduled), do: "info"
  defp state_variant(:publishing), do: "info"
  defp state_variant(:rolling_back), do: "warning"
  defp state_variant(:failed), do: "error"
  defp state_variant(_state), do: "neutral"

  defp release_state_label(:open), do: gettext("Open")
  defp release_state_label(:scheduled), do: gettext("Scheduled")
  defp release_state_label(:publishing), do: gettext("Publishing")
  defp release_state_label(:published), do: gettext("Published")
  defp release_state_label(:failed), do: gettext("Failed")
  defp release_state_label(:rolling_back), do: gettext("Rolling back")
  defp release_state_label(:rolled_back), do: gettext("Rolled back")
  defp release_state_label(:archived), do: gettext("Archived")

  defp item_status_label(:pending), do: gettext("Pending")
  defp item_status_label(:applied), do: gettext("Applied")
  defp item_status_label(:skipped), do: gettext("Skipped")
  defp item_status_label(:cancelled), do: gettext("Removed")
  defp item_status_label(:rolled_back), do: gettext("Rolled back")

  defp action_label(:publish), do: gettext("Publish")
  defp action_label(:unpublish), do: gettext("Unpublish")

  defp view_label("planned"), do: gettext("Planned")
  defp view_label("published"), do: gettext("Published")
  defp view_label("closed"), do: gettext("Closed")

  defp readiness_note(nil), do: nil
  defp readiness_note(:apply), do: nil

  defp readiness_note({:skip, :already_in_state}),
    do: {"outline", gettext("already in that state — will be skipped")}

  defp readiness_note({:error, reason}), do: {"error", reason}

  # --- render ----------------------------------------------------------------

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:releases}
    >
      <.header>
        {gettext("Releases")}
        <:subtitle>
          {gettext(
            "Bundle a campaign's publishes and unpublishes and ship them as one coordinated change. A release goes live all at once, or not at all."
          )}
        </:subtitle>
      </.header>

      <div class="card card-pad mt-6">
        <h2 class="text-sm font-medium">{gettext("New release")}</h2>
        <.form
          for={@new}
          id="new-release-form"
          phx-submit="create"
          class="mt-3 grid gap-3 sm:grid-cols-3"
        >
          <.input
            field={@new[:name]}
            label={gettext("Name")}
            placeholder={gettext("Spring campaign")}
          />
          <div class="sm:col-span-2">
            <.input field={@new[:description]} label={gettext("Notes (optional)")} />
          </div>
          <div class="sm:col-span-3">
            <.button variant="primary" size="sm">{gettext("Create release")}</.button>
            <span class="ml-2 text-xs text-base-content/60">
              {gettext("Add content to it from the content list.")}
            </span>
          </div>
        </.form>
      </div>

      <div class="mt-6 flex gap-2" role="tablist">
        <.link
          :for={view <- ~w(planned published closed)}
          patch={~p"/editor/releases?view=#{view}"}
          role="tab"
          aria-selected={to_string(view == @view)}
          class={["btn btn-sm", if(view == @view, do: "btn-primary", else: "btn-default")]}
        >
          {view_label(view)}
        </.link>
      </div>

      <.empty_state
        :if={@releases == []}
        icon="hero-rocket-launch"
        title={gettext("No releases here")}
      >
        {gettext("Create one above, then add content to it from the content list.")}
      </.empty_state>

      <div :if={@releases != []} class="mt-4 overflow-x-auto">
        <table class="table">
          <thead>
            <tr>
              <th>{gettext("Release")}</th>
              <th>{gettext("State")}</th>
              <th>{gettext("Items")}</th>
              <th>{gettext("Go-live")}</th>
              <th>{gettext("Published")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={release <- @releases}>
              <td>
                <.link navigate={~p"/editor/releases/#{release.id}"} class="link font-medium">
                  {release.name}
                </.link>
                <p :if={release.description} class="text-xs text-base-content/60">
                  {release.description}
                </p>
              </td>
              <td>
                <.badge variant={state_variant(release.state)}>
                  {release_state_label(release.state)}
                </.badge>
              </td>
              <td class="text-sm">{Map.get(@counts, release.id, 0)}</td>
              <td class="text-xs text-base-content/60">{stamp(release.scheduled_at)}</td>
              <td class="text-xs text-base-content/60">{stamp(release.published_at)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.console>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:releases}
    >
      <.link navigate={~p"/editor/releases"} class="link text-sm">
        {gettext("← All releases")}
      </.link>

      <.header>
        <span class="flex items-center gap-3">
          {@release.name}
          <.badge variant={state_variant(@release.state)}>
            {release_state_label(@release.state)}
          </.badge>
        </span>
        <:subtitle>{@release.description}</:subtitle>
      </.header>

      <div
        :if={@release.state == :failed}
        class="mt-4 rounded-lg border border-error/30 bg-error/5 p-4 text-sm"
      >
        <p class="font-medium">{gettext("This release did not ship. Nothing went live.")}</p>
        <p class="mt-1 text-base-content/70">{@release.failure_reason}</p>
      </div>

      <div class="mt-6 grid gap-6 lg:grid-cols-3">
        <div class="lg:col-span-2">
          <h2 class="text-sm font-medium">{gettext("Contents")}</h2>

          <.empty_state
            :if={@items == []}
            icon="hero-inbox"
            title={gettext("Nothing in this release")}
          >
            {gettext("Select content in the content list and use “Add to release”.")}
          </.empty_state>

          <div :if={@items != []} class="mt-3 overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>{gettext("Content")}</th>
                  <th>{gettext("Change")}</th>
                  <th>{gettext("Status")}</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={item <- @items}>
                  <td>
                    <%= if record = @titles[item.id] do %>
                      <.link
                        navigate={~p"/editor/content/#{item.content_type}/#{item.content_id}"}
                        class="link"
                      >
                        {record.title}
                      </.link>
                      <span class="ml-1 text-xs text-base-content/50">{item.content_type}</span>
                    <% else %>
                      <span class="text-base-content/60">{gettext("Content no longer exists")}</span>
                    <% end %>
                    <p :if={note = readiness_note(@readiness[item.id])} class="mt-1">
                      <.badge variant={elem(note, 0)}>{elem(note, 1)}</.badge>
                    </p>
                  </td>
                  <td class="text-sm">{action_label(item.action)}</td>
                  <td>
                    <span class="text-xs text-base-content/70">{item_status_label(item.status)}</span>
                  </td>
                  <td class="text-right">
                    <button
                      :if={item.status == :pending and @release.state in [:open, :scheduled, :failed]}
                      type="button"
                      phx-click="remove_item"
                      phx-value-id={item.id}
                      aria-label={gettext("Remove from release")}
                      class="btn btn-sm btn-ghost text-base-content/60 hover:text-error"
                    >
                      <.icon name="hero-x-mark" class="size-4" />
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <aside class="space-y-4">
          <div class="card card-pad">
            <h2 class="text-sm font-medium">{gettext("Go-live")}</h2>

            <dl class="mt-2 space-y-1 text-xs text-base-content/70">
              <div class="flex justify-between gap-2">
                <dt>{gettext("Scheduled")}</dt>
                <dd>{stamp(@release.scheduled_at)}</dd>
              </div>
              <div class="flex justify-between gap-2">
                <dt>{gettext("Published")}</dt>
                <dd>{stamp(@release.published_at)}</dd>
              </div>
              <div :if={@release.rolled_back_at} class="flex justify-between gap-2">
                <dt>{gettext("Rolled back")}</dt>
                <dd>{stamp(@release.rolled_back_at)}</dd>
              </div>
            </dl>

            <p :if={not admin?(@tier)} class="mt-3 text-xs text-base-content/60">
              {gettext("Scheduling and publishing a release need admin access.")}
            </p>

            <%!-- `:schedule` and `:start` transition from :open/:scheduled ONLY. Drawing
                  them on a :failed release offered two buttons that could only ever
                  produce "that didn't work", instead of pointing at Reopen — which
                  is the actual first step. --%>
            <div
              :if={admin?(@tier) and @release.state in [:open, :scheduled]}
              class="mt-3 space-y-3"
            >
              <.form for={@schedule_form} id="schedule-form" phx-submit="schedule">
                <div id="release-scheduled-at" phx-hook="UtcDatetimeInput" phx-update="ignore">
                  <label for="release-scheduled-at-local" class="field-label">
                    {gettext("Go live at")}
                  </label>
                  <input
                    type="datetime-local"
                    id="release-scheduled-at-local"
                    data-local-input
                    class="field-input"
                  />
                  <input
                    type="hidden"
                    name="schedule[scheduled_at]"
                    value={@schedule_form[:scheduled_at].value}
                    data-utc-input
                  />
                  <p class="mt-1 text-xs text-base-content/60">
                    {gettext("Shown in your local timezone; stored as UTC.")}
                  </p>
                </div>
                <.button size="sm" class="btn btn-sm btn-default mt-2">
                  {gettext("Schedule")}
                </.button>
              </.form>

              <button
                :if={@release.scheduled_at}
                type="button"
                phx-click="unschedule"
                class="btn btn-sm btn-default w-full"
              >
                {gettext("Remove schedule")}
              </button>

              <button
                type="button"
                phx-click="publish_now"
                data-confirm={
                  gettext(
                    "Publish this release now? Every item goes live together — or, if any one fails, none of them do."
                  )
                }
                class="btn btn-sm btn-primary w-full"
              >
                {gettext("Publish now")}
              </button>
            </div>

            <button
              :if={admin?(@tier) and @release.state == :published}
              type="button"
              phx-click="roll_back"
              data-confirm={
                gettext(
                  "Roll this release back? Every item it changed returns to the state it was in before."
                )
              }
              class="btn btn-sm btn-default mt-3 w-full"
            >
              {gettext("Roll back")}
            </button>

            <button
              :if={@release.state == :failed}
              type="button"
              phx-click="reopen"
              class="btn btn-sm btn-primary mt-3 w-full"
            >
              {gettext("Reopen for editing")}
            </button>
            <p :if={@release.state == :failed} class="mt-1 text-xs text-base-content/60">
              {gettext("Fix the item above, then reopen to schedule or publish again.")}
            </p>

            <%!-- The way out of a claim whose worker died. Nothing else can move
                  a release off :publishing / :rolling_back, and while it sits there
                  its items keep reserving their content against every other release. --%>
            <button
              :if={admin?(@tier) and @release.state in [:publishing, :rolling_back]}
              type="button"
              phx-click="abandon"
              data-confirm={
                gettext(
                  "Only do this if the release is stuck — no publish is still running. It releases the claim so the release can be retried."
                )
              }
              class="btn btn-sm btn-default mt-3 w-full"
            >
              {gettext("Release a stuck claim")}
            </button>
          </div>

          <div class="card card-pad">
            <h2 class="text-sm font-medium">{gettext("Preview")}</h2>
            <p class="mt-1 text-xs text-base-content/60">
              {gettext("A shareable link showing the site as this release would leave it.")}
            </p>
            <button type="button" phx-click="share_preview" class="btn btn-sm btn-default mt-2">
              {gettext("Create preview link")}
            </button>
            <p :if={@preview_url} class="mt-2 break-all rounded bg-base-200 p-2 font-mono text-xs">
              {@preview_url}
            </p>
            <p :if={@preview_url} class="mt-1 text-xs text-base-content/60">
              {gettext("Valid for one hour.")}
            </p>
          </div>

          <div class="card card-pad">
            <h2 class="text-sm font-medium">{gettext("Close out")}</h2>
            <%!-- Archiving is one-way — there is no transition out of :archived —
                  so archiving a published release permanently ends its group
                  rollback. That is an admin's call, and the confirm says so. --%>
            <button
              :if={archivable?(@release, @tier)}
              type="button"
              phx-click="archive"
              data-confirm={archive_prompt(@release)}
              class="btn btn-sm btn-default mt-2 w-full"
            >
              {gettext("Archive")}
            </button>
            <button
              :if={deletable?(@release, @tier)}
              type="button"
              phx-click="delete"
              data-confirm={gettext("Delete this release? Its item list goes with it.")}
              class="btn btn-sm btn-ghost mt-2 w-full text-error"
            >
              {gettext("Delete")}
            </button>
          </div>
        </aside>
      </div>
    </Layouts.console>
    """
  end
end
