defmodule KilnCMSWeb.OrganizeLive do
  @moduledoc """
  Derived organization (`/editor/organize`, #1596): the library seen through
  its embeddings rather than its folders. Five tabs over `KilnCMS.Organize`:

    * **Clusters** — published documents grouped by what they are about, each
      group named by its nearest tag, or flagged when no tag describes it;
    * **Tag review** — propose existing tags across a filtered selection and
      confirm per row (`KilnCMS.Organize.Tagging`, the one budgeted path);
    * **Under-organized** — untagged documents, and ones far from every tag;
    * **Taxonomy health** — unused, single-use and near-duplicate terms, and
      published documents nothing links to;
    * **Gaps** — zero-result searches read as a missing term or hub page.

  Editor-gated by the `:editor_routes` session; every read runs as the
  viewer. Semantic search off (the default): the nav item is hidden, and a
  bookmarked visit gets one quiet line and nothing else — the workstream's
  contract (#1596). Each tab computes in `start_async` when opened, never in
  `mount/3` or `handle_params/3`.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Organize
  alias KilnCMS.Organize.Candidates
  alias KilnCMS.Organize.Clusters
  alias KilnCMS.Organize.Gaps
  alias KilnCMS.Organize.Health
  alias KilnCMS.Organize.Queue
  alias KilnCMS.Organize.Tagging
  alias KilnCMS.Organize.Terms

  @tabs ~w(clusters tagging queue health gaps)
  @states ~w(any draft in_review published)
  @query_display 80

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Organize"))
     |> assign(:enabled?, Organize.enabled?())
     |> assign(:tab, "clusters")
     |> assign(:data, nil)
     |> assign(:loading?, false)
     |> assign(:filter, %{"type" => "", "state" => "any", "untagged" => "true"})
     |> assign(:type_options, ContentTypes.options(socket.assigns.current_org))
     |> reset_run()
     |> assign(:failed_tags, [])}
  end

  defp reset_run(socket) do
    socket
    |> assign(:run, nil)
    |> assign(:rows, %{})
    |> assign(:applied, %{})
    |> assign(:proposing?, false)
    |> assign(:indexing?, false)
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in @tabs, do: params["tab"], else: "clusters"
    {:noreply, socket |> assign(:tab, tab) |> load_tab()}
  end

  defp load_tab(%{assigns: %{enabled?: false}} = socket), do: assign(socket, :data, nil)

  defp load_tab(socket) do
    %{tab: tab, current_org: org, current_user: actor, filter: filter} = socket.assigns
    failed = socket.assigns.failed_tags

    socket
    |> assign(:data, nil)
    |> assign(:loading?, true)
    |> start_async(:tab, fn -> {tab, compute(tab, org, actor, filter, failed)} end)
  end

  defp compute("clusters", org, actor, _filter, _failed), do: Clusters.browse(org, actor)
  defp compute("queue", org, actor, _filter, _failed), do: Queue.build(org, actor)
  defp compute("health", org, actor, _filter, _failed), do: Health.report(org, actor)
  defp compute("gaps", org, actor, _filter, _failed), do: Gaps.signals(org, actor)

  defp compute("tagging", org, actor, filter, failed) do
    %{
      selection: Tagging.selection(org, actor, selection_opts(filter)),
      missing_tags: Terms.missing_tag_vectors(org, actor, failed),
      failed_tags: length(failed)
    }
  end

  defp selection_opts(filter) do
    [
      type: if(filter["type"] == "", do: nil, else: filter["type"]),
      state: String.to_existing_atom(filter["state"]),
      untagged?: filter["untagged"] == "true"
    ]
  end

  @impl true
  def handle_async(:tab, {:ok, {tab, data}}, socket) do
    # A tab switched while this one computed: drop the stale answer.
    if tab == socket.assigns.tab,
      do: {:noreply, socket |> assign(:data, data) |> assign(:loading?, false)},
      else: {:noreply, socket}
  end

  def handle_async(:tab, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:loading?, false)
     |> put_flash(:error, gettext("That view couldn't be loaded. Try again in a moment."))}
  end

  def handle_async(:propose, {:ok, run}, socket) do
    rows = Map.merge(socket.assigns.rows, Map.new(run.rows, &{&1.id, &1}))
    order = (socket.assigns.run && socket.assigns.run.order) || []

    {:noreply,
     socket
     |> assign(:proposing?, false)
     |> assign(:rows, rows)
     |> assign(:run, %{
       order: order ++ Enum.map(run.rows, & &1.id),
       stopped: run.stopped,
       pending: run.pending,
       spent: ((socket.assigns.run && socket.assigns.run.spent) || 0) + run.spent
     })}
  end

  def handle_async(:propose, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:proposing?, false)
     |> put_flash(:error, gettext("The proposal run stopped unexpectedly. Try again."))}
  end

  def handle_async(:index_tags, {:ok, result}, socket) do
    socket = assign(socket, :indexing?, false)

    socket =
      case result do
        {:ok, %{indexed: n, failed: new_failed, remaining: left}} ->
          socket
          |> assign(:failed_tags, socket.assigns.failed_tags ++ new_failed)
          |> put_flash(:info, index_message(n, left))

        {:error, reason} ->
          put_flash(socket, :error, budget_message(reason))
      end

    {:noreply, load_tab(socket)}
  end

  def handle_async(:index_tags, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:indexing?, false)
     |> put_flash(:error, gettext("Indexing tag names stopped unexpectedly. Try again."))}
  end

  @impl true
  def handle_event("filter", %{"filter" => params}, socket) when is_map(params) do
    filter = %{
      "type" =>
        pick(params["type"], [""] ++ Enum.map(socket.assigns.type_options, &elem(&1, 1)), ""),
      "state" => pick(params["state"], @states, "any"),
      "untagged" => if(params["untagged"] == "true", do: "true", else: "false")
    }

    {:noreply, socket |> assign(:filter, filter) |> reset_run() |> load_tab()}
  end

  # One chunk of tag-name inferences — seconds, so off the LiveView process.
  # Refused while a chunk or a run is in flight: two chunks would each size
  # themselves to the same room before either charged.
  def handle_event(
        "index_tags",
        _params,
        %{assigns: %{indexing?: false, proposing?: false}} = socket
      ) do
    %{current_org: org, current_user: actor, failed_tags: failed} = socket.assigns

    {:noreply,
     socket
     |> assign(:indexing?, true)
     |> start_async(:index_tags, fn -> Terms.index_tag_vectors(org, actor, failed) end)}
  end

  # Refused while a run (or an index chunk) is in flight: a second
  # `start_async(:propose)` would cancel the first after it may already have
  # charged, losing its rows with the units spent.
  def handle_event(
        "propose",
        _params,
        %{assigns: %{data: %{selection: docs}, proposing?: false, indexing?: false}} = socket
      ) do
    {:noreply, socket |> reset_run() |> start_propose(docs)}
  end

  def handle_event(
        "continue",
        _params,
        %{assigns: %{run: %{pending: [_ | _] = docs}, proposing?: false, indexing?: false}} =
          socket
      ),
      do: {:noreply, start_propose(socket, docs)}

  # The row comes from assigns by id — never from the client — and the ticked
  # ids are filtered against that row's own proposal in `Tagging.apply/4`.
  def handle_event("apply", %{"row" => id} = params, socket) when is_binary(id) do
    ticked = params |> Map.get("tag_ids", []) |> List.wrap() |> Enum.filter(&is_binary/1)

    case Map.fetch(socket.assigns.rows, id) do
      {:ok, row} -> {:noreply, apply_row(socket, row, ticked)}
      :error -> {:noreply, socket}
    end
  end

  # Anything else (a stale button, a forged payload) falls through to
  # `KilnCMSWeb.MalformedEvent`'s injected catch-all: ignored, not crashed.

  defp start_propose(socket, docs) do
    %{current_org: org, current_user: actor} = socket.assigns

    socket
    |> assign(:proposing?, true)
    |> start_async(:propose, fn -> Tagging.propose(org, actor, docs) end)
  end

  defp apply_row(socket, row, ticked) do
    case Tagging.apply(socket.assigns.current_org, socket.assigns.current_user, row, ticked) do
      {:ok, where} ->
        assign(socket, :applied, Map.put(socket.assigns.applied, row.id, where))

      {:error, :nothing_ticked} ->
        put_flash(socket, :error, gettext("Tick at least one tag to apply."))

      {:error, _reason} ->
        put_flash(
          socket,
          :error,
          gettext(
            "Couldn't apply those tags — the document may have changed. Reload and try again."
          )
        )
    end
  end

  defp pick(value, allowed, default) when is_binary(value),
    do: if(value in allowed, do: value, else: default)

  defp pick(_value, _allowed, default), do: default

  defp index_message(n, 0),
    do: ngettext("Indexed %{count} tag name.", "Indexed %{count} tag names.", n, count: n)

  defp index_message(n, left),
    do:
      gettext("Indexed %{n} tag names; %{left} still to go. Continue in a minute.",
        n: n,
        left: left
      )

  # `:unattended_disabled` is a standing setting, not an overload: "try later"
  # would send an editor to wait out a window that will never help.
  defp budget_message(:unattended_disabled),
    do:
      gettext(
        "Bulk review is switched off: background embedding is disabled on this site. The per-document panel in the editor still works."
      )

  defp budget_message(:run_cap),
    do:
      gettext(
        "This run reached its embedding allowance. Continue to propose the rest — each run spends at most %{cap} embeddings.",
        cap: Tagging.run_cap()
      )

  defp budget_message({:rate_limited, _ms}),
    do:
      gettext(
        "The site's background embedding allowance is used up for now — it is shared with automation rules. The per-document panel in the editor still works. Continue later."
      )

  defp budget_message(_other), do: gettext("The embedding budget refused that request.")

  defp editor_path(doc), do: Candidates.editor_path(doc)

  defp library_tag_path(term), do: ~p"/editor?#{%{tag: term.id}}"

  defp short_query(query) do
    if String.length(query) > @query_display,
      do: String.slice(query, 0, @query_display) <> "…",
      else: query
  end

  defp tab_label("clusters"), do: gettext("Clusters")
  defp tab_label("tagging"), do: gettext("Tag review")
  defp tab_label("queue"), do: gettext("Under-organized")
  defp tab_label("health"), do: gettext("Taxonomy health")
  defp tab_label("gaps"), do: gettext("Gaps")

  defp filter_state_label("any"), do: gettext("Any state")
  defp filter_state_label("draft"), do: gettext("Draft")
  defp filter_state_label("in_review"), do: gettext("In review")
  defp filter_state_label("published"), do: gettext("Published")

  defp percent(distance), do: round((1.0 - distance) * 100)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:organize}
    >
      <.header>
        {gettext("Organize")}
        <:subtitle>
          {gettext(
            "Your library grouped by what it is about, not only by how it was filed — and where the vocabulary has not caught up."
          )}
        </:subtitle>
      </.header>

      <p :if={not @enabled?} id="organize-off" class="mt-6 text-sm text-base-content/60">
        {gettext("These views appear once semantic search is switched on for this site.")}
      </p>

      <div :if={@enabled?} class="mt-6 space-y-6">
        <nav class="tabs" role="tablist" aria-label={gettext("Organize views")}>
          <.link
            :for={tab <- ~w(clusters tagging queue health gaps)}
            id={"organize-tab-#{tab}"}
            patch={~p"/editor/organize?#{%{tab: tab}}"}
            role="tab"
            aria-selected={to_string(@tab == tab)}
            class={["tab", @tab == tab && "tab-active"]}
          >
            {tab_label(tab)}
          </.link>
        </nav>

        <div
          :if={@loading?}
          class="flex items-center gap-2 text-sm text-base-content/60"
          role="status"
        >
          <.icon name="hero-arrow-path" class="size-4 animate-spin" />
          {gettext("Reading the library…")}
        </div>

        <.clusters :if={@tab == "clusters" and @data} data={@data} />
        <.tagging
          :if={@tab == "tagging" and @data}
          data={@data}
          filter={@filter}
          type_options={@type_options}
          run={@run}
          rows={@rows}
          applied={@applied}
          proposing?={@proposing?}
          indexing?={@indexing?}
        />
        <.queue :if={@tab == "queue" and @data} data={@data} />
        <.health :if={@tab == "health" and @data} data={@data} />
        <.gaps :if={@tab == "gaps" and @data} data={@data} />
      </div>
    </Layouts.console>
    """
  end

  # ── clusters ───────────────────────────────────────────────────────────────

  attr :data, :map, required: true

  defp clusters(assigns) do
    ~H"""
    <section id="organize-clusters" class="space-y-4">
      <p class="text-sm text-base-content/60">
        <%= if @data.truncated? do %>
          {gettext("Clustering the %{count} most recently updated published documents.",
            count: @data.considered
          )}
        <% else %>
          {ngettext(
            "Clustering %{count} published document.",
            "Clustering %{count} published documents.",
            @data.considered
          )}
        <% end %>
        <span :if={@data.unindexed > 0}>
          {ngettext(
            "%{count} isn't indexed yet, so it isn't grouped.",
            "%{count} aren't indexed yet, so they aren't grouped.",
            @data.unindexed
          )}
        </span>
      </p>

      <.empty_state
        :if={@data.clusters == []}
        icon="hero-squares-2x2"
        title={gettext("Nothing to group yet")}
      >
        {gettext("Clusters form from published, indexed documents.")}
      </.empty_state>

      <div class="grid gap-4 md:grid-cols-2">
        <article
          :for={{cluster, i} <- Enum.with_index(@data.clusters)}
          id={"cluster-#{i}"}
          class="card card-pad space-y-3 transition-shadow hover:shadow-md"
        >
          <header class="flex flex-wrap items-center justify-between gap-2">
            <%= case cluster.label do %>
              <% {:tag, term, distance} -> %>
                <.link navigate={library_tag_path(term)} class="font-medium hover:underline">
                  <.icon name="hero-tag" class="size-4 align-[-2px] text-base-content/50" />
                  {term.name}
                </.link>
                <.badge variant="outline">
                  {gettext("%{pct}% match", pct: percent(distance))}
                </.badge>
              <% :uncovered -> %>
                <span class="font-medium">{gettext("No tag covers this group")}</span>
                <.badge variant="warning">{gettext("Missing term?")}</.badge>
            <% end %>
          </header>
          <p class="text-xs text-base-content/55">
            {ngettext("%{count} document", "%{count} documents", length(cluster.members))}
          </p>
          <ul class="space-y-1 text-sm">
            <li :for={doc <- Enum.take(cluster.members, 8)} class="truncate">
              <.link navigate={editor_path(doc)} class="hover:underline">
                {doc.title || gettext("(untitled)")}
              </.link>
              <span class="text-xs text-base-content/45">{doc.type}</span>
            </li>
            <li :if={length(cluster.members) > 8} class="text-xs text-base-content/50">
              {gettext("and %{count} more", count: length(cluster.members) - 8)}
            </li>
          </ul>
        </article>
      </div>
    </section>
    """
  end

  # ── tag review ─────────────────────────────────────────────────────────────

  attr :data, :map, required: true
  attr :filter, :map, required: true
  attr :type_options, :list, required: true
  attr :run, :map, default: nil
  attr :rows, :map, required: true
  attr :applied, :map, required: true
  attr :proposing?, :boolean, required: true
  attr :indexing?, :boolean, required: true

  defp tagging(assigns) do
    ~H"""
    <section id="organize-tagging" class="space-y-5">
      <.form
        for={%{}}
        as={:filter}
        id="organize-filter"
        phx-change="filter"
        class="flex flex-wrap items-end gap-3"
      >
        <label class="text-sm">
          <span class="field-label">{gettext("Type")}</span>
          <select name="filter[type]" class="field-select w-auto">
            <option value="" selected={@filter["type"] == ""}>{gettext("All types")}</option>
            <option
              :for={{label, value} <- @type_options}
              value={value}
              selected={@filter["type"] == value}
            >
              {label}
            </option>
          </select>
        </label>
        <label class="text-sm">
          <span class="field-label">{gettext("State")}</span>
          <select name="filter[state]" class="field-select w-auto">
            <option
              :for={state <- ~w(any draft in_review published)}
              value={state}
              selected={@filter["state"] == state}
            >
              {filter_state_label(state)}
            </option>
          </select>
        </label>
        <label class="flex items-center gap-2 pb-2 text-sm">
          <input type="hidden" name="filter[untagged]" value="false" />
          <input
            type="checkbox"
            name="filter[untagged]"
            value="true"
            checked={@filter["untagged"] == "true"}
            class="field-checkbox"
          />
          {gettext("Untagged only")}
        </label>
      </.form>

      <div class="card card-pad flex flex-wrap items-center justify-between gap-3">
        <p class="text-sm text-base-content/70">
          {ngettext(
            "%{count} document selected (at most %{max} per run).",
            "%{count} documents selected (at most %{max} per run).",
            length(@data.selection),
            max: Organize.bound(:bulk_limit)
          )}
          <span :if={@data.missing_tags > 0}>
            {ngettext(
              "%{count} tag name isn't indexed yet — index it before proposing.",
              "%{count} tag names aren't indexed yet — index them before proposing.",
              @data.missing_tags
            )}
          </span>
          <span :if={@data.failed_tags > 0} class="text-warning-ink">
            {ngettext(
              "%{count} tag name couldn't be indexed and is left out.",
              "%{count} tag names couldn't be indexed and are left out.",
              @data.failed_tags
            )}
          </span>
        </p>
        <.button
          :if={@data.missing_tags > 0}
          id="index-tags"
          size="sm"
          phx-click="index_tags"
          disabled={@indexing?}
        >
          {if @indexing?, do: gettext("Indexing…"), else: gettext("Index tag names")}
        </.button>
        <.button
          :if={@data.missing_tags == 0}
          id="propose"
          size="sm"
          variant="primary"
          phx-click="propose"
          disabled={@proposing? or @data.selection == []}
        >
          {if @proposing?, do: gettext("Proposing…"), else: gettext("Propose tags")}
        </.button>
      </div>

      <div
        :if={@run && @run.stopped}
        id="run-stopped"
        class="flex flex-wrap items-center justify-between gap-3 rounded-lg bg-warning/15 px-4 py-3 text-sm text-warning-ink"
        role="status"
      >
        <span>{budget_message(@run.stopped)}</span>
        <.button
          :if={@run.stopped != :unattended_disabled and @run.pending != []}
          id="continue"
          size="sm"
          phx-click="continue"
          disabled={@proposing?}
        >
          {ngettext("Continue (%{count} left)", "Continue (%{count} left)", length(@run.pending))}
        </.button>
      </div>

      <ul :if={@run} id="proposal-rows" class="space-y-3">
        <li :for={id <- @run.order} id={"row-#{id}"} class="card card-pad">
          <.proposal_row row={Map.fetch!(@rows, id)} applied={Map.get(@applied, id)} />
        </li>
      </ul>
    </section>
    """
  end

  attr :row, :map, required: true
  attr :applied, :atom, default: nil

  defp proposal_row(assigns) do
    ~H"""
    <div class="flex flex-wrap items-start justify-between gap-3">
      <div class="min-w-0">
        <.link navigate={editor_path(@row)} class="font-medium hover:underline">
          {@row.title || gettext("(untitled)")}
        </.link>
        <span class="ml-2 text-xs text-base-content/50">{@row.type}</span>
      </div>
      <.badge :if={@applied == :saved} variant="success">{gettext("Applied")}</.badge>
      <.badge :if={@applied == :working_copy} variant="info">
        {gettext("Added to the working copy — publish changes to make it live")}
      </.badge>
    </div>

    <%= case @row.status do %>
      <% :proposed -> %>
        <.form
          :if={is_nil(@applied)}
          for={%{}}
          id={"apply-#{@row.id}"}
          phx-submit="apply"
          class="mt-3 flex flex-wrap items-center gap-x-4 gap-y-2"
        >
          <input type="hidden" name="row" value={@row.id} />
          <label :for={s <- @row.suggestions} class="flex items-center gap-2 text-sm">
            <input type="checkbox" name="tag_ids[]" value={s.term.id} class="field-checkbox" />
            {s.term.name}
            <span class="text-xs text-base-content/45">{percent(s.distance)}%</span>
          </label>
          <.button size="sm" type="submit">{gettext("Apply")}</.button>
        </.form>
      <% :nothing -> %>
        <p class="mt-2 text-sm text-base-content/60">{gettext("No existing tag fits closely.")}</p>
      <% :too_large -> %>
        <p class="mt-2 text-sm text-base-content/60">
          {gettext(
            "Too large to propose in bulk (%{count} embeddings). Open it in the editor for its own suggestions.",
            count: @row.cost
          )}
        </p>
      <% :unindexed -> %>
        <p class="mt-2 text-sm text-base-content/60">
          {gettext("Published but not indexed yet, so there is nothing to compare.")}
        </p>
      <% :unavailable -> %>
        <p class="mt-2 text-sm text-base-content/60">
          {gettext("No longer available — it may have been deleted.")}
        </p>
    <% end %>
    """
  end

  # ── under-organized ────────────────────────────────────────────────────────

  attr :data, :map, required: true

  defp queue(assigns) do
    ~H"""
    <section id="organize-queue" class="grid gap-6 lg:grid-cols-2">
      <div class="card card-pad space-y-3">
        <header class="flex items-center justify-between gap-2">
          <h2 class="text-sm font-medium">{gettext("No tags")}</h2>
          <.button
            :if={@data.untagged != []}
            size="sm"
            variant="ghost"
            patch={~p"/editor/organize?#{%{tab: "tagging"}}"}
          >
            {gettext("Review tags")}
          </.button>
        </header>
        <p :if={@data.untagged == []} class="text-sm text-base-content/60">
          {gettext("Every document carries at least one tag.")}
        </p>
        <ul class="space-y-1 text-sm">
          <li :for={row <- @data.untagged} class="flex flex-wrap items-center gap-2">
            <.link navigate={editor_path(row.doc)} class="hover:underline">
              {row.doc.title || gettext("(untitled)")}
            </.link>
            <.badge variant="outline">
              {if row.missing == :none,
                do: gettext("No tags or category"),
                else: gettext("No tags")}
            </.badge>
          </li>
        </ul>
        <p :if={@data.untagged_truncated?} class="text-xs text-base-content/50">
          {gettext("Showing the %{count} most recently updated.", count: length(@data.untagged))}
        </p>
      </div>

      <div class="card card-pad space-y-3">
        <h2 class="text-sm font-medium">{gettext("Far from every tag")}</h2>
        <p class="text-xs text-base-content/55">
          {gettext(
            "Published documents no tag describes closely, tagged or not — the vocabulary may be missing a word. Tags only: categories have no vector."
          )}
        </p>
        <p :if={not @data.vocabulary_indexed?} class="text-sm text-base-content/60">
          {gettext("Index your tag names on the Tag review tab to see these.")}
        </p>
        <ul class="space-y-1 text-sm">
          <li :for={row <- @data.far} class="flex flex-wrap items-center gap-2">
            <.link navigate={editor_path(row.doc)} class="hover:underline">
              {row.doc.title || gettext("(untitled)")}
            </.link>
            <span :if={row.nearest} class="text-xs text-base-content/50">
              {gettext("closest: %{tag} (%{pct}%)",
                tag: elem(row.nearest, 0).name,
                pct: percent(elem(row.nearest, 1))
              )}
            </span>
          </li>
        </ul>
        <p :if={@data.vocabulary_truncated?} class="text-xs text-base-content/50">
          {gettext("Compared against the first %{count} tags by name.",
            count: Organize.bound(:term_limit)
          )}
        </p>
        <p :if={@data.far_truncated?} class="text-xs text-base-content/50">
          {gettext("Checked the %{count} most recently updated published documents.",
            count: @data.far_considered
          )}
        </p>
      </div>
    </section>
    """
  end

  # ── taxonomy health ────────────────────────────────────────────────────────

  attr :data, :map, required: true

  defp health(assigns) do
    ~H"""
    <section id="organize-health" class="grid gap-6 lg:grid-cols-2">
      <div class="card card-pad space-y-3">
        <h2 class="text-sm font-medium">{gettext("Unused and single-use terms")}</h2>
        <p class="text-xs text-base-content/55">
          {gettext("Trashed items don't count. Counts cover the content you can see.")}
        </p>
        <.term_list
          id="health-unused"
          terms={@data.unused}
          label={gettext("Unused")}
          empty={gettext("Every term is in use.")}
        />
        <.term_list
          id="health-single"
          terms={@data.single_use}
          label={gettext("Used once")}
          empty={gettext("No term is used only once.")}
        />
        <p :if={@data.terms_truncated?} class="text-xs text-base-content/50">
          {gettext("Reporting on the first %{count} terms by name.",
            count: Organize.bound(:term_limit)
          )}
        </p>
        <.link navigate={~p"/editor/taxonomy"} class="link text-sm">
          {gettext("Manage taxonomy")}
        </.link>
      </div>

      <div class="card card-pad space-y-3">
        <h2 class="text-sm font-medium">{gettext("Tags that may be the same")}</h2>
        <p :if={@data.near_duplicates == []} class="text-sm text-base-content/60">
          {gettext("No tag names are close enough to look like duplicates.")}
        </p>
        <ul id="health-duplicates" class="space-y-1 text-sm">
          <li :for={pair <- @data.near_duplicates} class="flex flex-wrap items-center gap-2">
            <.badge>{pair.a.name}</.badge>
            <span class="text-base-content/40">≈</span>
            <.badge>{pair.b.name}</.badge>
          </li>
        </ul>
        <p :if={@data.missing_vectors > 0} class="text-xs text-base-content/50">
          {ngettext(
            "%{count} tag isn't indexed yet and isn't compared.",
            "%{count} tags aren't indexed yet and aren't compared.",
            @data.missing_vectors
          )}
        </p>
      </div>

      <div class="card card-pad space-y-3 lg:col-span-2">
        <h2 class="text-sm font-medium">{gettext("Nothing links here")}</h2>
        <p class="text-xs text-base-content/55">
          {gettext(
            "Published documents with no way in: no related link, no reference field and no menu points to them. A link from a trashed page still counts until that page is purged."
          )}
        </p>
        <p :if={@data.unlinked == []} class="text-sm text-base-content/60">
          {gettext("Every published document has at least one link in.")}
        </p>
        <ul id="health-unlinked" class="grid gap-1 text-sm sm:grid-cols-2">
          <li :for={doc <- @data.unlinked} class="truncate">
            <.link navigate={editor_path(doc)} class="hover:underline">
              {doc.title || gettext("(untitled)")}
            </.link>
            <span class="text-xs text-base-content/45">{doc.type}</span>
          </li>
        </ul>
        <p :if={@data.unlinked_truncated?} class="text-xs text-base-content/50">
          {gettext("Checked the %{count} most recently updated published documents.",
            count: @data.unlinked_considered
          )}
        </p>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :terms, :list, required: true
  attr :label, :string, required: true
  attr :empty, :string, required: true

  defp term_list(assigns) do
    ~H"""
    <div id={@id}>
      <p class="text-xs font-medium uppercase tracking-wide text-base-content/50">{@label}</p>
      <p :if={@terms == []} class="text-sm text-base-content/60">{@empty}</p>
      <ul class="mt-1 flex flex-wrap gap-1.5">
        <li :for={term <- @terms}>
          <.badge variant={if term.kind == :tag, do: "neutral", else: "outline"}>
            {term.name}
          </.badge>
        </li>
      </ul>
    </div>
    """
  end

  # ── gaps ───────────────────────────────────────────────────────────────────

  attr :data, :map, required: true

  defp gaps(assigns) do
    ~H"""
    <section id="organize-gaps" class="space-y-4">
      <p class="text-sm text-base-content/60">
        {gettext(
          "Searches that found nothing, read as organization: a term that exists but has no page behind it, or a term the site doesn't have."
        )}
      </p>
      <p :if={@data.vocabulary_truncated?} class="text-xs text-base-content/50">
        {gettext("Compared against the first %{count} tags by name.",
          count: Organize.bound(:term_limit)
        )}
      </p>
      <p :if={@data.skipped == :no_vectors} class="text-sm text-base-content/60">
        {gettext("Index your tag names on the Tag review tab to classify these.")}
      </p>
      <p :if={match?({:rate_limited, _}, @data.skipped)} class="text-sm text-base-content/60">
        {gettext("Not classified right now — the embedding budget has no room. Reload later.")}
      </p>
      <.empty_state
        :if={@data.gaps == []}
        icon="hero-magnifying-glass"
        title={gettext("No zero-result searches recorded")}
      />
      <ul id="gap-rows" class="space-y-2">
        <li
          :for={gap <- @data.gaps}
          class="card card-pad flex flex-wrap items-center justify-between gap-3"
        >
          <div class="min-w-0">
            <p class="truncate font-medium">“{short_query(gap.query)}”</p>
            <p class="text-xs text-base-content/50">
              {ngettext("%{count} search", "%{count} searches", gap.searches)}
            </p>
          </div>
          <%= case gap.signal do %>
            <% {:hub_missing, term, _distance} -> %>
              <div class="flex items-center gap-2 text-sm">
                <.badge variant="info">{gettext("Missing hub page")}</.badge>
                <.link navigate={library_tag_path(term)} class="link">
                  {gettext("Content tagged %{tag}", tag: term.name)}
                </.link>
              </div>
            <% :term_missing -> %>
              <div class="flex items-center gap-2 text-sm">
                <.badge variant="warning">{gettext("Missing term")}</.badge>
                <.link navigate={~p"/editor/taxonomy"} class="link">
                  {gettext("Open taxonomy")}
                </.link>
              </div>
            <% :unclassified -> %>
              <span></span>
          <% end %>
        </li>
      </ul>
    </section>
    """
  end
end
