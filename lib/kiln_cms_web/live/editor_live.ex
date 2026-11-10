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

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.ListFields
  alias KilnCMS.Compliance
  alias KilnCMS.Compliance.Settings
  alias KilnCMS.I18n
  alias KilnCMSWeb.ContentEditor.Shared
  alias KilnCMSWeb.ContentTrash
  alias KilnCMSWeb.EditorLive.FieldCells
  alias KilnCMSWeb.EditorLive.Filters
  alias KilnCMSWeb.EditorLive.ListScope

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
     # The Export disclosure (#2293): the matching count is read when it opens
     # (`:unknown` until then), never with the list; the private-fields
     # opt-in rewrites the download links.
     |> assign(:export_count, :unknown)
     |> assign(:export_private?, false)
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
     # The custom-field columns of the one type being listed (`assign_columns/1`).
     |> assign(:column_type, nil)
     |> assign(:column_options, [])
     |> assign(:column_names, [])
     |> assign(:columns, [])
     |> assign(:column_labels, FieldCells.empty())
     # Custom-field conditions (#2293): the exact count is replaced by "N+"
     # past `@count_cap`, and each saved view's params are re-read against
     # today's field definitions (`assign_saved_view_params/1`).
     |> assign(:total_capped?, false)
     |> assign(:saved_view_params, %{})
     |> assign(:stale_views, MapSet.new())
     # The add-a-condition form's draft: the field and op picked and the value
     # typed so far. Held server-side so the value control can follow the field.
     |> assign(:ff_draft, %{field: nil, op: nil, value: ""})
     |> assign(:field_preload, nil)
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
    |> assign_saved_view_params()
  end

  # Each saved view's params as the list would apply them today, and which
  # views name a field condition that no longer applies (a field deleted or
  # made private since the view was saved). A view with a `cf` or a field sort
  # needs its type's field definitions, read once per such type, so the render never
  # touches the database. Before `handle_params` has loaded the types there is
  # nothing to check against.
  defp assign_saved_view_params(%{assigns: %{content_types: _}} = socket) do
    ctx = filter_ctx(socket)

    cache =
      for view <- socket.assigns.saved_views,
          Filters.needs_fields?(view.params),
          type = Filters.field_type_in_play(view.params, ctx),
          uniq: true,
          into: %{},
          do: {type, field_definitions(socket, type)}

    ctx = Map.put(ctx, :fields, &Map.get(cache, &1, []))

    params = Map.new(socket.assigns.saved_views, &{&1.id, view_params(&1, ctx)})

    stale =
      for view <- socket.assigns.saved_views,
          Filters.stale?(view.params, ctx),
          into: MapSet.new(),
          do: view.id

    socket |> assign(:saved_view_params, params) |> assign(:stale_views, stale)
  end

  defp assign_saved_view_params(socket), do: socket

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
    # The row's byline, named from the `@authors` roster already loaded.
    :author_id,
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
    # The export count describes the rows under the previous filter.
    socket = socket |> assign_columns() |> assign(:export_count, :unknown)

    case guard_field_query(socket, fn -> {fetch_page(socket, %{}), count_items(socket)} end) do
      {:ok, {{items, cursors}, {total, capped?}}} ->
        socket
        |> assign(:items, items)
        |> assign(:trashable, trashable(socket, items))
        |> assign_column_labels(items, FieldCells.empty())
        |> assign(:cursors, cursors)
        |> assign(:more?, more?(cursors))
        |> assign(:total, total)
        |> assign(:total_capped?, capped?)
        |> assign(:compliance_settings, compliance_settings(socket, items))
        |> assign_translated()

      :field_query_failed ->
        # The patch below reloads the list once, without the field query; this
        # render only needs assigns that make sense until it lands.
        socket |> drop_field_query() |> assign_empty_page()
    end
  end

  defp assign_empty_page(socket) do
    socket
    |> assign(:items, [])
    |> assign(:trashable, MapSet.new())
    |> assign(:column_labels, FieldCells.empty())
    |> assign(:cursors, %{})
    |> assign(:more?, false)
    |> assign(:total, 0)
    |> assign(:total_capped?, false)
    |> assign(:compliance_settings, nil)
    |> assign(:translated, nil)
  end

  # A field-filtered read can fail after its conditions were validated: the
  # field was deleted, made private or retyped in between (the list holds
  # the conditions across "Load more", saved views and other tabs). That is
  # a real boundary, so it is the one place the read's error is caught; any
  # other read is not touched.
  defp guard_field_query(socket, read) do
    if Filters.field_query?(socket.assigns.filters) do
      try do
        {:ok, read.()}
      rescue
        error in [Ash.Error.Invalid] ->
          # Only the preparation's refusal of a condition or sort is "the field
          # went away"; anything else is a real failure and keeps raising.
          if field_query_error?(error),
            do: :field_query_failed,
            else: reraise(error, __STACKTRACE__)
      end
    else
      {:ok, read.()}
    end
  end

  @doc false
  # True when every error is `CustomFieldQuery` refusing a `custom_filter` or
  # `custom_sort` (unknown field, bad value, unsortable field).
  def field_query_error?(%Ash.Error.Invalid{errors: [_ | _] = errors}) do
    Enum.all?(errors, fn
      %Ash.Error.Query.InvalidArgument{field: field} -> field in [:custom_filter, :custom_sort]
      _other -> false
    end)
  end

  def field_query_error?(_error), do: false

  # Back to the list without its field conditions and field sort, said out
  # loud, with the URL brought in line.
  defp drop_field_query(socket) do
    filters = Filters.clear_field_query(socket.assigns.filters)

    socket
    |> assign(:filters, filters)
    |> put_flash(
      :error,
      gettext("The field filter or sort could no longer be applied, so it was cleared.")
    )
    |> push_patch(to: list_path(filters), replace: true)
  end

  # Who the Export controller serves: editors and admins, like the list.
  defp exporter?(socket), do: socket.assigns.tier in [:editor, :admin]

  # What the Export disclosure and the bulk link need, worked out per render:
  # the download links under the current filters (private columns only when
  # the opt-in is offered and ticked), and the selected rows' ids.
  defp assign_export(assigns) do
    filters = assigns.filters
    private_option? = Enum.any?(assigns.column_options, &(Map.get(&1, :private) == true))
    private? = private_option? and assigns.export_private?

    ids =
      for key <- assigns.selected,
          [_kind, id] <- [String.split(key, ":", parts: 2)],
          do: id

    ids = Enum.sort(ids)
    too_many? = length(ids) > ListScope.max_ids()

    assigns
    |> assign(:export?, assigns.tier in [:editor, :admin])
    |> assign(:export_private_option?, private_option?)
    |> assign(:export_private_on?, private?)
    |> assign(:export_csv_path, ListScope.export_path(:csv, filters, private?: private?))
    |> assign(:export_json_path, ListScope.export_path(:json, filters, private?: private?))
    |> assign(:export_ids_too_many?, too_many?)
    |> assign(
      :export_selected_path,
      if(ids == [] or too_many?,
        do: nil,
        else: ListScope.export_path(:csv, filters, ids: ids, private?: private?)
      )
    )
  end

  defp export_cap_label, do: group_thousands(ListScope.export_cap())

  defp group_thousands(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  # The rows the actor may move to the trash (#2137), as selection keys
  # ("kind:id"): the destroy policy asked once per row per load, not per
  # render. Only decides whether the row menu OFFERS the item; the
  # `move_to_trash` handler asks again.
  defp trashable(socket, items) do
    %{actor: actor, current_org: org} = socket.assigns

    for {kind, record} <- items,
        ContentTypes.can_destroy?(kind, record, actor, tenant: org),
        into: MapSet.new(),
        do: "#{kind}:#{record.id}"
  end

  # The overview strip's counts: how much of the site's content sits in each
  # stage, whatever the list below is filtered to. One count per type per
  # stage, so it is NOT run on every filter change — only on the first
  # navigation and after a write from this page (`refresh/1`). Another tab's
  # write shows up on the next visit, as the facet choices do.
  @overview [
    {"draft", %{"status" => "draft"}},
    {"in_review", %{"status" => "in_review"}},
    {"scheduled", %{"scheduled" => "1"}},
    {"published", %{"status" => "published"}}
  ]

  defp load_overview(socket) do
    %{actor: actor, current_org: org, content_types: types} = socket.assigns

    overview =
      Map.new(@overview, fn {key, params} ->
        query = params |> Filters.parse(filter_ctx(socket)) |> Filters.query_filters(actor.id)

        count =
          types
          |> Enum.map(&ContentTypes.count!(&1, actor: actor, tenant: org, query: query))
          |> Enum.sum()

        {key, count}
      end)

    assign(socket, :overview, overview)
  end

  defp ensure_overview(%{assigns: %{overview: %{}}} = socket), do: socket
  defp ensure_overview(socket), do: load_overview(socket)

  # After a write from this page: the list and the overview both moved.
  defp refresh(socket), do: socket |> load_items() |> load_overview()

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
    %{actor: actor, current_org: org, filters: filters, columns: columns} = socket.assigns
    query = page_query(filters, actor, columns)
    arguments = Filters.field_arguments(filters, socket.assigns.column_options)

    streams =
      for ct <- filtered_types(socket), Map.get(cursors, type_value(ct)) != :done do
        cursor = Map.get(cursors, type_value(ct))
        page_opts = if cursor, do: [limit: @page_size, after: cursor], else: [limit: @page_size]

        # Dispatch on the descriptor itself so a type archived between listing
        # and dispatch can't turn into a registry-lookup miss. Scoped to the
        # current site's org (epic #336) so the index only lists this org's content.
        page =
          ContentTypes.list!(ct,
            actor: actor,
            tenant: org,
            query: query,
            page: page_opts,
            arguments: arguments
          )

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

  # The most a field-filtered count reports exactly. A custom-field condition
  # is a scan of the site's rows of that type, and the figure is only context,
  # so the count stops one row past the cap (`Ash.count/2` counts at most the
  # query's `limit`) and the list says "1000+".
  @count_cap 1000

  # How many rows the filter matches across the types it reads — one count per
  # type, through the same filters as the page (#1593) — and whether it
  # stopped at `@count_cap`. Only the conditions narrow a count; a field sort
  # does not, so it is left out of the arguments.
  defp count_items(socket) do
    %{actor: actor, current_org: org, filters: filters} = socket.assigns
    query = Filters.query_filters(filters, actor.id)

    conditions = Filters.conditions(filters)

    arguments =
      KilnCMS.CMS.ListFieldQuery.arguments(conditions, nil, socket.assigns.column_options)

    query = if conditions == [], do: query, else: query ++ [limit: @count_cap + 1]

    total =
      socket
      |> filtered_types()
      |> Enum.map(
        &ContentTypes.count!(&1, actor: actor, tenant: org, query: query, arguments: arguments)
      )
      |> Enum.sum()

    {min(total, @count_cap), conditions != [] and total > @count_cap}
  end

  defp page_query(filters, actor, columns) do
    # Widened for `in_review` (#856): the other filters never render the
    # compliance badge, so they keep the narrower select the comment on
    # `@list_fields` explains the cost of. Independently, `:custom_fields` is
    # pulled only when the list shows field columns, which cost the same.
    select =
      if(filters["status"] == "in_review",
        do: @list_fields ++ @compliance_fields,
        else: @list_fields
      )

    select = if columns == [], do: select, else: select ++ [:custom_fields]

    Filters.query_filters(filters, actor.id) ++ [select: select, sort: Filters.sort(filters)]
  end

  # The one content type whose fields the list can show as columns (see
  # `ListScope.column_type/2`).
  defp column_type(%{assigns: %{type: type, content_types: types}}),
    do: ListScope.column_type(types, type)

  # The custom fields of the content type `type` (a type value) that this
  # actor may list, filter and sort by, private ones included
  # (`ListScope.field_definitions/4`).
  defp field_definitions(socket, type) do
    %{actor: actor, current_org: org, content_types: types} = socket.assigns
    ListScope.field_definitions(types, type, actor, org)
  end

  # What the column picker offers and what the strip shows, for the current
  # type. The remembered names are re-read against today's field definitions,
  # so a deleted or since-private field simply drops out.
  defp assign_columns(socket) do
    previous = socket.assigns.column_type && type_value(socket.assigns.column_type)
    socket = socket |> pick_columns() |> assign(:field_preload, nil)
    current = socket.assigns.column_type && type_value(socket.assigns.column_type)

    # A half-typed condition belongs to the type it was typed for.
    if previous == current,
      do: socket,
      else: assign(socket, :ff_draft, %{field: nil, op: nil, value: ""})
  end

  defp pick_columns(socket) do
    %{current_user: user, current_org: org} = socket.assigns

    case column_type(socket) do
      nil ->
        socket
        |> assign(:column_type, nil)
        |> assign(:column_options, [])
        |> assign(:column_names, [])
        |> assign(:columns, [])

      descriptor ->
        value = type_value(descriptor)

        options =
          case socket.assigns[:field_preload] do
            {^value, definitions} -> definitions
            _ -> field_definitions(socket, value)
          end

        names = ListScope.column_names(user, org, descriptor, options)

        socket
        |> assign(:column_type, descriptor)
        |> assign(:column_options, options)
        |> assign(:column_names, names)
        |> assign(:columns, ListFields.resolve_columns(names, options))
    end
  end

  # The labels the strip's cells need for `items`, one lookup per page of rows
  # (see `FieldCells`). Recomputed wherever rows are fetched.
  defp assign_column_labels(socket, items, prior) do
    %{actor: actor, current_org: org, columns: columns} = socket.assigns
    assign(socket, :column_labels, FieldCells.labels(prior, items, columns, actor, org))
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
  defp editable_types(org_id, actor), do: ListScope.types(actor, org_id)

  # The types this page pulls rows from: every editable type, or just the one
  # the `type` filter names. Filtering here rather than after the merge keeps
  # the DB from reading rows we'd only throw away, and keeps the per-type
  # `@page_size` window (so "Load more" still reaches every match).
  defp filtered_types(%{assigns: %{type: type, content_types: types}}),
    do: ListScope.filtered_types(types, type)

  # A descriptor's filter/URL value (see `ListScope.type_value/1`).
  defp type_value(descriptor), do: ListScope.type_value(descriptor)

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

  # The Columns picker (the form's whole checked set arrives each time). Only
  # the type being listed is accepted, and every name is checked against what
  # the picker offers: a forged event names nothing it could not click. The
  # write re-validates (`Accounts.set_content_list_columns/5`) and is the
  # user's own preference, keyed by the current site, never by a param.
  def handle_event("set_columns", %{"type" => type} = params, socket) when is_binary(type) do
    names = Map.get(params, "columns", [])

    with true <- is_list(names) and Enum.all?(names, &is_binary/1),
         %{} = descriptor <- column_type(socket),
         true <- type_value(descriptor) == type,
         names = names |> Enum.reject(&(&1 == "")) |> Enum.uniq(),
         true <- valid_columns?(socket, names) do
      {:noreply, save_columns(socket, type, names)}
    else
      _ -> {:noreply, socket}
    end
  end

  # Custom-field conditions (#2293). The condition is re-validated here
  # against the fields of the one type in play (`column_options`, empty when
  # several types are listed), as `Filters.parse/2` will again on the patch: a
  # forged field, op or value changes nothing but a flash. A fifth condition
  # (or one that would not fit a saved view) is refused out loud.
  def handle_event("add_field_filter", %{"field" => field, "op" => op, "value" => value}, socket)
      when is_binary(field) and is_binary(op) and is_binary(value) do
    %{filters: filters, column_options: options} = socket.assigns

    case Filters.add_condition(filters, options, field, op, value) do
      {:ok, filters} ->
        {:noreply,
         socket
         |> assign(:ff_draft, %{field: field, op: op, value: ""})
         |> patch_filters(%{"cf" => filters["cf"]})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, field_filter_error(reason))}
    end
  end

  def handle_event("add_field_filter", _params, socket), do: {:noreply, socket}

  # The add-a-condition form changing: the value control follows the field and
  # op. The draft is clamped to what the type offers, so a forged field or op
  # falls back to the first of each; the typed value is kept unless the field
  # changed (a value for one field means nothing for another).
  # Nothing to draw on a list that is not one type with fields: a stale or
  # forged event is a no-op.
  def handle_event("field_filter_draft", _params, %{assigns: %{column_options: []}} = socket),
    do: {:noreply, socket}

  def handle_event("field_filter_draft", params, socket) when is_map(params) do
    options = socket.assigns.column_options
    previous = socket.assigns.ff_draft
    field = draft_field(options, params["field"])
    op = draft_op(field, params["op"])
    value = if is_binary(params["value"]), do: params["value"], else: ""
    value = if field.name == previous.field, do: value, else: ""

    {:noreply, assign(socket, :ff_draft, %{field: field.name, op: op, value: value})}
  end

  def handle_event("remove_field_filter", %{"field" => field, "op" => op}, socket)
      when is_binary(field) and is_binary(op) do
    filters = Filters.remove_condition(socket.assigns.filters, field, op)
    {:noreply, patch_filters(socket, %{"cf" => filters["cf"]})}
  end

  # A forged or stale payload (missing keys, wrong shapes) changes nothing.
  def handle_event("remove_field_filter", _params, socket), do: {:noreply, socket}

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

  # Opening the Export disclosure reads the bounded count of matching rows
  # (`ListScope.export_count/6`) once per filter state; closing it, or opening
  # it again, costs nothing. The download itself is re-checked by the
  # controller, which is the gate; this only labels the links.
  def handle_event("export_count", params, socket) when is_map(params) do
    if exporter?(socket) and socket.assigns.export_count == :unknown do
      %{filters: filters, actor: actor, current_org: org} = socket.assigns

      counted =
        guard_field_query(socket, fn ->
          ListScope.export_count(
            filtered_types(socket),
            filters,
            actor,
            org,
            socket.assigns.column_options
          )
        end)

      case counted do
        {:ok, result} -> {:noreply, assign(socket, :export_count, result)}
        :field_query_failed -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_export_private", params, socket) when is_map(params) do
    if exporter?(socket),
      do: {:noreply, update(socket, :export_private?, &(not &1))},
      else: {:noreply, socket}
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
      # No one record here: the selection can span types, so the sentence is
      # decided from the tier and the publish switch alone.
      context = [actor: socket.assigns.actor, org: socket.assigns.current_org]
      {:noreply, put_flash(socket, :error, KilnCMSWeb.WorkflowMessages.forbidden(verb, context))}
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

    {ok, skipped, needs_severity} =
      Enum.reduce(socket.assigns.selected, {0, 0, 0}, fn key, counts ->
        [kind, id] = String.split(key, ":", parts: 2)

        result =
          if verb == "delete",
            do: destroy(kind, id, actor, org),
            else: do_transition(kind, verb, get!(kind, id, actor, org), actor, org)

        tally_bulk(result, counts)
      end)

    flash = bulk_flash(verb, ok, skipped + needs_severity)

    flash =
      if needs_severity > 0,
        do:
          flash <>
            " " <>
            gettext(
              "%{count} of them touch a safety field — open each in the editor to publish and say how much the change matters.",
              count: needs_severity
            ),
        else: flash

    {:noreply,
     socket
     |> refresh()
     |> assign(:selected, MapSet.new())
     |> assign(:confirming_bulk, nil)
     |> put_flash(:info, flash)}
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
       |> refresh()
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

  # "Move to trash" on one row (#2137). `kind`/`id` come off the clicked row,
  # so they are client input: the type is resolved without raising, the record
  # is read under this site's org (another org's id is simply not found), and
  # the destroy policy is asked again before the write — the menu item is drawn
  # only for rows it allows, and a forged event gets the same answer.
  def handle_event("move_to_trash", %{"kind" => kind, "id" => id}, socket)
      when is_binary(kind) and is_binary(id) do
    %{actor: actor, current_org: org} = socket.assigns

    with %{} <- ContentTypes.get(kind, org),
         {:ok, record} <- ContentTypes.get_record(kind, id, actor: actor, tenant: org) do
      {:noreply, move_to_trash(socket, kind, record)}
    else
      _missing -> {:noreply, put_flash(socket, :error, ContentTrash.not_found())}
    end
  end

  def handle_event("move_to_trash", _params, socket), do: {:noreply, socket}

  def handle_event("load_more", _params, socket) do
    if socket.assigns.items == [],
      do: {:noreply, assign(socket, :more?, false)},
      else: {:noreply, load_next_page(socket)}
  end

  defp load_next_page(socket) do
    case guard_field_query(socket, fn -> fetch_page(socket, socket.assigns.cursors) end) do
      {:ok, {page, cursors}} -> append_page(socket, page, cursors)
      :field_query_failed -> drop_field_query(socket)
    end
  end

  defp append_page(socket, page, cursors) do
    socket
    |> assign(:items, socket.assigns.items ++ page)
    |> assign(:trashable, MapSet.union(socket.assigns.trashable, trashable(socket, page)))
    |> assign(:cursors, cursors)
    |> assign(:more?, more?(cursors))
    |> assign_column_labels(page, socket.assigns.column_labels)
    |> assign_translated()
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
    {socket, ctx} = preload_fields(socket, params)
    filters = Filters.parse(params, ctx)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:status, filters["status"])
     |> assign(:type, filters["type"])
     |> assign(:query, filters["q"])
     |> assign(:saving_view?, false)
     |> assign(:renaming_view, nil)
     |> assign(:confirming_view_delete, nil)
     |> assign_saved_view_params()
     |> flash_stale_view()
     |> load_releases()
     |> load_items()
     |> ensure_overview()}
  end

  # A `cf` or field sort needs the type's readable fields to validate; the
  # column strip needs the same list a moment later (`assign_columns/1`). Read
  # it once here, only when the URL asks, and hand it on.
  defp preload_fields(socket, params) do
    ctx = filter_ctx(socket)
    type = Filters.field_type_in_play(params, ctx)

    if type && Filters.needs_fields?(params) do
      definitions = field_definitions(socket, type)

      {assign(socket, :field_preload, {type, definitions}),
       Map.put(ctx, :fields, fn
         ^type -> definitions
         other -> field_definitions(socket, other)
       end)}
    else
      {assign(socket, :field_preload, nil), ctx}
    end
  end

  # `:fields` reads a type's field definitions only when a `cf` or field sort
  # asks (`Filters.parse/2`), so a plain list costs no extra read.
  defp filter_ctx(socket) do
    ListScope.filter_ctx(
      socket.assigns.content_types,
      socket.assigns.locales,
      socket.assigns.actor,
      socket.assigns.current_org
    )
  end

  # The add-a-condition form as drawn: the draft clamped to today's fields
  # (nil when the list is not one type with fields), with its value control.
  defp field_filter_form(%{column_options: []}), do: nil

  defp field_filter_form(%{column_options: options, ff_draft: draft}) do
    field = draft_field(options, draft.field)
    op = draft_op(field, draft.op)
    value = if field.name == draft.field, do: draft.value, else: ""

    %{
      field: field,
      op: op,
      value: value,
      ops: KilnCMS.CMS.ListFieldQuery.ops(field.field_type),
      control: value_control(field, op)
    }
  end

  defp draft_field([first | _] = options, name),
    do: Enum.find(options, first, &(&1.name == name))

  defp draft_op(field, op) do
    ops = KilnCMS.CMS.ListFieldQuery.ops(field.field_type)
    if op in ops, do: op, else: List.first(ops)
  end

  defp field_filter_error(:limit),
    do:
      gettext("A list holds at most %{count} field filters, and they must fit a saved view.",
        count: Filters.max_conditions()
      )

  defp field_filter_error(:invalid), do: gettext("That field filter is not valid here.")

  # Opening a saved view whose field conditions no longer apply is said out
  # loud: the list narrows less than the view was saved to, never silently.
  defp flash_stale_view(socket) do
    %{filters: filters, saved_views: views, saved_view_params: params, stale_views: stale} =
      socket.assigns

    current = Filters.to_params(filters)

    case Enum.find(views, &(&1.id in stale and Map.get(params, &1.id) == current)) do
      nil ->
        socket

      view ->
        put_flash(
          socket,
          :info,
          gettext(
            "The view “%{name}” named a field that no longer applies, so that condition was left out.",
            name: view.name
          )
        )
    end
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

  defp valid_columns?(socket, names) do
    known = MapSet.new(socket.assigns.column_options, & &1.name)
    length(names) <= ListFields.max_stored() and Enum.all?(names, &MapSet.member?(known, &1))
  end

  defp save_columns(socket, type, names) do
    %{current_user: user, current_org: org} = socket.assigns

    case Accounts.set_content_list_columns(user, Accounts.org_id(org), type, names, actor: user) do
      {:ok, updated} ->
        socket
        |> assign(:current_user, %{user | content_list_columns: updated.content_list_columns})
        |> load_items()

      {:error, _error} ->
        put_flash(socket, :error, gettext("Your choice could not be saved."))
    end
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
      |> Filters.merge(changes)
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
        |> refresh()
        |> put_flash(:info, KilnCMSWeb.WorkflowMessages.success(verb, record.state))

      {:error, error} ->
        if severity_required?(error) do
          put_flash(
            socket,
            :error,
            gettext(
              "This change touches a safety field. Open it in the editor to publish and say how much it matters."
            )
          )
        else
          message =
            KilnCMSWeb.WorkflowMessages.error(verb, error, refusal_context(socket, record))

          put_flash(socket, :error, message)
        end
    end
  end

  # All dispatch to the current site's org (epic #336): reads/writes are
  # tenant-scoped so an editor on one site's subdomain can only see and act on
  # that site's content. `org_id` is writable? false, so the tenant is the only
  # way to set/scope it.
  defp get!(kind, id, actor, org),
    do: ContentTypes.get_record!(kind, id, actor: actor, tenant: org)

  # A publish from the list has no severity picker, so the action is told to
  # refuse (rather than default to :notable) a publish that touches a site
  # safety field; the editor has the panel that asks.
  defp do_transition(kind, "publish", record, actor, org) do
    ContentTypes.transition(kind, "publish", record,
      actor: actor,
      tenant: org,
      context: %{require_change_severity: true}
    )
  end

  defp do_transition(kind, verb, record, actor, org),
    do: ContentTypes.transition(kind, verb, record, actor: actor, tenant: org)

  defp severity_required?(error) when is_exception(error) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.any?(&(Map.get(&1, :field) == :change_severity))
  end

  defp severity_required?(_error), do: false

  # Hard delete (soft via archival). Admin-only; the policy rejects others, in
  # which case the item is counted as skipped.
  defp destroy(kind, id, actor, org),
    do: ContentTypes.destroy(kind, get!(kind, id, actor, org), actor: actor, tenant: org)

  defp move_to_trash(socket, kind, record) do
    %{actor: actor, current_org: org} = socket.assigns

    if ContentTypes.can_destroy?(kind, record, actor, tenant: org) do
      case ContentTrash.trash(kind, record, actor, org) do
        :ok ->
          socket
          |> refresh()
          |> assign(:selected, MapSet.delete(socket.assigns.selected, "#{kind}:#{record.id}"))
          |> put_flash(:info, ContentTrash.moved(record))

        {:error, error} ->
          put_flash(
            socket,
            :error,
            KilnCMSWeb.WorkflowMessages.error("trash", error, refusal_context(socket, record))
          )
      end
    else
      put_flash(
        socket,
        :error,
        KilnCMSWeb.WorkflowMessages.forbidden("trash", refusal_context(socket, record))
      )
    end
  end

  # Who was refused, where, on what — `KilnCMSWeb.WorkflowMessages` decides the
  # sentence from the actor's tier and scope on this site.
  defp refusal_context(socket, record),
    do: [actor: socket.assigns.actor, org: socket.assigns.current_org, resource: record]

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

  # Unpublish and Archive take the publish permission (#2134), so someone who
  # may not publish is offered neither; Unarchive lands on draft and stays.
  defp bulk_actions(_tier, _editors_can_publish) do
    [
      {"submit", gettext("Submit for review")},
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
      |> assign_export()
      |> assign(:compiled_types, Enum.filter(assigns.content_types, &(&1.source == :compiled)))
      |> assign(:dynamic_types, Enum.filter(assigns.content_types, &(&1.source == :dynamic)))
      |> assign(:type_labels, Map.new(assigns.content_types, &{type_value(&1), &1.label}))
      |> assign(:author_names, Map.new(assigns.authors, fn {label, id} -> {id, label} end))
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
              A disclosure (#2145): a real <button> carrying aria-expanded, so
              assistive tech hears a button and its state, which a styled
              <summary> did not reliably give. The click opens it client-side;
              `data-autoclose` hands outside clicks and Escape to app.js. Both
              sides write `hidden` and `aria-expanded`, so the patch that every
              filter change sends leaves them alone and the menu stays open. --%>
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
        <div
          :if={length(@content_types) > @max_inline_new_buttons}
          id="content-new-menu"
          class="relative"
          data-autoclose
        >
          <button
            type="button"
            id="content-new-menu-toggle"
            class="btn btn-primary btn-sm group"
            aria-expanded="false"
            aria-controls="content-new-menu-list"
            phx-mounted={JS.ignore_attributes(["aria-expanded"])}
            phx-click={
              JS.toggle_attribute({"aria-expanded", "true", "false"})
              |> JS.toggle_attribute({"hidden", "hidden"}, to: "#content-new-menu-list")
            }
          >
            <.icon name="hero-plus" class="size-4" />
            {gettext("New")}
            <.icon
              name="hero-chevron-down"
              class="size-3.5 transition-transform group-aria-expanded:rotate-180"
            />
          </button>
          <div
            id="content-new-menu-list"
            hidden
            phx-mounted={JS.ignore_attributes(["hidden"])}
            class="absolute right-0 z-30 mt-2 flex max-h-96 w-56 flex-col gap-0.5 overflow-y-auto rounded-lg border border-base-content/10 bg-base-100 p-1.5 shadow-lg"
          >
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
        </div>
      </:actions>

      <div class="space-y-6">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">{gettext("Content")}</h1>
          <p class="mt-1 text-sm text-base-content/60">
            {gettext("Pages, posts and custom types across your site.")}
          </p>
        </div>

        <%!-- Where the site's content stands, whatever the list is filtered
              to: each count is a link to the list it counts. --%>
        <nav
          :if={Enum.any?(@overview, fn {_key, count} -> count > 0 end)}
          id="content-overview"
          aria-label={gettext("Content by stage")}
        >
          <ul class="grid grid-cols-2 gap-3 lg:grid-cols-4">
            <li :for={stat <- @stats}>
              <.link
                patch={stat.path}
                id={"overview-#{stat.key}"}
                aria-current={stat.current? && "page"}
                class="stat"
              >
                <span class={[
                  "flex size-10 shrink-0 items-center justify-center rounded-full",
                  stat.tone
                ]}>
                  <.icon name={stat.icon} class="size-5" />
                </span>
                <span class="min-w-0">
                  <span class="stat-value block">{stat.count}</span>
                  <span class="stat-label block truncate">{stat.label}</span>
                </span>
              </.link>
            </li>
          </ul>
        </nav>

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
                class="pill"
              >
                {view.name}
              </.link>
            </li>
            <li :for={view <- @saved_views}>
              <.link
                patch={params_path(Map.get(@saved_view_params, view.id, %{}))}
                id={"view-#{view.id}"}
                aria-current={view.id == @active_view_id && "page"}
                class="pill"
              >
                <.icon
                  :if={view.shared}
                  name="hero-user-group"
                  class="size-3.5"
                />
                <span :if={view.shared} class="sr-only">{gettext("Shared:")}</span>
                {view.name}
                <span
                  :if={view.id in @stale_views}
                  id={"view-stale-#{view.id}"}
                  title={gettext("This view names a field that no longer applies.")}
                >
                  <.icon name="hero-exclamation-triangle" class="size-3.5 text-warning-ink" />
                  <span class="sr-only">
                    {gettext("This view names a field that no longer applies.")}
                  </span>
                </span>
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
              <input type="checkbox" name="shared" value="true" class="field-checkbox size-4" />
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
            class="flex flex-wrap items-center gap-3 rounded-lg border border-error/40 bg-error/10 px-3 py-2 text-sm"
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
                class="btn btn-sm btn-danger-fill"
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

            <form
              id="content-search"
              phx-change="search"
              phx-submit="search"
              class="relative min-w-48 max-w-xs flex-1"
            >
              <label for="content-search-input" class="sr-only">{gettext("Search by title")}</label>
              <.icon
                name="hero-magnifying-glass"
                class="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-base-content/45"
              />
              <input
                id="content-search-input"
                type="search"
                name="q"
                value={@query}
                placeholder={gettext("Search by title")}
                aria-label={gettext("Search by title")}
                phx-debounce="200"
                autocomplete="off"
                class="field-input pl-9"
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
                <%!-- One group per single-type list: the fields the list can
                      order by, each ascending and descending. The current
                      field sort stays selected, so submitting the form does
                      not reset it. --%>
                <optgroup
                  :if={sortable_options(@column_options) != []}
                  id="field-sort"
                  label={gettext("Field")}
                >
                  <%= for option <- sortable_options(@column_options), dir <- [:asc, :desc] do %>
                    <option
                      value={Filters.field_sort_value(option.name, dir)}
                      selected={Filters.field_sort_value(option.name, dir) == @filters["sort"]}
                    >
                      {field_sort_label(option, dir)}
                    </option>
                  <% end %>
                </optgroup>
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
                  <label for="content-reviewed-filter" class="field-label">
                    {gettext("Review history")}
                  </label>
                  <select id="content-reviewed-filter" name="reviewed" class="field-select">
                    <option value="">{gettext("Any")}</option>
                    <option
                      :for={reviewed <- Filters.reviewed()}
                      value={reviewed}
                      selected={@filters["reviewed"] == reviewed}
                    >
                      {Filters.reviewed_label(reviewed)}
                    </option>
                  </select>
                </div>
                <div>
                  <label for="content-consent-filter" class="field-label">
                    {gettext("Missing consent")}
                  </label>
                  <select id="content-consent-filter" name="consent_missing" class="field-select">
                    <option value="">{gettext("Any")}</option>
                    <option
                      :for={kind <- Filters.consent_kinds()}
                      value={kind}
                      selected={@filters["consent_missing"] == kind}
                    >
                      {Filters.consent_kind_label(kind)}
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
                    class="field-checkbox size-4"
                  />
                  {gettext("Only scheduled to publish")}
                </label>
                <div
                  :if={@ff}
                  id="field-filters"
                  class="space-y-2 sm:col-span-2 lg:col-span-4"
                >
                  <%!-- The form element sits outside `#content-filter` (forms do
                        not nest); these controls join it by `form=`. --%>
                  <p class="field-label">{gettext("Field conditions")}</p>
                  <div class="flex flex-wrap items-end gap-3">
                    <div class="min-w-40">
                      <.input
                        type="select"
                        id="field-filter-field"
                        name="field"
                        form="field-filter-form"
                        label={gettext("Field")}
                        value={@ff.field.name}
                        options={for option <- @column_options, do: {field_name(option), option.name}}
                      />
                    </div>
                    <div class="min-w-36">
                      <.input
                        type="select"
                        id="field-filter-op"
                        name="op"
                        form="field-filter-form"
                        label={gettext("Condition")}
                        value={@ff.op}
                        options={
                          for op <- @ff.ops, do: {op_option_label(@ff.field.field_type, op), op}
                        }
                      />
                    </div>
                    <% {control_type, control_attrs, control_options} = @ff.control %>
                    <div class="min-w-40">
                      <.input
                        :if={control_options}
                        type="select"
                        id="field-filter-value"
                        name="value"
                        form="field-filter-form"
                        label={gettext("Value")}
                        value={@ff.value}
                        options={control_options}
                      />
                      <.input
                        :if={!control_options}
                        type={control_type}
                        id="field-filter-value"
                        name="value"
                        form="field-filter-form"
                        label={gettext("Value")}
                        value={@ff.value}
                        maxlength={KilnCMS.CMS.ListFieldQuery.max_value_length()}
                        required
                        {control_attrs}
                      />
                    </div>
                    <button
                      type="submit"
                      form="field-filter-form"
                      id="field-filter-add"
                      class="btn btn-default mb-2"
                    >
                      <.icon name="hero-plus" class="size-4" />
                      {gettext("Add condition")}
                    </button>
                  </div>
                </div>
                <p
                  :if={@column_options == [] and is_nil(@column_type) and length(@content_types) > 1}
                  id="field-filters-hint"
                  class="text-sm text-base-content/60 sm:col-span-2 lg:col-span-4"
                >
                  {gettext("Choose a content type to filter by its fields.")}
                </p>
              </fieldset>
            </form>
            <form
              :if={@ff && @show_filters?}
              id="field-filter-form"
              phx-change="field_filter_draft"
              phx-submit="add_field_filter"
            >
            </form>
          </div>

          <%!-- One chip per active facet, each its own remove button. --%>
          <div
            :if={@chips != []}
            class="flex flex-wrap items-center gap-2"
          >
            <ul id="content-filter-chips" class="flex flex-wrap gap-2">
              <li :for={chip <- @chips}>
                <button
                  type="button"
                  id={chip.id}
                  aria-label={gettext("Remove filter: %{filter}", filter: chip.label)}
                  class="chip"
                  {chip.attrs}
                >
                  {chip.label}
                  <.icon name="hero-x-mark" class="size-3.5" />
                </button>
              </li>
            </ul>
            <button
              type="button"
              phx-click="clear_filters"
              class="btn btn-sm btn-ghost text-base-content/70"
            >
              {gettext("Clear filters")}
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
        <.empty_state
          :if={@items == [] and @filtering?}
          id="content-no-match"
          icon="hero-funnel"
          title={gettext("Nothing matches the current filter.")}
          compact
          role="status"
        >
          {gettext("Try a wider filter, or clear it to see everything.")}
          <:action>
            <button type="button" phx-click="clear_filters" class="btn btn-sm btn-default">
              {gettext("Clear filters")}
            </button>
          </:action>
        </.empty_state>

        <div :if={@items != []} id="content-list" class="card">
          <%!-- The list's head: select-all and the count, and — only once
                something is ticked — what can be done to the selection. --%>
          <div class={[
            "flex min-h-12 flex-wrap items-center gap-x-4 gap-y-2 rounded-t-[inherit] border-b px-3 py-2 transition-colors",
            if(@selected_count > 0,
              do: "border-primary/25 bg-primary/8",
              else: "border-base-content/10 bg-base-200/40"
            )
          ]}>
            <label class="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={@all_selected?}
                phx-click="toggle_select_all"
                class="field-checkbox size-4"
              />
              {gettext("Select all")}
            </label>
            <span
              :if={@selected_count > 0}
              id="content-selected-count"
              class="text-sm font-medium text-primary-ink"
            >
              {gettext("%{count} selected", count: @selected_count)}
            </span>
            <span class="text-sm text-base-content/60" role="status" id="content-count">
              <%= if @total_capped? do %>
                {gettext("%{count}+ items", count: @total)}
              <% else %>
                {ngettext("%{count} item", "%{count} items", @total)}
              <% end %>
            </span>
            <div :if={@selected_count > 0} id="bulk-actions" class="ml-auto flex flex-wrap gap-2">
              <button
                :for={{verb, label} <- bulk_actions(@tier, @editors_can_publish)}
                type="button"
                phx-click="bulk"
                phx-value-action={verb}
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
                class="btn btn-sm btn-default"
              >
                {gettext("Add to release")}
              </button>
              <button
                :if={@tier == :admin}
                type="button"
                phx-click="bulk"
                phx-value-action="delete"
                class="btn btn-sm btn-danger"
              >
                {gettext("Delete")}
              </button>
              <%!-- Export selected (#2293): a plain download link to the rows
                    ticked here (ids, at most `ListScope.max_ids/0`: the URL
                    is a GET). Above the cap it is off, with the reason. --%>
              <a
                :if={@export? and @export_selected_path}
                id="bulk-export-selected"
                href={@export_selected_path}
                class="btn btn-sm btn-default"
              >
                <.icon name="hero-arrow-down-tray" class="size-4" />
                {gettext("Export selected")}
              </a>
              <button
                :if={@export? and @export_ids_too_many?}
                id="bulk-export-selected"
                type="button"
                disabled
                aria-describedby="bulk-export-limit"
                class="btn btn-sm btn-default"
              >
                <.icon name="hero-arrow-down-tray" class="size-4" />
                {gettext("Export selected")}
              </button>
              <span
                :if={@export? and @export_ids_too_many?}
                id="bulk-export-limit"
                class="self-center text-xs text-base-content/60"
              >
                {gettext("Select at most %{max} rows to export.", max: ListScope.max_ids())}
              </span>
            </div>
            <%!-- Which custom fields each row shows (this person's choice, per
                  site and type). Offered for one type at a time — field names
                  collide across types — so "all" gets a hint. Same disclosure
                  as the New menu: `data-autoclose` closes it on an outside
                  click (which is also what closes the New menu when this one
                  opens, and the reverse), and both sides write `hidden` and
                  `aria-expanded` so a list patch leaves it open. --%>
            <div
              :if={@column_options != []}
              id="content-columns"
              class={["relative", @selected_count == 0 && "ml-auto"]}
              data-autoclose
            >
              <button
                type="button"
                id="content-columns-toggle"
                class="btn btn-default btn-sm group"
                aria-expanded="false"
                aria-controls="content-columns-panel"
                phx-mounted={JS.ignore_attributes(["aria-expanded"])}
                phx-click={
                  JS.toggle_attribute({"aria-expanded", "true", "false"})
                  |> JS.toggle_attribute({"hidden", "hidden"}, to: "#content-columns-panel")
                }
              >
                <.icon name="hero-view-columns" class="size-4" />
                {gettext("Columns")}
                <.icon
                  name="hero-chevron-down"
                  class="size-3.5 transition-transform group-aria-expanded:rotate-180"
                />
              </button>
              <div
                id="content-columns-panel"
                hidden
                phx-mounted={JS.ignore_attributes(["hidden"])}
                class="absolute right-0 z-30 mt-2 w-64 max-w-[calc(100vw-2rem)] rounded-lg border border-base-content/10 bg-base-100 p-3 shadow-lg"
              >
                <form id="content-columns-form" phx-change="set_columns" class="space-y-2">
                  <input type="hidden" name="type" value={type_value(@column_type)} />
                  <input type="hidden" name="columns[]" value="" />
                  <p class="text-xs text-base-content/60">
                    {gettext("Show fields on each row. Pick up to %{count}; the first %{shown} show.",
                      count: ListFields.max_stored(),
                      shown: ListFields.max_shown()
                    )}
                  </p>
                  <div class="flex max-h-64 flex-col gap-0.5 overflow-y-auto">
                    <label
                      :for={option <- @column_options}
                      class="flex items-center gap-2 rounded-md px-1.5 py-1 text-sm hover:bg-base-200"
                    >
                      <input
                        type="checkbox"
                        name="columns[]"
                        value={option.name}
                        checked={option.name in @column_names}
                        disabled={
                          option.name not in @column_names and
                            length(@column_names) >= ListFields.max_stored()
                        }
                        class="field-checkbox size-4 shrink-0"
                      />
                      <span class="truncate">{option.label || option.name}</span>
                    </label>
                  </div>
                </form>
              </div>
            </div>
            <span
              :if={is_nil(@column_type)}
              id="content-columns-hint"
              class={["text-xs text-base-content/60", @selected_count == 0 && "ml-auto"]}
            >
              {gettext("Choose a content type to show its fields as columns.")}
            </span>
            <%!-- Export (#2293): the same disclosure shape as Columns and the New
                  menu, so all three close each other and on outside clicks.
                  Opening it asks the server for the matching count once per
                  filter state; the links are plain downloads, so they work
                  without the socket. --%>
            <div
              :if={@export?}
              id="content-export"
              class={[
                "relative",
                (@selected_count == 0 and @column_options == [] and not is_nil(@column_type)) &&
                  "ml-auto"
              ]}
              data-autoclose
            >
              <button
                type="button"
                id="content-export-toggle"
                class="btn btn-default btn-sm group"
                aria-expanded="false"
                aria-controls="content-export-panel"
                phx-mounted={JS.ignore_attributes(["aria-expanded"])}
                phx-click={
                  JS.toggle_attribute({"aria-expanded", "true", "false"})
                  |> JS.toggle_attribute({"hidden", "hidden"}, to: "#content-export-panel")
                  |> JS.push("export_count")
                }
              >
                <.icon name="hero-arrow-down-tray" class="size-4" />
                {gettext("Export")}
                <.icon
                  name="hero-chevron-down"
                  class="size-3.5 transition-transform group-aria-expanded:rotate-180"
                />
              </button>
              <div
                id="content-export-panel"
                hidden
                phx-mounted={JS.ignore_attributes(["hidden"])}
                class="absolute right-0 z-30 mt-2 w-72 max-w-[calc(100vw-2rem)] space-y-2 rounded-lg border border-base-content/10 bg-base-100 p-3 shadow-lg"
              >
                <p id="export-summary" class="text-sm font-medium">
                  <%= case @export_count do %>
                    <% :unknown -> %>
                      {gettext("Export matching")}
                    <% :over_cap -> %>
                      {gettext("More than %{max} rows — narrow the list first",
                        max: export_cap_label()
                      )}
                    <% {:ok, count} -> %>
                      {gettext("Export %{count} matching", count: count)}
                  <% end %>
                </p>
                <p class="text-xs text-base-content/60">
                  {gettext("Exports the columns shown in the list.")}
                </p>
                <label
                  :if={@export_private_option?}
                  class="flex items-center gap-2 text-sm"
                >
                  <input
                    id="export-private"
                    type="checkbox"
                    checked={@export_private_on?}
                    phx-click="toggle_export_private"
                    class="field-checkbox size-4"
                  />
                  {gettext("Include private fields")}
                </label>
                <div class="flex flex-wrap gap-2">
                  <a id="export-csv" href={@export_csv_path} class="btn btn-sm btn-default">
                    {gettext("Download CSV")}
                  </a>
                  <a id="export-json" href={@export_json_path} class="btn btn-sm btn-default">
                    {gettext("Download JSON")}
                  </a>
                </div>
              </div>
            </div>
          </div>

          <form
            :if={@adding_to_release?}
            id="add-to-release"
            phx-submit="add_to_release"
            class="flex flex-wrap items-end gap-3 border-b border-primary/25 bg-primary/5 px-3 py-2 text-sm"
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
            id="bulk-confirm"
            role="alertdialog"
            aria-labelledby="bulk-confirm-prompt"
            class={[
              "flex flex-wrap items-center gap-3 border-b px-3 py-2 text-sm",
              (@confirming_bulk == "delete" && "border-error/30 bg-error/10") ||
                "border-warning/30 bg-warning/10"
            ]}
          >
            <span id="bulk-confirm-prompt">
              {bulk_confirm_prompt(@confirming_bulk, @selected_count)}
            </span>
            <div class="ml-auto flex flex-wrap justify-end gap-2">
              <button
                type="button"
                phx-click="confirm_bulk"
                phx-mounted={JS.focus()}
                class={[
                  "btn btn-sm",
                  (@confirming_bulk == "delete" && "btn-danger-fill") || "btn-warning-fill"
                ]}
              >
                {bulk_verb_label(@confirming_bulk)}
              </button>
              <button type="button" phx-click="cancel_bulk" class="btn btn-sm btn-default">
                {gettext("Cancel")}
              </button>
            </div>
          </div>

          <ul class="divide-y divide-base-content/10 overflow-hidden rounded-b-[inherit]">
            <li
              :for={{kind, record} <- @items}
              id={"#{kind}-#{record.id}"}
              class={[
                "group/row flex flex-wrap items-center gap-x-3 gap-y-2 px-3 py-3 transition-colors sm:flex-nowrap",
                if(MapSet.member?(@selected, "#{kind}:#{record.id}"),
                  do: "bg-primary/5",
                  else: "hover:bg-base-200/40"
                )
              ]}
            >
              <input
                type="checkbox"
                checked={MapSet.member?(@selected, "#{kind}:#{record.id}")}
                phx-click="toggle_select"
                phx-value-key={"#{kind}:#{record.id}"}
                aria-label={gettext("Select %{title}", title: record.title)}
                class="field-checkbox size-4 shrink-0"
              />
              <.content_trigram
                :if={@status_marks == :trigrams}
                published={record.state == :published}
                translated={translated?(@translated, kind, record.slug)}
                scheduled={scheduled?(record)}
                class="text-base-content/50"
              />
              <div class="min-w-0 flex-1">
                <div class="flex min-w-0 items-center gap-2">
                  <.link
                    navigate={edit_path(kind, record.id)}
                    class="truncate font-medium hover:text-primary-ink hover:underline"
                  >
                    {record.title}
                  </.link>
                  <.badge variant="neutral" class="shrink-0">
                    {Map.get(@type_labels, to_string(kind), kind)}
                  </.badge>
                </div>
                <div class="mt-0.5 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-base-content/60">
                  <span class="max-w-full truncate font-mono text-[0.7rem]">/{record.slug}</span>
                  <span
                    :if={@author_names[record.author_id]}
                    class="flex items-center gap-1"
                  >
                    <.icon name="hero-user" class="size-3.5" />
                    {@author_names[record.author_id]}
                  </span>
                  <time
                    :if={record.updated_at}
                    datetime={DateTime.to_iso8601(record.updated_at)}
                    title={Calendar.strftime(record.updated_at, "%Y-%m-%d %H:%M UTC")}
                  >
                    {gettext("Updated %{time} ago", time: ago(record.updated_at))}
                  </time>
                  <%!-- A live record whose working copy has run ahead of its
                        published text (docs/working-copy.md). --%>
                  <span
                    :if={record.state == :published and record.working_copy_at}
                    class="italic"
                    title={gettext("The working copy has run ahead of the published text.")}
                  >
                    {gettext("edited since publishing")}
                  </span>
                  <span
                    :if={record.scheduled_at && record.state in [:draft, :in_review]}
                    class="flex items-center gap-1 font-medium text-primary-ink"
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
                    class="flex items-center gap-1 rounded border border-dashed border-base-content/40 px-1.5 text-base-content/70"
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
                    class="flex items-center gap-1"
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
                </div>
                <%!-- The chosen custom fields, a few label/value pairs. Only drawn
                      when the columns were selected into this row (`custom_fields`
                      is a loaded map, not the NotLoaded struct a narrower select
                      leaves). --%>
                <% fields = FieldCells.custom_fields(record) %>
                <dl
                  :if={@columns != [] and is_map(fields)}
                  id={"row-fields-#{kind}-#{record.id}"}
                  class="mt-1.5 flex flex-wrap gap-x-4 gap-y-0.5 text-xs"
                >
                  <div :for={column <- @columns} class="flex min-w-0 max-w-full gap-1">
                    <dt class="shrink-0 text-base-content/60">{column.label || column.name}</dt>
                    <dd class="truncate">{FieldCells.cell(@column_labels, column, fields)}</dd>
                  </div>
                </dl>
              </div>

              <div class="flex w-full shrink-0 items-center justify-end gap-2 sm:w-auto">
                <.content_status_marks
                  :if={@status_marks == :words}
                  translated={translated?(@translated, kind, record.slug)}
                />
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
                <.state_badge state={record.state} />

                <%!-- One visible next step per row — the verb that moves the
                      record along its workflow — and everything else behind
                      the "⋯" menu. The title is the way into the editor. --%>
                <% can_publish? = @tier == :admin or (@tier == :editor and @editors_can_publish) %>
                <button
                  :if={record.state in [:draft, :in_review] and can_publish?}
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
                  :if={record.state == :draft and @tier == :editor and not can_publish?}
                  type="button"
                  phx-click="submit"
                  phx-value-kind={kind}
                  phx-value-id={record.id}
                  class="btn btn-sm btn-default"
                >
                  {gettext("Submit for review")}
                </button>
                <span
                  :if={record.state == :in_review and @tier == :editor and not can_publish?}
                  class="text-xs text-base-content/70"
                >
                  {gettext("Awaiting admin approval")}
                </span>
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
                  id={"row-menu-button-#{kind}-#{record.id}"}
                  popovertarget={"row-menu-#{kind}-#{record.id}"}
                  aria-label={gettext("More actions for %{title}", title: record.title)}
                  title={gettext("More actions")}
                  class="btn btn-sm btn-ghost px-1.5 opacity-0 transition-opacity group-hover/row:opacity-100 group-focus-within/row:opacity-100 group-has-[:popover-open]/row:opacity-100 pointer-coarse:opacity-100"
                >
                  <.icon name="hero-ellipsis-horizontal" class="size-5" />
                </button>
                <div
                  id={"row-menu-#{kind}-#{record.id}"}
                  popover
                  class="row-menu"
                >
                  <button
                    :if={record.state == :draft and @tier == :editor and can_publish?}
                    type="button"
                    popovertarget={"row-menu-#{kind}-#{record.id}"}
                    popovertargetaction="hide"
                    phx-click="submit"
                    phx-value-kind={kind}
                    phx-value-id={record.id}
                    class="row-menu-item"
                  >
                    <.icon name="hero-paper-airplane" class="size-4 text-base-content/60" />
                    {gettext("Submit for review")}
                  </button>
                  <button
                    :if={
                      not is_nil(record.proposed_publish_at) and record.state in [:draft, :in_review] and
                        can_publish?
                    }
                    type="button"
                    popovertarget={"row-menu-#{kind}-#{record.id}"}
                    popovertargetaction="hide"
                    phx-click="confirm_proposed_date"
                    phx-value-kind={kind}
                    phx-value-id={record.id}
                    class="row-menu-item"
                  >
                    <.icon name="hero-calendar-days" class="size-4 text-base-content/60" />
                    {gettext("Confirm date")}
                  </button>
                  <button
                    :if={record.state == :in_review and @tier == :admin}
                    type="button"
                    popovertarget={"row-menu-#{kind}-#{record.id}"}
                    popovertargetaction="hide"
                    phx-click="return"
                    phx-value-kind={kind}
                    phx-value-id={record.id}
                    class="row-menu-item"
                  >
                    <.icon name="hero-arrow-uturn-left" class="size-4 text-base-content/60" />
                    {gettext("Return")}
                  </button>
                  <button
                    :if={record.state == :published and can_publish?}
                    type="button"
                    popovertarget={"row-menu-#{kind}-#{record.id}"}
                    popovertargetaction="hide"
                    phx-click="unpublish"
                    phx-value-kind={kind}
                    phx-value-id={record.id}
                    class="row-menu-item"
                  >
                    <.icon name="hero-eye-slash" class="size-4 text-base-content/60" />
                    {gettext("Unpublish")}
                  </button>
                  <button
                    type="button"
                    popovertarget={"row-menu-#{kind}-#{record.id}"}
                    popovertargetaction="hide"
                    phx-click="duplicate"
                    phx-value-kind={kind}
                    phx-value-id={record.id}
                    title={gettext("Copy into a new draft")}
                    class="row-menu-item"
                  >
                    <.icon name="hero-document-duplicate" class="size-4 text-base-content/60" />
                    {gettext("Duplicate")}
                  </button>
                  <.link
                    navigate={edit_path(kind, record.id) <> "?assign=1"}
                    class="row-menu-item"
                  >
                    <.icon name="hero-user-plus" class="size-4 text-base-content/60" />
                    {gettext("Assign")}
                  </.link>
                  <.link navigate={edit_path(kind, record.id)} class="row-menu-item">
                    <.icon name="hero-pencil-square" class="size-4 text-base-content/60" />
                    {gettext("Edit")}
                  </.link>
                  <%!-- Last and set apart: the one item that takes the row
                        away (#2137). Drawn where the destroy policy allows it
                        (`@trashable`); the handler asks again. --%>
                  <% trashable? = MapSet.member?(@trashable, "#{kind}:#{record.id}") %>
                  <hr :if={trashable?} class="my-1 border-base-content/10" aria-hidden="true" />
                  <button
                    :if={trashable?}
                    type="button"
                    id={"row-trash-#{kind}-#{record.id}"}
                    popovertarget={"row-menu-#{kind}-#{record.id}"}
                    popovertargetaction="hide"
                    phx-click="move_to_trash"
                    phx-value-kind={kind}
                    phx-value-id={record.id}
                    data-confirm={ContentTrash.confirm(record)}
                    class="row-menu-item text-error"
                  >
                    <.icon name="hero-trash" class="size-4" />
                    {gettext("Move to trash")}
                  </button>
                </div>
              </div>
            </li>
          </ul>
        </div>

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
  @panel_keys ~w(author category tag locale health reviewed consent_missing from to scheduled cf)

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

    active_saved =
      Enum.find(assigns.saved_views, &(Map.get(assigns.saved_view_params, &1.id) == current))

    assigns
    |> assign(:filter_ctx, ctx)
    |> assign(:default_views, defaults)
    |> assign(:active_saved_view, active_saved)
    |> assign(:active_view_id, (active_default || active_saved || %{id: nil}).id)
    |> assign(:stats, stats(assigns.overview, ctx, current))
    |> assign(:chips, chips(assigns))
    |> assign(:ff, field_filter_form(assigns))
    |> assign(
      :panel_count,
      assigns.filters |> Map.take(@panel_keys) |> Filters.to_params() |> map_size()
    )
  end

  # The overview strip's cards, in workflow order. Each links to the list it
  # counts and is current when that is exactly the filter on screen.
  defp stats(overview, ctx, current) do
    for {key, params} <- @overview do
      path_params = params |> Filters.parse(ctx) |> Filters.to_params()
      {label, icon, tone} = stat_look(key)

      %{
        key: key,
        label: label,
        icon: icon,
        tone: tone,
        count: Map.get(overview, key, 0),
        path: params_path(path_params),
        current?: path_params == current
      }
    end
  end

  # Tones match `state_badge/1`'s, so a card and the badges it counts agree.
  defp stat_look("draft"), do: {gettext("Drafts"), "hero-pencil", "bg-info/12 text-info-ink"}

  defp stat_look("in_review"),
    do: {gettext("In review"), "hero-eye", "bg-warning/20 text-warning-ink"}

  defp stat_look("scheduled"),
    do: {gettext("Scheduled"), "hero-clock", "bg-primary/12 text-primary-ink"}

  defp stat_look("published"),
    do: {gettext("Published"), "hero-check-circle", "bg-success/15 text-success-ink"}

  # `{key, label}` for every active facet but the sort, in a stable order.
  defp chips(assigns) do
    params = Filters.to_params(assigns.filters)

    flat =
      for key <-
            ~w(q status type author category tag locale health reviewed consent_missing from to scheduled),
          value = params[key],
          not is_nil(value),
          do: %{
            id: nil,
            label: chip_label(key, value, assigns),
            attrs: %{"phx-click" => "remove_filter", "phx-value-key" => key}
          }

    flat ++ field_chips(assigns)
  end

  # One chip per custom-field condition (#2293), each its own remove button.
  # The conditions came through `Filters.parse/2`, so each names a field of
  # `column_options`; the label is looked up there and a condition without one
  # (it cannot happen after a parse) is simply not drawn.
  defp field_chips(assigns) do
    for {%{field: name, op: op, value: value}, n} <-
          assigns.filters |> Filters.conditions() |> Enum.with_index(),
        definition = Enum.find(assigns.column_options, &(&1.name == name)),
        do: %{
          id: "field-filter-chip-#{n}",
          label: condition_label(definition, op, value),
          attrs: %{
            "phx-click" => "remove_field_filter",
            "phx-value-field" => name,
            "phx-value-op" => op
          }
        }
  end

  @chip_value_chars 40

  defp condition_label(definition, "null", value) do
    field = field_name(definition)

    if value == "true",
      do: gettext("%{field} is empty", field: field),
      else: gettext("%{field} has a value", field: field)
  end

  defp condition_label(definition, op, value) do
    gettext("%{field} %{op} %{value}",
      field: field_name(definition),
      op: op_symbol(definition.field_type, op),
      value: value |> value_label(definition) |> String.slice(0, @chip_value_chars)
    )
  end

  defp field_name(definition), do: definition.label || definition.name

  defp value_label(value, %{field_type: :select} = definition),
    do: KilnCMS.CMS.FieldDefinition.option_label(definition, value)

  defp value_label("true", %{field_type: :boolean}), do: gettext("Yes")
  defp value_label("false", %{field_type: :boolean}), do: gettext("No")
  defp value_label(value, _definition), do: value

  # The chip's short operator: symbols for ranges, words where a symbol reads
  # oddly (a day range is "from"/"until", a substring is "contains").
  defp op_symbol(_type, "gt"), do: ">"
  defp op_symbol(type, "gte") when type in [:date, :datetime], do: gettext("from")
  defp op_symbol(_type, "gte"), do: "≥"
  defp op_symbol(_type, "lt"), do: "<"
  defp op_symbol(type, "lte") when type in [:date, :datetime], do: gettext("until")
  defp op_symbol(_type, "lte"), do: "≤"
  defp op_symbol(_type, "contains"), do: gettext("contains")
  defp op_symbol(type, "eq") when type in [:integer, :float, :date], do: "="
  defp op_symbol(_type, "eq"), do: gettext("is")

  # The op <select>'s wording, per field type.
  defp op_option_label(type, "gte") when type in [:date, :datetime], do: gettext("From")
  defp op_option_label(type, "lte") when type in [:date, :datetime], do: gettext("Until")
  defp op_option_label(_type, "eq"), do: gettext("Is")
  defp op_option_label(_type, "gt"), do: gettext("Greater than")
  defp op_option_label(_type, "gte"), do: gettext("At least")
  defp op_option_label(_type, "lt"), do: gettext("Less than")
  defp op_option_label(_type, "lte"), do: gettext("At most")
  defp op_option_label(_type, "contains"), do: gettext("Contains")
  defp op_option_label(_type, "null"), do: gettext("Empty or not")

  defp sortable_options(options),
    do: Enum.filter(options, &KilnCMS.CMS.ListFieldQuery.sortable?/1)

  defp field_sort_label(option, :asc),
    do: gettext("Field: %{field} (↑)", field: field_name(option))

  defp field_sort_label(option, :desc),
    do: gettext("Field: %{field} (↓)", field: field_name(option))

  # The value control for the draft condition, by field type: `{input type,
  # extra attrs, select options or nil}`.
  defp value_control(_definition, "null"),
    do: {"select", [], [{gettext("Empty"), "true"}, {gettext("Has a value"), "false"}]}

  defp value_control(%{field_type: :boolean}, _op),
    do: {"select", [], [{gettext("Yes"), "true"}, {gettext("No"), "false"}]}

  defp value_control(%{field_type: :select} = definition, _op) do
    options =
      for option <- List.wrap(definition.options),
          do: {KilnCMS.CMS.FieldDefinition.option_label(definition, option), option}

    {"select", [], options}
  end

  defp value_control(%{field_type: :integer}, _op), do: {"number", [step: "1"], nil}
  defp value_control(%{field_type: :float}, _op), do: {"number", [step: "any"], nil}

  defp value_control(%{field_type: type}, _op) when type in [:date, :datetime],
    do: {"date", [], nil}

  defp value_control(%{field_type: type}, _op) when type in [:reference, :user, :media],
    do: {"text", [placeholder: gettext("An id (UUID)"), autocomplete: "off"], nil}

  defp value_control(_definition, _op), do: {"text", [autocomplete: "off"], nil}

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
  defp chip_label("reviewed", reviewed, _assigns), do: Filters.reviewed_label(reviewed)

  defp chip_label("consent_missing", kind, _assigns),
    do: gettext("No %{kind} consent", kind: Filters.consent_kind_label(kind))

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

  defp tally_bulk(:ok, {ok, skipped, sev}), do: {ok + 1, skipped, sev}
  defp tally_bulk({:ok, _}, {ok, skipped, sev}), do: {ok + 1, skipped, sev}

  defp tally_bulk({:error, error}, {ok, skipped, sev}) do
    if severity_required?(error), do: {ok, skipped, sev + 1}, else: {ok, skipped + 1, sev}
  end

  defp tally_bulk(_other, {ok, skipped, sev}), do: {ok, skipped + 1, sev}
end
