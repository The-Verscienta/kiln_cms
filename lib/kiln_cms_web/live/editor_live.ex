defmodule KilnCMSWeb.EditorLive do
  @moduledoc """
  Content list / editor home (`/editor`) — browse pages and posts with their
  workflow state, create new content, jump into the block editor, and
  publish/unpublish inline. Editor/admin only.

  The list filters on status, type, title, author, category, tag, locale, an
  update-date range and review health, and sorts by update, publish date or
  title (#1593). All of it lives in the URL (`KilnCMSWeb.EditorLive.Filters`),
  so a link, a refresh and the back button keep it. A filter can be saved as a
  named view (`KilnCMS.CMS.SavedView`) next to a few built-in ones.
  """
  use KilnCMSWeb, :live_view

  import Ash.Expr, only: [expr: 1]

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Compliance
  alias KilnCMS.Compliance.Settings
  alias KilnCMS.I18n
  alias KilnCMSWeb.ContentEditor.NewDraft
  alias KilnCMSWeb.ContentEditor.Shared
  alias KilnCMSWeb.EditorLive.Filters

  import KilnCMSWeb.ComplianceComponents, only: [compliance_grade_badge: 1]

  # Server-side page size. Each page pulls at most @page_size rows per content
  # type from the DB (every filter runs there too — audit U-M2) and keeps the
  # first @page_size of the merged order, so any item is reachable via Load more.
  @page_size 50

  # Past this many content types, the top bar's per-type "New …" buttons
  # collapse into a single dropdown so the header stays one row.
  @max_inline_new_buttons 3

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user
    org = socket.assigns.current_org

    {:ok,
     socket
     |> assign(:actor, socket.assigns.current_user)
     |> assign(:tier, KilnCMSWeb.LiveUserAuth.effective_tier(socket))
     # Offers Publish (row and bulk) to editors on a site that lets them; the
     # content policy (`Checks.EditorMayPublish`) is what decides.
     |> assign(
       :editors_can_publish,
       KilnCMS.CMS.EditorialSettings.editors_can_publish?(socket.assigns.current_org)
     )
     |> assign(:page_title, gettext("Content"))
     # Words or the opt-in trigram glyph per row (#1323) — chosen on Your
     # settings, so read once here rather than per render.
     |> assign(:status_marks, status_marks(socket.assigns.current_user))
     # `:content_types` is owned by handle_params (which always runs after
     # mount) so the type filter, the "New …" buttons and the listing query all
     # read one freshly-loaded registry per navigation.
     |> assign(:max_inline_new_buttons, @max_inline_new_buttons)
     |> assign(:statuses, Filters.statuses())
     |> assign(:selected, MapSet.new())
     |> assign(:confirming_bulk, nil)
     # Facet choices (#1593). Loaded once per mount: a category or tag created
     # in another tab shows up on the next visit, as the editor's pickers do.
     |> assign(:authors, Shared.assignable_users(org))
     |> assign(
       :categories,
       CMS.list_categories!(actor: actor, tenant: org, query: [sort: [name: :asc]])
     )
     |> assign(:tags, CMS.list_tags!(actor: actor, tenant: org, query: [sort: [name: :asc]]))
     |> assign(:locales, I18n.locales())
     |> assign(:show_filters?, false)
     |> assign(:saving_view?, false)
     |> assign(:renaming_view, nil)
     |> assign(:confirming_view_delete, nil)
     |> load_saved_views()}
  end

  # The actor's own views and the site's shared ones, plus which of them this
  # actor may rename or delete (the policy decides; the buttons follow it).
  defp load_saved_views(socket) do
    %{actor: actor, current_org: org} = socket.assigns
    views = CMS.list_saved_views!(actor: actor, tenant: org)

    manageable =
      for view <- views,
          CMS.can_update_saved_view?(actor, view, %{}, tenant: org),
          into: MapSet.new(),
          do: view.id

    socket
    |> assign(:saved_views, views)
    |> assign(:manageable_views, manageable)
  end

  # Only what the list renders — without a select, every row drags its whole
  # blocks JSONB tree (plus search_text and embedding) into the LiveView heap.
  # Workflow/destroy actions re-fetch the full record by id before acting.
  # `working_copy_at` is the *edited since publishing* marker
  # (docs/working-copy.md) — a timestamp column, not the working text.
  @list_fields [
    :id,
    :title,
    :slug,
    :state,
    :updated_at,
    :scheduled_at,
    # A proposed publish date (#1812) is shown to the reviewer on the row.
    :proposed_publish_at,
    :unpublish_at,
    :working_copy_at,
    # The "Last published" sort's key — selected so keyset paging can read it.
    :published_at
  ]

  # Only pulled for `in_review` (see `page_query/3`): the fields the compliance
  # badge scans (#856). `search_text` is the denormalized plain-text body — a
  # column read, not a `blocks` union cast — so this stays cheap relative to
  # what the full advisory panel does per keystroke in the editor.
  @compliance_fields [:search_text, :seo_title, :seo_description, :locale, :org_id]

  # (Re)load the first page under the active filter.
  defp load_items(socket) do
    {items, cursors} = fetch_page(socket, %{})

    socket
    |> assign(:items, items)
    |> assign(:cursors, cursors)
    |> assign(:more?, more?(cursors))
    |> assign(:total, count_items(socket))
    |> assign(:compliance_settings, compliance_settings(socket, items))
    |> assign_translated()
  end

  # Resolved once per load, not per row — `Settings.for_org/1` is cached, but a
  # cache read per row on a 50-row page is still 50 reads for one answer. Only
  # resolved for the status where it is used: the other filters never render
  # the badge, and `Settings.for_org/1` is a per-org (not per-request) cache,
  # so this is a real (if small) avoided cost, not just an unread assign.
  defp compliance_settings(socket, items) do
    if socket.assigns.filters["status"] == "in_review" and items != [],
      do: Settings.for_org(socket.assigns.current_org),
      else: nil
  end

  # `nil` (no badge) unless compliance is on for this org AND the document's
  # locale is one the shipped English pack can judge — the same `:n_a` posture
  # `KilnCMS.Compliance.Checks.Claims` takes: a document nobody scanned must
  # not render as clean.
  #
  # Scans the SAME fields the publish gate does
  # (`KilnCMS.CMS.Validations.ComplianceClaims`) — body text (via the
  # denormalized `search_text` column rather than re-deriving it from `blocks`,
  # since this is an informational list badge, not the gate itself), title,
  # SEO title, SEO description — so a phrase this badge shows and one the gate
  # would refuse are always the same phrase. The gate remains the actual
  # authority; this is visibility into what it will say.
  defp compliance_grade(_record, nil), do: nil

  defp compliance_grade(record, %Settings{enabled?: true} = settings) do
    if Settings.judgeable_locale?(settings, record.locale || I18n.default_locale()) do
      # Each field scanned on its own, never concatenated — joining them first
      # invents claims that are not in the document (see docs/compliance.md,
      # "The publish gate": a body ending "…at your own risk" beside a title
      # starting "Free…" would report "risk free" across the seam).
      [record.search_text, record.title, record.seo_title, record.seo_description]
      |> Enum.map(&(&1 |> to_string() |> Compliance.scan(settings.rules)))
      |> Enum.reduce(%{}, &Compliance.merge/2)
      |> grade_from_matches(settings.rules)
    end
  end

  defp compliance_grade(_record, _settings), do: nil

  # Same rule `Kiln.Advisory.Report`'s (private) grader uses — kept in sync by
  # hand since this list badge computes its own lightweight report rather than
  # running the full advisory pipeline per row.
  defp grade_from_matches(matches, rules) do
    severities =
      for {code, phrases} <- matches, phrases != [], do: Compliance.severity(code, rules)

    errors = Enum.count(severities, &(&1 == :error))
    warnings = Enum.count(severities, &(&1 == :warning))

    grade =
      cond do
        errors > 0 or warnings >= 3 -> :poor
        warnings > 0 -> :ok
        true -> :good
      end

    %{grade: grade, total: 0, passed: 0, findings: []}
  end

  # One page of `{kind, record}` tuples merged across every content type, in
  # the filter's order, continuing from `cursors` — per type, the keyset of the
  # last row of that type already shown, or `:done`.
  #
  # Each type is read as its own keyset page and the pages are merged by always
  # taking the earliest head, so what a type contributes is always a prefix of
  # its page. The next cursor for that type is then exactly its last shown row:
  # nothing is skipped or repeated whatever the sort, and a type that ran out
  # is not queried again.
  defp fetch_page(socket, cursors) do
    %{actor: actor, current_org: org, filters: filters} = socket.assigns
    query = page_query(filters, actor)

    streams =
      for ct <- filtered_types(socket), Map.get(cursors, type_value(ct)) != :done do
        cursor = Map.get(cursors, type_value(ct))
        page_opts = if cursor, do: [limit: @page_size, after: cursor], else: [limit: @page_size]

        # Dispatch on the descriptor itself so a type archived between listing
        # and dispatch can't turn into a registry-lookup miss. Scoped to the
        # current site's org (epic #336) so the index only lists this org's content.
        page = ContentTypes.list!(ct, actor: actor, tenant: org, query: query, page: page_opts)
        %{key: type_value(ct), kind: ct.type, rows: page.results, more?: page.more?}
      end

    {items, taken} = merge(streams, filters, @page_size, [], %{})

    cursors =
      Enum.reduce(streams, cursors, fn %{key: key} = stream, acc ->
        shown = Map.get(taken, key, [])
        left = length(stream.rows) - length(shown)

        cond do
          left == 0 and not stream.more? -> Map.put(acc, key, :done)
          shown == [] -> acc
          true -> Map.put(acc, key, hd(shown).__metadata__.keyset)
        end
      end)

    {items, cursors}
  end

  # Takes up to `n` rows off the heads of `streams` in the filter's order.
  # `taken` holds each type's shown rows, newest-taken first.
  defp merge(_streams, _filters, 0, acc, taken), do: {Enum.reverse(acc), taken}

  defp merge(streams, filters, n, acc, taken) do
    case Enum.filter(streams, &(&1.rows != [])) do
      [] ->
        {Enum.reverse(acc), taken}

      live ->
        first = Enum.reduce(live, &earliest(filters, &1, &2))
        [row | rest] = first.rows
        streams = Enum.map(streams, &if(&1.key == first.key, do: %{&1 | rows: rest}, else: &1))
        taken = Map.update(taken, first.key, [row], &[row | &1])
        merge(streams, filters, n - 1, [{first.kind, row} | acc], taken)
    end
  end

  defp earliest(filters, stream, best),
    do: if(Filters.before?(filters, hd(stream.rows), hd(best.rows)), do: stream, else: best)

  defp more?(cursors), do: Enum.any?(cursors, fn {_key, cursor} -> cursor != :done end)

  # How many rows the filter matches across the types it reads — one count per
  # type, through the same filters as the page (#1593).
  defp count_items(socket) do
    %{actor: actor, current_org: org, filters: filters} = socket.assigns
    query = Filters.query_filters(filters, actor.id)

    socket
    |> filtered_types()
    |> Enum.map(&ContentTypes.count!(&1, actor: actor, tenant: org, query: query))
    |> Enum.sum()
  end

  defp page_query(filters, actor) do
    # Widened only for `in_review` (#856): the other filters never render the
    # compliance badge, so they keep the narrower select the comment on
    # `@list_fields` explains the cost of.
    select =
      if filters["status"] == "in_review",
        do: @list_fields ++ @compliance_fields,
        else: @list_fields

    Filters.query_filters(filters, actor.id) ++ [select: select, sort: Filters.sort(filters)]
  end

  # Everything editable here: compiled content types plus admin-defined dynamic
  # ones (D17) — the descriptors share a shape, and `ContentTypes` dispatch
  # routes dynamic kinds (name strings) to the generic entry tier.
  # Scoped to the current site's org (epic #336), like every sibling page
  # (`trash_live`, `calendar_live`, …): the dynamic registry is per-org, so the
  # type filter and the "New …" buttons must offer *this* site's types.
  # Only the types this actor may actually author. `all_for_org/1` returned every
  # type regardless of the actor, so the "New …" buttons, the type filter and the
  # row actions all offered work the create policy would refuse — an editor
  # scoped to `editable_types: ["post"]` saw a Duplicate button on every page row
  # whose only possible outcome was an error flash (#926).
  #
  # The same question the create policy asks, shared with the unsaved-editor
  # mount and the calendar's "new on this day" picker, so the button and the
  # page it opens cannot disagree.
  defp editable_types(org_id, actor), do: NewDraft.authorable_types(actor, org_id)

  # The types this page pulls rows from: every editable type, or just the one
  # the `type` filter names. Filtering here rather than after the merge keeps
  # the DB from reading rows we'd only throw away, and keeps the per-type
  # `@page_size` window (so "Load more" still reaches every match).
  defp filtered_types(%{assigns: %{type: "all", content_types: types}}), do: types

  defp filtered_types(%{assigns: %{type: type, content_types: types}}),
    do: Enum.filter(types, &(type_value(&1) == type))

  # A descriptor's filter/URL value. Compiled types carry an atom `type`,
  # dynamic ones (D17) a name string — the URL only ever speaks strings.
  defp type_value(%{type: type}), do: to_string(type)

  @impl true
  # Opens the editor on an UNSAVED document; no row is written here. The first
  # title or Save creates it (`KilnCMSWeb.ContentEditor.NewDraft`), so an
  # abandoned click no longer leaves an "Untitled …" draft behind. The `/new`
  # mount re-checks who may author the type — this button is not the boundary.
  def handle_event("new", %{"kind" => kind}, socket) when is_binary(kind) do
    {:noreply, push_navigate(socket, to: ~p"/editor/content/#{kind}/new")}
  end

  # Filter state lives in the URL (audit U-M3): refresh, back button, and
  # shared links keep the active filter. Typing replaces the history entry so
  # a search doesn't leave one entry per debounced keystroke.
  # One form drives every select, so a change to any arrives with the rest of
  # the form; keys the form does not render (the `type` select on a single-type
  # site, the panel's facets while it is closed) keep their current value.
  # Every value is re-checked by `Filters.parse/2`, so a crafted payload can
  # only narrow the list to nothing.
  def handle_event("filter", params, socket) when is_map(params) do
    form = Map.take(params, Filters.defaults() |> Map.keys() |> List.delete("q"))
    {:noreply, patch_filters(socket, form)}
  end

  # `is_binary(q)` guards against a pushed `%{"q" => []}` (#764). A wrong shape
  # falls through to the catch-all `KilnCMSWeb.MalformedEvent` appends.
  def handle_event("search", %{"q" => q}, socket) when is_binary(q) do
    {:noreply, patch_filters(socket, %{"q" => q}, replace: true)}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/editor", replace: true)}
  end

  # A chip's remove button: back to that facet's default.
  def handle_event("remove_filter", %{"key" => key}, socket) when is_binary(key) do
    {:noreply, patch_filters(socket, %{key => Map.get(Filters.defaults(), key)})}
  end

  def handle_event("toggle_filters", _params, socket),
    do: {:noreply, update(socket, :show_filters?, &(not &1))}

  # --- saved views (#1593) ---------------------------------------------------

  def handle_event("open_save_view", _params, socket) do
    {:noreply,
     socket
     |> assign(:saving_view?, true)
     |> assign(:renaming_view, nil)
     |> assign(:confirming_view_delete, nil)}
  end

  def handle_event("cancel_save_view", _params, socket),
    do: {:noreply, assign(socket, :saving_view?, false)}

  def handle_event("save_view", %{"name" => name} = params, socket) when is_binary(name) do
    %{actor: actor, current_org: org, filters: filters} = socket.assigns

    attrs = %{
      name: name,
      params: Filters.to_params(filters),
      # Only an admin is offered the box; the policy refuses it for anyone else.
      shared: params["shared"] == "true"
    }

    case CMS.create_saved_view(attrs, actor: actor, tenant: org) do
      {:ok, view} ->
        {:noreply,
         socket
         |> assign(:saving_view?, false)
         |> load_saved_views()
         |> put_flash(:info, gettext("Saved the view “%{name}”.", name: view.name))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, view_error(error))}
    end
  end

  def handle_event("start_rename_view", %{"id" => id}, socket) when is_binary(id) do
    {:noreply,
     socket
     |> assign(:renaming_view, find_view(socket, id))
     |> assign(:saving_view?, false)
     |> assign(:confirming_view_delete, nil)}
  end

  def handle_event("cancel_rename_view", _params, socket),
    do: {:noreply, assign(socket, :renaming_view, nil)}

  def handle_event("rename_view", %{"view_id" => id, "name" => name}, socket)
      when is_binary(id) and is_binary(name) do
    %{actor: actor, current_org: org} = socket.assigns

    with %{} = view <- find_view(socket, id),
         {:ok, view} <- CMS.update_saved_view(view, %{name: name}, actor: actor, tenant: org) do
      {:noreply,
       socket
       |> assign(:renaming_view, nil)
       |> load_saved_views()
       |> put_flash(:info, gettext("Renamed the view to “%{name}”.", name: view.name))}
    else
      nil -> {:noreply, assign(socket, :renaming_view, nil)}
      {:error, error} -> {:noreply, put_flash(socket, :error, view_error(error))}
    end
  end

  def handle_event("delete_view", %{"id" => id}, socket) when is_binary(id) do
    {:noreply,
     socket
     |> assign(:confirming_view_delete, find_view(socket, id))
     |> assign(:saving_view?, false)
     |> assign(:renaming_view, nil)}
  end

  def handle_event("cancel_delete_view", _params, socket),
    do: {:noreply, assign(socket, :confirming_view_delete, nil)}

  def handle_event("confirm_delete_view", %{"id" => id}, socket) when is_binary(id) do
    %{actor: actor, current_org: org} = socket.assigns

    with %{} = view <- find_view(socket, id),
         :ok <- CMS.destroy_saved_view(view, actor: actor, tenant: org) do
      {:noreply,
       socket
       |> assign(:confirming_view_delete, nil)
       |> load_saved_views()
       |> put_flash(:info, gettext("Deleted the view “%{name}”.", name: view.name))}
    else
      nil -> {:noreply, assign(socket, :confirming_view_delete, nil)}
      {:error, error} -> {:noreply, put_flash(socket, :error, view_error(error))}
    end
  end

  def handle_event("toggle_select", %{"key" => key}, socket) when is_binary(key) do
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
  #
  # Only a verb this tier is actually offered (`bulk_verbs/2`, the list the bar
  # renders from) opens it: a crafted phx-value naming publish or delete as an
  # editor would otherwise open a confirm bar for an action policy then refuses
  # on every row.
  def handle_event("bulk", %{"action" => verb}, socket) when is_binary(verb) do
    if verb in bulk_verbs(socket.assigns.tier, socket.assigns.editors_can_publish) do
      confirming = if MapSet.size(socket.assigns.selected) > 0, do: verb
      {:noreply, assign(socket, :confirming_bulk, confirming)}
    else
      {:noreply, put_flash(socket, :error, KilnCMSWeb.WorkflowMessages.forbidden(verb))}
    end
  end

  def handle_event("cancel_bulk", _params, socket),
    do: {:noreply, assign(socket, :confirming_bulk, nil)}

  # "Add to release" (#500) is a bulk verb with an argument — which release, and
  # whether the release publishes or unpublishes the selection — so it opens its
  # own panel instead of reusing the yes/no confirm bar.
  def handle_event("open_release_panel", _params, socket) do
    {:noreply,
     socket
     |> assign(:adding_to_release?, MapSet.size(socket.assigns.selected) > 0)
     |> assign(:confirming_bulk, nil)}
  end

  def handle_event("cancel_release_panel", _params, socket),
    do: {:noreply, assign(socket, :adding_to_release?, false)}

  def handle_event(
        "add_to_release",
        %{"release_id" => release_id, "release_action" => action},
        socket
      )
      when action in ~w(publish unpublish) and is_binary(release_id) do
    opts = [actor: socket.assigns.actor, tenant: socket.assigns.current_org]

    {added, skipped} =
      Enum.reduce(socket.assigns.selected, {0, 0}, fn key, {added, skipped} ->
        [kind, id] = String.split(key, ":", parts: 2)

        attrs = %{
          release_id: release_id,
          content_type: kind,
          content_id: id,
          action: String.to_existing_atom(action)
        }

        case CMS.add_release_item(attrs, opts) do
          {:ok, _item} -> {added + 1, skipped}
          {:error, _error} -> {added, skipped + 1}
        end
      end)

    {:noreply,
     socket
     |> assign(:selected, MapSet.new())
     |> assign(:adding_to_release?, false)
     |> put_flash(:info, release_flash(added, skipped))}
  end

  def handle_event("add_to_release", _params, socket),
    do: {:noreply, put_flash(socket, :error, gettext("Pick a release first."))}

  def handle_event("confirm_bulk", _params, socket) do
    verb = socket.assigns.confirming_bulk
    actor = socket.assigns.actor
    org = socket.assigns.current_org

    {ok, skipped} =
      Enum.reduce(socket.assigns.selected, {0, 0}, fn key, {ok, skipped} ->
        [kind, id] = String.split(key, ":", parts: 2)

        result =
          if verb == "delete",
            do: destroy(kind, id, actor, org),
            else: do_transition(kind, verb, get!(kind, id, actor, org), actor, org)

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

  # "Confirm date" on a row with a proposed publish date (#1812): the
  # proposal becomes `scheduled_at`. It is an ordinary write of `scheduled_at`
  # — the content policy authorizes it exactly as it does setting a publish
  # date anywhere else, and `Changes.ClearProposedPublishAt` clears the
  # proposal in the same write.
  def handle_event("confirm_proposed_date", %{"kind" => kind, "id" => id}, socket)
      when is_binary(kind) and is_binary(id) do
    %{actor: actor, current_org: org} = socket.assigns
    record = get!(kind, id, actor, org)

    with %DateTime{} = at <- record.proposed_publish_at,
         {:ok, _record} <-
           ContentTypes.update(kind, record, %{scheduled_at: at}, actor: actor, tenant: org) do
      {:noreply,
       socket
       |> load_items()
       |> put_flash(
         :info,
         gettext("Scheduled to publish on %{date} UTC.",
           date: Calendar.strftime(at, "%-d %B %Y, %H:%M")
         )
       )}
    else
      nil ->
        {:noreply, load_items(socket)}

      {:error, _error} ->
        {:noreply,
         put_flash(socket, :error, gettext("You can't set the publish date of this content."))}
    end
  end

  # Clone a row into a new draft and land the editor in it (#471) — the same
  # verb the content editor's own Duplicate button runs.
  def handle_event("duplicate", %{"kind" => kind, "id" => id}, socket)
      when is_binary(kind) and is_binary(id) do
    %{actor: actor, current_org: org} = socket.assigns

    # `kind`/`id` come off the clicked row, so they are client input: pass them
    # straight through rather than pre-fetching, so an unknown type or an
    # unreachable id lands in the error branch instead of crashing the LiveView
    # (`duplicate/3` re-reads the record either way).
    case KilnCMS.CMS.Duplication.duplicate(kind, id, actor: actor, tenant: org) do
      {:ok, copy, []} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Duplicated as a new draft."))
         |> push_navigate(to: edit_path(kind, copy.id))}

      # Some of the source did not travel — a field grant dropped attributes, or
      # the block policy reset values this editor could not have set. Saying so
      # is the difference between "duplication is broken" and "your role cannot
      # copy those fields" (#929).
      {:ok, copy, withheld} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext(
             "Duplicated as a new draft. Not copied, because your role cannot set them: %{fields}.",
             fields: Enum.join(withheld, ", ")
           )
         )
         |> push_navigate(to: edit_path(kind, copy.id))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't duplicate that content."))}
    end
  end

  def handle_event("load_more", _params, socket) do
    case List.last(socket.assigns.items) do
      nil ->
        {:noreply, assign(socket, :more?, false)}

      {_kind, _last} ->
        {page, cursors} = fetch_page(socket, socket.assigns.cursors)

        {:noreply,
         socket
         |> assign(:items, socket.assigns.items ++ page)
         |> assign(:cursors, cursors)
         |> assign(:more?, more?(cursors))
         |> assign_translated()}
    end
  end

  # The "fully translated" bit of each row's status marks: which visible
  # {kind, slug} groups have a variant in every configured locale. One
  # slug-batched query per kind on the visible page; `nil` (single-locale
  # site) means trivially covered.
  defp assign_translated(socket) do
    locales = I18n.locales()

    if length(locales) < 2 do
      assign(socket, :translated, nil)
    else
      actor = socket.assigns.actor
      org = socket.assigns.current_org

      translated =
        socket.assigns.items
        |> Enum.group_by(fn {kind, _r} -> kind end, fn {_kind, r} -> r.slug end)
        |> Enum.flat_map(fn {kind, slugs} -> covered_slugs(kind, slugs, locales, actor, org) end)
        |> MapSet.new()

      assign(socket, :translated, translated)
    end
  end

  # The {kind, slug} pairs among `slugs` whose slug group has a variant in
  # every configured locale.
  defp covered_slugs(kind, slugs, locales, actor, org) do
    kind
    |> ContentTypes.list!(
      actor: actor,
      tenant: org,
      query: [filter: expr(slug in ^slugs), select: [:slug, :locale]]
    )
    |> Enum.group_by(& &1.slug, & &1.locale)
    |> Enum.filter(fn {_slug, ls} -> Enum.all?(locales, &(&1 in ls)) end)
    |> Enum.map(fn {slug, _ls} -> {kind, slug} end)
  end

  defp translated?(nil, _kind, _slug), do: true
  defp translated?(set, kind, slug), do: MapSet.member?(set, {kind, slug})

  # The trigram's "scheduled" bit: a pending transition the calendar would
  # show — publish for drafts/in-review, unpublish for published.
  defp scheduled?(%{state: state} = r) when state in [:draft, :in_review],
    do: not is_nil(r.scheduled_at)

  defp scheduled?(%{state: :published} = r), do: not is_nil(r.unpublish_at)
  defp scheduled?(_record), do: false

  @impl true
  def handle_params(params, _uri, socket) do
    types = editable_types(socket.assigns.current_org.id, socket.assigns.actor)
    socket = assign(socket, :content_types, types)

    # Every value is checked against what it can be (`Filters.parse/2`): an
    # unknown `type` (hand-edited URL, or a type deleted/archived since the
    # link was shared) falls back to "all" rather than listing nothing, and
    # `?q[a]=1` — a MAP — reads as absent instead of raising (#764).
    filters = Filters.parse(params, filter_ctx(socket))

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:status, filters["status"])
     |> assign(:type, filters["type"])
     |> assign(:query, filters["q"])
     |> assign(:saving_view?, false)
     |> assign(:renaming_view, nil)
     |> assign(:confirming_view_delete, nil)
     |> load_releases()
     |> load_items()}
  end

  defp filter_ctx(socket) do
    %{
      types: Enum.map(socket.assigns.content_types, &type_value/1),
      locales: socket.assigns.locales
    }
  end

  # Releases still open for new content (#500), for the "Add to release" bulk
  # action. Reloaded per navigation like the type registry, so a release created
  # in another tab shows up on the next filter change rather than needing a
  # reload of this page.
  defp load_releases(socket) do
    releases =
      CMS.list_editable_releases!(
        actor: socket.assigns.actor,
        tenant: socket.assigns.current_org
      )

    socket |> assign(:releases, releases) |> assign(:adding_to_release?, false)
  end

  defp list_path(filters), do: params_path(Filters.to_params(filters))

  defp params_path(params) when params == %{}, do: ~p"/editor"
  defp params_path(params), do: ~p"/editor?#{params}"

  # A view's link: its params, re-read under today's types and locales so a
  # stale view links to what it would actually show.
  defp view_params(view, ctx), do: view.params |> Filters.parse(ctx) |> Filters.to_params()

  # Patches the URL to the current filter with `changes` applied.
  defp patch_filters(socket, changes, opts \\ []) do
    filters =
      socket.assigns.filters
      |> Map.merge(changes)
      |> Filters.parse(filter_ctx(socket))

    push_patch(socket, Keyword.put(opts, :to, list_path(filters)))
  end

  # Only views the actor can see are ever looked up: the id is client input.
  defp find_view(socket, id), do: Enum.find(socket.assigns.saved_views, &(&1.id == id))

  defp view_error(%Ash.Error.Forbidden{}),
    do: gettext("You can't change that view. Only an admin can share or edit a shared view.")

  defp view_error(_error), do: gettext("Give the view a name, up to 255 characters.")

  defp transition(socket, %{"kind" => kind, "id" => id}, verb) do
    actor = socket.assigns.actor
    org = socket.assigns.current_org
    record = get!(kind, id, actor, org)

    # Flash copy shared with the content editor, chosen from the error the
    # transition returned rather than from the verb (see WorkflowMessages).
    case do_transition(kind, verb, record, actor, org) do
      {:ok, record} ->
        socket
        |> load_items()
        |> put_flash(:info, KilnCMSWeb.WorkflowMessages.success(verb, record.state))

      {:error, error} ->
        put_flash(socket, :error, KilnCMSWeb.WorkflowMessages.error(verb, error))
    end
  end

  # All dispatch to the current site's org (epic #336): reads/writes are
  # tenant-scoped so an editor on one site's subdomain can only see and act on
  # that site's content. `org_id` is writable? false, so the tenant is the only
  # way to set/scope it.
  defp get!(kind, id, actor, org),
    do: ContentTypes.get_record!(kind, id, actor: actor, tenant: org)

  defp do_transition(kind, verb, record, actor, org),
    do: ContentTypes.transition(kind, verb, record, actor: actor, tenant: org)

  # Hard delete (soft via archival). Admin-only; the policy rejects others, in
  # which case the item is counted as skipped.
  defp destroy(kind, id, actor, org),
    do: ContentTypes.destroy(kind, get!(kind, id, actor, org), actor: actor, tenant: org)

  # The set of selection keys ("kind:id") for the currently loaded items (the
  # status/search filter already ran server-side).
  defp visible_keys(socket) do
    MapSet.new(socket.assigns.items, fn {kind, r} -> "#{kind}:#{r.id}" end)
  end

  defp edit_path(type, id), do: ~p"/editor/content/#{type}/#{id}"

  defp bulk_actions(tier, editors_can_publish)
       when tier == :admin or (tier == :editor and editors_can_publish) do
    [
      {"publish", gettext("Publish")},
      {"unpublish", gettext("Unpublish")},
      {"archive", gettext("Archive")},
      {"unarchive", gettext("Unarchive")}
    ]
  end

  defp bulk_actions(_tier, _editors_can_publish) do
    [
      {"submit", gettext("Submit for review")},
      {"unpublish", gettext("Unpublish")},
      {"archive", gettext("Archive")},
      {"unarchive", gettext("Unarchive")}
    ]
  end

  # Every verb the bulk bar offers `tier`: the menu above, plus Delete, which
  # the bar renders on its own button for admins only (`:if={@tier == :admin}`).
  defp bulk_verbs(tier, editors_can_publish) do
    verbs = Enum.map(bulk_actions(tier, editors_can_publish), &elem(&1, 0))
    if tier == :admin, do: verbs ++ ["delete"], else: verbs
  end

  defp bulk_verb_label("publish"), do: gettext("Publish")
  defp bulk_verb_label("submit"), do: gettext("Submit for review")
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

  defp bulk_confirm_prompt("submit", n),
    do:
      gettext(
        "Submit %{count} selected draft(s) for review? An admin must publish them.",
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

  # "Skipped" here has one dominant cause worth naming: a record already sitting
  # in another open release, which the database refuses (#500's conflict rule).
  defp release_flash(added, 0),
    do: gettext("Added %{count} item(s) to the release", count: added)

  defp release_flash(added, skipped) do
    gettext(
      "Added %{count} item(s); %{skipped} skipped — already in another open release, or not addable",
      count: added,
      skipped: skipped
    )
  end

  @impl true
  def render(assigns) do
    visible_keys = MapSet.new(assigns.items, fn {kind, r} -> "#{kind}:#{r.id}" end)

    assigns =
      assigns
      |> assign(:filtering?, Filters.active?(assigns.filters))
      |> assign_views()
      |> assign(:selected_count, MapSet.size(assigns.selected))
      |> assign(:compiled_types, Enum.filter(assigns.content_types, &(&1.source == :compiled)))
      |> assign(:dynamic_types, Enum.filter(assigns.content_types, &(&1.source == :dynamic)))
      |> assign(
        :all_selected?,
        MapSet.size(visible_keys) > 0 and MapSet.subset?(visible_keys, assigns.selected)
      )

    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={gettext("Content")}
      active={:content}
    >
      <:actions>
        <%!-- A handful of types reads best as direct buttons; past that the row
              (even wrapping) crowds out the top bar, so collapse into one menu.
              CSS-only <details>, same pattern as the mobile nav disclosure. --%>
        <.button
          :for={ct <- @content_types}
          :if={length(@content_types) <= @max_inline_new_buttons}
          type="button"
          phx-click="new"
          phx-value-kind={ct.type}
          variant="primary"
          size="sm"
        >
          <.icon name="hero-plus" class="size-4" />
          {gettext("New %{type}", type: String.downcase(ct.label))}
        </.button>
        <details
          :if={length(@content_types) > @max_inline_new_buttons}
          id="content-new-menu"
          class="relative"
        >
          <summary class="btn btn-primary btn-sm cursor-pointer list-none [&::-webkit-details-marker]:hidden">
            <.icon name="hero-plus" class="size-4" />
            {gettext("New")}
            <.icon name="hero-chevron-down" class="size-3.5" />
          </summary>
          <div class="absolute right-0 z-30 mt-2 flex max-h-96 w-56 flex-col gap-0.5 overflow-y-auto rounded-lg border border-base-content/10 bg-base-100 p-1.5 shadow-lg">
            <button
              :for={ct <- @content_types}
              type="button"
              phx-click="new"
              phx-value-kind={ct.type}
              class="rounded-md px-2.5 py-1.5 text-left text-sm hover:bg-base-200"
            >
              {gettext("New %{type}", type: String.downcase(ct.label))}
            </button>
          </div>
        </details>
      </:actions>

      <div class="space-y-5">
        <div>
          <h1 class="text-xl font-semibold tracking-tight">{gettext("Content")}</h1>
          <p class="text-sm text-base-content/60">
            {gettext("Pages, posts and custom types across your site.")}
          </p>
        </div>

        <%!-- Views (#1593): built-in filters with a name, then the actor's own
              saved views and the site's shared ones. Each is a link to its
              filter's URL, so it works without the socket, opens in a new
              tab, and the back button walks between views. --%>
        <nav
          :if={@items != [] or @filtering? or @saved_views != []}
          id="content-views"
          aria-label={gettext("Views")}
          class="space-y-2"
        >
          <ul class="flex flex-wrap items-center gap-1.5">
            <li :for={view <- @default_views}>
              <.link
                patch={view.path}
                id={"view-#{view.id}"}
                aria-current={view.id == @active_view_id && "page"}
                class="inline-flex items-center gap-1.5 rounded-full border border-base-content/15 px-3 py-1 text-sm text-base-content/80 transition-colors hover:border-base-content/30 hover:bg-base-200 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary aria-[current=page]:border-primary aria-[current=page]:bg-primary aria-[current=page]:text-primary-content"
              >
                {view.name}
              </.link>
            </li>
            <li :for={view <- @saved_views}>
              <.link
                patch={params_path(view_params(view, @filter_ctx))}
                id={"view-#{view.id}"}
                aria-current={view.id == @active_view_id && "page"}
                class="inline-flex items-center gap-1.5 rounded-full border border-base-content/15 px-3 py-1 text-sm text-base-content/80 transition-colors hover:border-base-content/30 hover:bg-base-200 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary aria-[current=page]:border-primary aria-[current=page]:bg-primary aria-[current=page]:text-primary-content"
              >
                <.icon
                  :if={view.shared}
                  name="hero-user-group"
                  class="size-3.5"
                />
                <span :if={view.shared} class="sr-only">{gettext("Shared:")}</span>
                {view.name}
              </.link>
            </li>
            <li :if={@filtering? and is_nil(@active_view_id) and not @saving_view?}>
              <button
                type="button"
                id="save-view"
                phx-click="open_save_view"
                class="btn btn-sm btn-ghost text-primary-ink"
              >
                <.icon name="hero-bookmark" class="size-4" />
                {gettext("Save view")}
              </button>
            </li>
          </ul>

          <form
            :if={@saving_view?}
            id="save-view-form"
            phx-submit="save_view"
            class="flex flex-wrap items-end gap-3 rounded-lg border border-primary/30 bg-primary/5 px-3 py-2 text-sm"
          >
            <div>
              <label for="save-view-name" class="field-label">{gettext("View name")}</label>
              <input
                id="save-view-name"
                type="text"
                name="name"
                required
                maxlength="255"
                autocomplete="off"
                phx-mounted={JS.focus()}
                class="field-input w-64"
              />
            </div>
            <label :if={@tier == :admin} class="flex items-center gap-2 pb-2">
              <input type="checkbox" name="shared" value="true" class="size-4 accent-primary" />
              {gettext("Share with every editor on this site")}
            </label>
            <div class="ml-auto flex gap-2">
              <button type="submit" class="btn btn-sm btn-primary">{gettext("Save view")}</button>
              <button type="button" phx-click="cancel_save_view" class="btn btn-sm btn-default">
                {gettext("Cancel")}
              </button>
            </div>
          </form>

          <%!-- The view on screen, when it is one this actor may change. --%>
          <div
            :if={@active_saved_view && MapSet.member?(@manageable_views, @active_saved_view.id)}
            class="flex flex-wrap items-center gap-2 text-sm"
          >
            <span class="text-base-content/60">
              {if @active_saved_view.shared,
                do: gettext("Shared view, listed for every editor on this site."),
                else: gettext("Your view. Only you can see it.")}
            </span>
            <button
              :if={is_nil(@renaming_view) and is_nil(@confirming_view_delete)}
              type="button"
              phx-click="start_rename_view"
              phx-value-id={@active_saved_view.id}
              class="btn btn-sm btn-ghost"
            >
              {gettext("Rename")}
            </button>
            <button
              :if={is_nil(@renaming_view) and is_nil(@confirming_view_delete)}
              type="button"
              phx-click="delete_view"
              phx-value-id={@active_saved_view.id}
              class="btn btn-sm btn-ghost hover:text-error"
            >
              {gettext("Delete view")}
            </button>
          </div>

          <form
            :if={@renaming_view}
            id="rename-view-form"
            phx-submit="rename_view"
            class="flex flex-wrap items-end gap-3 rounded-lg border border-base-content/15 px-3 py-2 text-sm"
          >
            <input type="hidden" name="view_id" value={@renaming_view.id} />
            <div>
              <label for="rename-view-name" class="field-label">{gettext("New name")}</label>
              <input
                id="rename-view-name"
                type="text"
                name="name"
                value={@renaming_view.name}
                required
                maxlength="255"
                autocomplete="off"
                phx-mounted={JS.focus()}
                class="field-input w-64"
              />
            </div>
            <div class="ml-auto flex gap-2">
              <button type="submit" class="btn btn-sm btn-primary">{gettext("Rename")}</button>
              <button type="button" phx-click="cancel_rename_view" class="btn btn-sm btn-default">
                {gettext("Cancel")}
              </button>
            </div>
          </form>

          <div
            :if={@confirming_view_delete}
            id="delete-view-confirm"
            role="alertdialog"
            aria-labelledby="delete-view-prompt"
            class="flex flex-wrap items-center gap-3 rounded border border-error/40 bg-error/10 px-3 py-2 text-sm"
          >
            <span id="delete-view-prompt">
              {gettext("Delete the view “%{name}”? The content in it is not touched.",
                name: @confirming_view_delete.name
              )}
            </span>
            <div class="ml-auto flex gap-2">
              <button
                type="button"
                phx-click="confirm_delete_view"
                phx-value-id={@confirming_view_delete.id}
                phx-mounted={JS.focus()}
                class="btn btn-sm border-transparent bg-error text-error-content hover:opacity-90"
              >
                {gettext("Delete view")}
              </button>
              <button type="button" phx-click="cancel_delete_view" class="btn btn-sm btn-default">
                {gettext("Cancel")}
              </button>
            </div>
          </div>
        </nav>

        <div :if={@items != [] or @filtering?} class="space-y-3">
          <div class="flex flex-wrap items-center gap-3">
            <%!-- The content tree for this type (#1597, D21). Only with ONE type
                    selected: a parent is a record of the same type, so a tree
                    cannot span types and "all" has no structure to show. --%>
            <.link
              :if={@filters["type"] not in [nil, "", "all"]}
              navigate={~p"/editor/structure/#{@filters["type"]}"}
              class="btn btn-default"
            >
              <.icon name="hero-bars-3-bottom-left" class="size-4" />
              {gettext("Structure")}
            </.link>

            <form id="content-search" phx-change="search" phx-submit="search" class="min-w-48 flex-1">
              <label for="content-search-input" class="sr-only">{gettext("Search by title")}</label>
              <input
                id="content-search-input"
                type="search"
                name="q"
                value={@query}
                placeholder={gettext("Search by title")}
                aria-label={gettext("Search by title")}
                phx-debounce="200"
                autocomplete="off"
                class="field-input max-w-xs"
              />
            </form>
            <form
              id="content-filter"
              phx-change="filter"
              class="flex flex-wrap items-center gap-3"
            >
              <label for="content-status-filter" class="sr-only">{gettext("Filter by status")}</label>
              <select
                id="content-status-filter"
                name="status"
                aria-label={gettext("Filter by status")}
                class="field-select w-auto"
              >
                <option :for={status <- @statuses} value={status} selected={status == @status}>
                  {status_filter_label(status)}
                </option>
              </select>
              <%!-- Nothing to choose between on a single-type site, so the select
                    only appears once there are at least two types. --%>
              <label
                :if={length(@content_types) > 1}
                for="content-type-filter"
                class="sr-only"
              >
                {gettext("Filter by type")}
              </label>
              <select
                :if={length(@content_types) > 1}
                id="content-type-filter"
                name="type"
                aria-label={gettext("Filter by type")}
                class="field-select w-auto"
              >
                <option value="all" selected={@type == "all"}>{gettext("All types")}</option>
                <%!-- Built-in vs admin-defined, same grouping the field-definition
                      type picker uses. Only the "Custom" group is conditional —
                      a site with no dynamic types shouldn't show an empty group. --%>
                <optgroup :if={@compiled_types != []} label={gettext("Built-in")}>
                  <option
                    :for={ct <- @compiled_types}
                    value={type_value(ct)}
                    selected={type_value(ct) == @type}
                  >
                    {ct.label}
                  </option>
                </optgroup>
                <optgroup :if={@dynamic_types != []} label={gettext("Custom")}>
                  <option
                    :for={ct <- @dynamic_types}
                    value={type_value(ct)}
                    selected={type_value(ct) == @type}
                  >
                    {ct.label}
                  </option>
                </optgroup>
              </select>
              <label for="content-sort" class="sr-only">{gettext("Sort by")}</label>
              <select
                id="content-sort"
                name="sort"
                aria-label={gettext("Sort by")}
                class="field-select w-auto"
              >
                <option
                  :for={sort <- Filters.sorts()}
                  value={sort}
                  selected={sort == @filters["sort"]}
                >
                  {Filters.sort_label(sort)}
                </option>
              </select>
              <button
                type="button"
                id="toggle-filters"
                phx-click="toggle_filters"
                aria-expanded={to_string(@show_filters?)}
                aria-controls="content-facets"
                class="btn btn-sm btn-default"
              >
                <.icon name="hero-adjustments-horizontal" class="size-4" />
                {gettext("More filters")}
                <.badge :if={@panel_count > 0} variant="primary">{@panel_count}</.badge>
              </button>

              <%!-- The facets past status and type, behind one toggle so the
                    bar stays one row. Rendered inside the same form, so any
                    change here arrives with the rest of the filter. --%>
              <fieldset
                :if={@show_filters?}
                id="content-facets"
                class="grid w-full grid-cols-1 gap-3 rounded-lg border border-base-content/10 bg-base-200/30 p-3 sm:grid-cols-2 lg:grid-cols-4"
              >
                <legend class="sr-only">{gettext("More filters")}</legend>
                <div>
                  <label for="content-author-filter" class="field-label">{gettext("Author")}</label>
                  <select id="content-author-filter" name="author" class="field-select">
                    <option value="">{gettext("Anyone")}</option>
                    <option value="me" selected={@filters["author"] == "me"}>{gettext("Me")}</option>
                    <option
                      :for={{label, id} <- @authors}
                      value={id}
                      selected={@filters["author"] == id}
                    >
                      {label}
                    </option>
                  </select>
                </div>
                <div :if={@categories != []}>
                  <label for="content-category-filter" class="field-label">
                    {gettext("Category")}
                  </label>
                  <select id="content-category-filter" name="category" class="field-select">
                    <option value="">{gettext("Any category")}</option>
                    <option
                      :for={category <- @categories}
                      value={category.id}
                      selected={@filters["category"] == category.id}
                    >
                      {category.name}
                    </option>
                  </select>
                </div>
                <div :if={@tags != []}>
                  <label for="content-tag-filter" class="field-label">{gettext("Tag")}</label>
                  <select id="content-tag-filter" name="tag" class="field-select">
                    <option value="">{gettext("Any tag")}</option>
                    <option :for={tag <- @tags} value={tag.id} selected={@filters["tag"] == tag.id}>
                      {tag.name}
                    </option>
                  </select>
                </div>
                <div :if={length(@locales) > 1}>
                  <label for="content-locale-filter" class="field-label">{gettext("Language")}</label>
                  <select id="content-locale-filter" name="locale" class="field-select">
                    <option value="">{gettext("Any language")}</option>
                    <option
                      :for={locale <- @locales}
                      value={locale}
                      selected={@filters["locale"] == locale}
                    >
                      {locale}
                    </option>
                  </select>
                </div>
                <div>
                  <label for="content-health-filter" class="field-label">{gettext("Review")}</label>
                  <select id="content-health-filter" name="health" class="field-select">
                    <option value="">{gettext("Any")}</option>
                    <option
                      :for={health <- Filters.healths()}
                      value={health}
                      selected={@filters["health"] == health}
                    >
                      {Filters.health_label(health)}
                    </option>
                  </select>
                </div>
                <div>
                  <label for="content-from-filter" class="field-label">
                    {gettext("Updated from")}
                  </label>
                  <input
                    id="content-from-filter"
                    type="date"
                    name="from"
                    value={@filters["from"]}
                    class="field-input"
                  />
                </div>
                <div>
                  <label for="content-to-filter" class="field-label">{gettext("Updated until")}</label>
                  <input
                    id="content-to-filter"
                    type="date"
                    name="to"
                    value={@filters["to"]}
                    class="field-input"
                  />
                </div>
                <label class="flex items-center gap-2 self-end pb-2 text-sm">
                  <input type="hidden" name="scheduled" value="" />
                  <input
                    id="content-scheduled-filter"
                    type="checkbox"
                    name="scheduled"
                    value="1"
                    checked={@filters["scheduled"] == "1"}
                    class="size-4 accent-primary"
                  />
                  {gettext("Only scheduled to publish")}
                </label>
              </fieldset>
            </form>
          </div>

          <%!-- One chip per active facet, each its own remove button. --%>
          <div
            :if={@chips != [] or @filtering?}
            class="flex flex-wrap items-center gap-2"
          >
            <ul :if={@chips != []} id="content-filter-chips" class="flex flex-wrap gap-2">
              <li :for={{key, label} <- @chips}>
                <button
                  type="button"
                  phx-click="remove_filter"
                  phx-value-key={key}
                  aria-label={gettext("Remove filter: %{filter}", filter: label)}
                  class="inline-flex items-center gap-1 rounded-full bg-primary/12 px-2.5 py-0.5 text-xs font-medium text-primary-ink transition-colors hover:bg-primary/20 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
                >
                  {label}
                  <.icon name="hero-x-mark" class="size-3.5" />
                </button>
              </li>
            </ul>
            <span class="text-sm text-base-content/60" role="status" id="content-count">
              {ngettext("%{count} item", "%{count} items", @total)}
            </span>
            <button
              :if={@filtering?}
              type="button"
              phx-click="clear_filters"
              class="btn btn-sm btn-ghost text-base-content/70"
            >
              {gettext("Clear filters")}
            </button>
          </div>
        </div>

        <div
          :if={@items != []}
          class="flex flex-wrap items-center gap-3 rounded-lg border border-base-content/10 bg-base-200/40 px-3 py-2"
        >
          <label class="flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              checked={@all_selected?}
              phx-click="toggle_select_all"
              class="size-4 rounded border-base-content/30 accent-primary"
            />
            {gettext("Select all")}
          </label>
          <span class="text-sm text-base-content/60">
            {if @selected_count > 0,
              do: gettext("%{count} selected", count: @selected_count),
              else: gettext("None selected")}
          </span>
          <div class="ml-auto flex flex-wrap justify-end gap-2">
            <button
              :for={{verb, label} <- bulk_actions(@tier, @editors_can_publish)}
              type="button"
              phx-click="bulk"
              phx-value-action={verb}
              disabled={@selected_count == 0}
              class="btn btn-sm btn-default"
            >
              {label}
            </button>
            <%!-- Content releases (#500). Only offered once a release exists to
                  add to — the button would otherwise be a dead end, and the
                  release list is one click away in the sidebar. --%>
            <button
              :if={@releases != []}
              type="button"
              phx-click="open_release_panel"
              disabled={@selected_count == 0}
              class="btn btn-sm btn-default"
            >
              {gettext("Add to release")}
            </button>
            <button
              :if={@tier == :admin}
              type="button"
              phx-click="bulk"
              phx-value-action="delete"
              disabled={@selected_count == 0}
              class="btn btn-sm btn-danger"
            >
              {gettext("Delete")}
            </button>
          </div>
        </div>

        <form
          :if={@adding_to_release?}
          id="add-to-release"
          phx-submit="add_to_release"
          class="flex flex-wrap items-end gap-3 rounded border border-primary/40 bg-primary/5 px-3 py-2 text-sm"
        >
          <div>
            <label for="add-to-release-target" class="field-label">{gettext("Release")}</label>
            <select id="add-to-release-target" name="release_id" class="field-select w-auto">
              <option :for={release <- @releases} value={release.id}>{release.name}</option>
            </select>
          </div>
          <div>
            <label for="add-to-release-action" class="field-label">{gettext("On go-live")}</label>
            <select id="add-to-release-action" name="release_action" class="field-select w-auto">
              <option value="publish">{gettext("Publish")}</option>
              <option value="unpublish">{gettext("Unpublish")}</option>
            </select>
          </div>
          <div class="ml-auto flex gap-2">
            <button type="submit" class="btn btn-sm btn-primary">
              {gettext("Add %{count} item(s)", count: @selected_count)}
            </button>
            <button type="button" phx-click="cancel_release_panel" class="btn btn-sm btn-default">
              {gettext("Cancel")}
            </button>
          </div>
        </form>

        <div
          :if={@confirming_bulk}
          class={[
            "flex flex-wrap items-center gap-3 rounded border px-3 py-2 text-sm",
            (@confirming_bulk == "delete" && "border-error/40 bg-error/10") ||
              "border-warning/40 bg-warning/10"
          ]}
        >
          <span>{bulk_confirm_prompt(@confirming_bulk, @selected_count)}</span>
          <div class="ml-auto flex flex-wrap justify-end gap-2">
            <button
              type="button"
              phx-click="confirm_bulk"
              class={[
                "btn btn-sm border-transparent hover:opacity-90",
                (@confirming_bulk == "delete" && "bg-error text-error-content") ||
                  "bg-warning text-warning-content"
              ]}
            >
              {bulk_verb_label(@confirming_bulk)}
            </button>
            <button type="button" phx-click="cancel_bulk" class="btn btn-sm btn-default">
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
          <button
            type="button"
            phx-click="clear_filters"
            class="btn btn-sm btn-ghost ml-2 text-base-content/70"
          >
            {gettext("Clear filters")}
          </button>
        </p>

        <ul
          :if={@items != []}
          class="card divide-y divide-base-content/10 overflow-hidden"
        >
          <li
            :for={{kind, record} <- @items}
            id={"#{kind}-#{record.id}"}
            class="flex flex-wrap items-center gap-x-3 gap-y-2 p-3 transition-colors hover:bg-base-200/40"
          >
            <input
              type="checkbox"
              checked={MapSet.member?(@selected, "#{kind}:#{record.id}")}
              phx-click="toggle_select"
              phx-value-key={"#{kind}:#{record.id}"}
              aria-label={gettext("Select %{title}", title: record.title)}
              class="size-4 shrink-0 rounded border border-base-content/30 accent-primary"
            />
            <.content_trigram
              :if={@status_marks == :trigrams}
              published={record.state == :published}
              translated={translated?(@translated, kind, record.slug)}
              scheduled={scheduled?(record)}
              class="text-base-content/50"
            />
            <span class="shrink-0 text-xs uppercase text-base-content/70">{kind}</span>
            <div class="min-w-0 flex-1">
              <.link navigate={edit_path(kind, record.id)} class="font-medium hover:underline">
                {record.title}
              </.link>
              <p class="truncate text-xs text-base-content/70">/{record.slug}</p>
            </div>
            <.state_badge state={record.state} />
            <.content_status_marks
              :if={@status_marks == :words}
              translated={translated?(@translated, kind, record.slug)}
            />
            <%!-- A live record whose working copy has run ahead of its
                  published text (docs/working-copy.md). --%>
            <span
              :if={record.state == :published and record.working_copy_at}
              class="text-xs italic text-base-content/60"
              title={gettext("The working copy has run ahead of the published text.")}
            >
              {gettext("edited since publishing")}
            </span>
            <%!-- The approving admin sees the publish gate but never the
                  claim panel — it lives in the editor, and the approver acts
                  from this list (#856). A click-through to the editor rather
                  than a flat badge: seeing "poor" here and still having to
                  open the editor to find out WHAT matched is the same dead
                  end the flash refusal already is. `nil` (no badge) when
                  compliance is off for this org or the document's locale
                  isn't one the shipped pack can judge — see
                  `compliance_grade/2`. Computed once into `compliance` rather
                  than called twice (`:if` and the badge attr), since it scans
                  the document's text on every call. --%>
            <% compliance = compliance_grade(record, @compliance_settings) %>
            <.link
              :if={compliance}
              navigate={edit_path(kind, record.id)}
              title={gettext("Open the editor's Compliance panel")}
            >
              <.compliance_grade_badge report={compliance} />
            </.link>
            <span
              :if={record.scheduled_at && record.state in [:draft, :in_review]}
              class="flex items-center gap-1 text-xs text-base-content/60"
              title={gettext("Scheduled to publish")}
            >
              <.icon name="hero-clock" class="size-3.5" />
              <span>{gettext("Publishes")}</span>
              <time
                id={"scheduled-#{kind}-#{record.id}"}
                phx-hook="LocalTime"
                datetime={DateTime.to_iso8601(record.scheduled_at)}
              >{Calendar.strftime(record.scheduled_at, "%Y-%m-%d %H:%M")} UTC</time>
            </span>
            <%!-- A date someone without publish rights proposed (#1812). Drawn
                  apart from the real schedule above — dashed, and saying who
                  decides — so a reviewer cannot mistake it for one. --%>
            <span
              :if={record.proposed_publish_at && record.state in [:draft, :in_review]}
              id={"proposed-#{kind}-#{record.id}"}
              class="flex items-center gap-1 rounded border border-dashed border-base-content/40 px-1.5 text-xs text-base-content/70"
              title={gettext("Proposed publish date — an admin confirms it")}
            >
              <.icon name="hero-calendar-days" class="size-3.5" />
              <span>{gettext("Proposed")}</span>
              <time
                id={"proposed-time-#{kind}-#{record.id}"}
                phx-hook="LocalTime"
                datetime={DateTime.to_iso8601(record.proposed_publish_at)}
              >{Calendar.strftime(record.proposed_publish_at, "%Y-%m-%d %H:%M")} UTC</time>
            </span>
            <span
              :if={record.unpublish_at && record.state == :published}
              class="flex items-center gap-1 text-xs text-base-content/60"
              title={gettext("Scheduled to unpublish")}
            >
              <.icon name="hero-clock" class="size-3.5" />
              <span>{gettext("Unpublishes")}</span>
              <time
                id={"unpublish-#{kind}-#{record.id}"}
                phx-hook="LocalTime"
                datetime={DateTime.to_iso8601(record.unpublish_at)}
              >{Calendar.strftime(record.unpublish_at, "%Y-%m-%d %H:%M")} UTC</time>
            </span>
            <div class="flex w-full items-center justify-end gap-2 sm:w-auto">
              <button
                :if={record.state == :draft and @tier == :editor}
                type="button"
                phx-click="submit"
                phx-value-kind={kind}
                phx-value-id={record.id}
                class="btn btn-sm btn-default"
              >
                {gettext("Submit for review")}
              </button>
              <span
                :if={record.state == :in_review and @tier == :editor}
                class="text-xs text-base-content/70"
              >
                {gettext("Awaiting admin approval")}
              </span>
              <button
                :if={
                  not is_nil(record.proposed_publish_at) and record.state in [:draft, :in_review] and
                    (@tier == :admin or (@tier == :editor and @editors_can_publish))
                }
                type="button"
                phx-click="confirm_proposed_date"
                phx-value-kind={kind}
                phx-value-id={record.id}
                class="btn btn-sm btn-default"
              >
                {gettext("Confirm date")}
              </button>
              <button
                :if={
                  record.state in [:draft, :in_review] and
                    (@tier == :admin or (@tier == :editor and @editors_can_publish))
                }
                type="button"
                phx-click="publish"
                phx-value-kind={kind}
                phx-value-id={record.id}
                class="btn btn-sm btn-default"
              >
                {if record.state == :in_review and @tier == :admin,
                  do: gettext("Approve"),
                  else: gettext("Publish")}
              </button>
              <button
                :if={record.state == :in_review and @tier == :admin}
                type="button"
                phx-click="return"
                phx-value-kind={kind}
                phx-value-id={record.id}
                class="btn btn-sm btn-default"
              >
                {gettext("Return")}
              </button>
              <button
                :if={record.state == :published}
                type="button"
                phx-click="unpublish"
                phx-value-kind={kind}
                phx-value-id={record.id}
                class="btn btn-sm btn-default"
              >
                {gettext("Unpublish")}
              </button>
              <button
                :if={record.state == :archived}
                type="button"
                phx-click="unarchive"
                phx-value-kind={kind}
                phx-value-id={record.id}
                class="btn btn-sm btn-default"
              >
                {gettext("Unarchive")}
              </button>
              <button
                type="button"
                phx-click="duplicate"
                phx-value-kind={kind}
                phx-value-id={record.id}
                title={gettext("Copy into a new draft")}
                class="btn btn-sm btn-default"
              >
                {gettext("Duplicate")}
              </button>
              <.link
                navigate={edit_path(kind, record.id) <> "?assign=1"}
                class="btn btn-sm btn-default"
              >
                {gettext("Assign")}
              </.link>
              <.link
                navigate={edit_path(kind, record.id)}
                class="btn btn-sm btn-default"
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
            class="btn btn-default"
          >
            {gettext("Load more")}
          </button>
        </div>
      </div>
    </Layouts.console>
    """
  end

  # The facets behind "More filters" — counted on its button.
  @panel_keys ~w(author category tag locale health from to scheduled)

  # The view on screen, if any: the first built-in or saved view whose filter
  # is exactly the current one.
  defp assign_views(assigns) do
    ctx = %{types: Enum.map(assigns.content_types, &type_value/1), locales: assigns.locales}
    current = Filters.to_params(assigns.filters)

    defaults =
      Enum.map(Filters.default_views(), fn view ->
        Map.put(view, :path, params_path(view_params(view, ctx)))
      end)

    active_default = Enum.find(defaults, &(view_params(&1, ctx) == current))
    active_saved = Enum.find(assigns.saved_views, &(view_params(&1, ctx) == current))

    assigns
    |> assign(:filter_ctx, ctx)
    |> assign(:default_views, defaults)
    |> assign(:active_saved_view, active_saved)
    |> assign(:active_view_id, (active_default || active_saved || %{id: nil}).id)
    |> assign(:chips, chips(assigns))
    |> assign(
      :panel_count,
      assigns.filters |> Map.take(@panel_keys) |> Filters.to_params() |> map_size()
    )
  end

  # `{key, label}` for every active facet but the sort, in a stable order.
  defp chips(assigns) do
    params = Filters.to_params(assigns.filters)

    for key <- ~w(q status type author category tag locale health from to scheduled),
        value = params[key],
        not is_nil(value),
        do: {key, chip_label(key, value, assigns)}
  end

  defp chip_label("q", q, _assigns), do: gettext("Title contains “%{text}”", text: q)

  defp chip_label("status", status, _assigns),
    do: gettext("Status: %{status}", status: Filters.status_label(status))

  defp chip_label("type", type, assigns) do
    label =
      case Enum.find(assigns.content_types, &(type_value(&1) == type)) do
        %{label: label} -> label
        nil -> type
      end

    gettext("Type: %{type}", type: label)
  end

  defp chip_label("author", "me", _assigns), do: gettext("Author: me")

  defp chip_label("author", id, assigns) do
    case List.keyfind(assigns.authors, id, 1) do
      {name, _id} -> gettext("Author: %{name}", name: name)
      nil -> gettext("Author: a former member")
    end
  end

  defp chip_label("category", id, assigns) do
    case Enum.find(assigns.categories, &(&1.id == id)) do
      %{name: name} -> gettext("Category: %{name}", name: name)
      nil -> gettext("Category: a deleted category")
    end
  end

  defp chip_label("tag", id, assigns) do
    case Enum.find(assigns.tags, &(&1.id == id)) do
      %{name: name} -> gettext("Tag: %{name}", name: name)
      nil -> gettext("Tag: a deleted tag")
    end
  end

  defp chip_label("locale", locale, _assigns),
    do: gettext("Language: %{locale}", locale: locale)

  defp chip_label("health", health, _assigns), do: Filters.health_label(health)
  defp chip_label("from", date, _assigns), do: gettext("Updated from %{date}", date: date)
  defp chip_label("to", date, _assigns), do: gettext("Updated until %{date}", date: date)
  defp chip_label("scheduled", _value, _assigns), do: gettext("Scheduled to publish")

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
