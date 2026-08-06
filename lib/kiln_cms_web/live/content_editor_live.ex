defmodule KilnCMSWeb.ContentEditorLive do
  @moduledoc """
  Block editor for a single content record of **any** content type. The type
  comes from the `:type` param on `/editor/content/:type/:id` (or the
  `live_action` on the legacy `/editor/pages|posts/:id` routes) and is resolved
  through `KilnCMS.CMS.ContentTypes`, so types generated with
  `mix kiln.gen.content` are editable here with no extra wiring.

  Edit title/slug (+ excerpt where the type has one) and the typed block tree —
  blocks are authored as native `Ash.Type.Union` member sub-forms (Kiln v2), with
  per-member fields generated from each block's `Kiln.Block` DSL (add/remove/reorder
  via the `Sortable` hook, **TipTap rich text** for `rich_text`). A **side-by-side
  live preview** renders through the same typed serializers as firing/delivery
  (preview parity). Plus SEO & scheduling, version history + restore, and the
  publishing workflow. Editor/admin only.
  """
  use KilnCMSWeb, :live_view

  require Ash.Query
  require Logger

  import Ash.Expr, only: [expr: 1]
  import KilnCMSWeb.AccessibilityComponents, only: [a11y_findings: 1, a11y_grade_badge: 1]

  import KilnCMSWeb.ComplianceComponents,
    only: [compliance_findings: 1, compliance_grade_badge: 1]

  import KilnCMSWeb.SeoComponents, only: [seo_findings: 1, seo_grade_badge: 1]
  import KilnCMSWeb.VersionDiffComponents, only: [version_compare: 1]

  alias Kiln.Advisory.Registry
  alias Kiln.Advisory.Report
  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.VersionDiff
  alias KilnCMS.CMS.VersionSnapshot
  alias KilnCMS.Slug
  alias KilnCMSWeb.EditorTelemetry
  alias KilnCMSWeb.Presence
  alias KilnCMSWeb.VersionDiffComponents

  # Preferred display order for the block palette; any block type registered
  # beyond these is appended automatically (the palette is registry-driven, so
  # adding a `Kiln.Block` module needs no editor change).
  @type_order ~w(rich_text heading quote image gallery file embed divider columns accordion faq how_to claim custom)

  # Block types edited by `item_rows_editor/1` — a repeating label + body row —
  # and the `{:array, :map}` param names those rows bind into. Both lists are
  # load-bearing beyond the component: `normalize_item_rows/1` needs the field
  # names to turn indexed maps back into lists, and the add/remove handlers
  # guard on them. A block added to one and not the other silently loses its
  # rows on save, which is why they sit together here rather than inline.
  @row_editor_types ~w(faq how_to accordion)
  @row_fields ~w(items steps panels)

  # Child block types offerable inside a `columns` container (#335). A curated
  # subset with simple field editors — nested blocks get functional inputs, not
  # the top-level TipTap/media-picker treatment. Columns-in-columns is supported
  # by the model/renderer but intentionally not offered here (one nesting level
  # keeps the nested editor legible).
  @nested_child_types ~w(heading rich_text quote image embed divider)

  # Bounds on the columns editor, so the nested UI (and any hostile client event)
  # can't create a pathological tree. The storage cast has its own depth guard.
  @max_columns 4
  @max_children_per_column 20

  # Stands in for the working draft on the version-compare picker (#467). A
  # version id is a UUID, so this can never collide with one.
  @current_pick "current"

  # Bound the media picker window loaded on mount (newest first) so a large
  # library can't grow each open editor's heap without limit.
  @max_media 500

  # Idle delay before a draft is autosaved after the last edit. Configurable so
  # tests can shorten it.
  @autosave_debounce_ms Application.compile_env(
                          :kiln_cms,
                          [:editor, :autosave_debounce_ms],
                          2_000
                        )

  # Stable per-collaborator colors for live focus cursors. Static class strings
  # so Tailwind keeps them.
  @cursor_colors ~w(
    bg-rose-500 bg-amber-500 bg-emerald-500 bg-sky-500 bg-violet-500 bg-pink-500
  )

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    # Deep-linked from the content list's "Assign" button (#501): open
    # straight to the Settings tab with the assignment form expanded.
    assign_deep_link? = params["assign"] in ["1", "true"]

    case content_kind(params, socket) do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/editor")}

      kind ->
        actor = socket.assigns.current_user
        org = socket.assigns.current_org
        record = fetch!(kind, id, actor, org)
        field_definitions = field_definitions(kind, actor, org)
        content_type = ContentTypes.get!(kind, org_id(org))

        if connected?(socket) do
          topic = Presence.track_editor(self(), kind, id, actor)
          Phoenix.PubSub.subscribe(KilnCMS.PubSub, topic)
          # Preview-window joins/leaves, so broadcast_preview/1 can no-op
          # while no pop-out is watching.
          Phoenix.PubSub.subscribe(KilnCMS.PubSub, Presence.preview_topic(kind, id))
        end

        {:ok,
         socket
         |> assign(:kind, kind)
         |> assign(:content_type, content_type)
         |> assign(:slug_targets, slug_targets(content_type))
         |> assign(:has_excerpt, content_type.excerpt?)
         |> assign(:actor, actor)
         |> assign(:tier, KilnCMSWeb.LiveUserAuth.effective_tier(socket))
         |> assign(:block_types, block_types())
         |> assign(:nested_child_types, @nested_child_types)
         |> assign(:editors, Presence.editors(kind, id))
         |> assign(:preview_open?, Presence.previews_open?(kind, id))
         |> assign(:cursors, %{})
         |> assign(:self_field, nil)
         # Deep-link focus from an external front end (#355): `?focus=<field>`
         # scrolls to and pulses that field's input on load (block ids use the
         # in-context editor's `?focus=`; this is the custom/core-field twin).
         |> assign(:focus_field, params["focus"])
         # Debounced draft autosave: pending timer ref + status indicator state.
         |> assign(:autosave_timer, nil)
         |> assign(:save_state, :saved)
         # Set when an optimistic-lock conflict blocks saving until reload.
         |> assign(:conflict, false)
         # Bumped on server-driven form replacement (conflict reload, version
         # restore) so rich-text blocks remount and reload TipTap from the new
         # content — `phx-update="ignore"` otherwise keeps the stale editor (#135).
         |> assign(:editor_version, 0)
         # Version compare (#467): the (at most two) history entries picked in the
         # version panel, and the computed diff while the modal is open. Restoring
         # blind is the thing this replaces, so the modal offers Restore itself.
         |> assign(:current_pick, @current_pick)
         |> assign(:compare_pick, [])
         |> assign(:compare, nil)
         # Right inspector rail (Theme A): which panel is showing. All panels stay
         # mounted (form fields must survive submit) — the tab only toggles CSS
         # visibility, never `:if`. Always mounts as `:preview` here (even for
         # the `?assign=1` deep link, switched to `:settings` further below,
         # AFTER `assign_record/2`) — `refresh_preview_html/2` only computes
         # `@preview_html` when `inspector_tab` is `nil`/`:preview` at mount, so
         # defaulting straight to `:settings` left it unassigned and crashed
         # the Preview panel, which stays rendered (CSS-hidden) either way.
         |> assign(:inspector_tab, :preview)
         # Preview render is only refreshed while the Preview tab is showing;
         # this tracks whether an off-tab edit left it needing a re-render.
         |> assign(:preview_stale, false)
         # AI-assisted SEO drafting (#60). Read once at mount: this is global
         # app config, so it can't change under a live session. `seo_drafts`
         # holds the current proposal (never persisted, never broadcast — each
         # editor's suggestions are their own); `seo_dismissed` tracks fields
         # already accepted or waved away so their cards stop rendering.
         |> assign(:seo_enabled?, KilnCMS.Seo.enabled?())
         |> assign(:seo_egress?, KilnCMS.Seo.egress?())
         |> assign(:seo_provider, KilnCMS.Seo.provider())
         |> assign(:seo_drafting?, false)
         |> assign(:seo_drafts, nil)
         |> assign(:seo_dismissed, MapSet.new())
         # Block-level AI assist (#60) — the body-copy twin of the metadata
         # drafting above, and a separate switch, so a deployment can run one
         # without the other. Read once at mount for the same reason.
         # `assist_block` is the id of the block whose panel is open (nil =
         # closed); only one is ever open, so one suggestion is ever in flight.
         |> assign(:assist_enabled?, KilnCMS.Assist.enabled?())
         |> assign(:assist_egress?, KilnCMS.Assist.egress?())
         |> assign(:assist_provider, KilnCMS.Assist.provider())
         |> assign(:assist_block, nil)
         |> assign(:assist_action, :rewrite)
         |> assign(:assist_instruction, nil)
         |> assign(:assist_running?, false)
         |> assign(:assist_result, nil)
         # Block-level editorial comments (#404): loaded once at mount (a
         # document's comment volume is small) and refreshed after
         # add/resolve/unresolve. `comment_block` is the id of the block whose
         # thread panel is open (nil = closed, one at a time — same pattern as
         # `assist_block`); `comment_draft` is that panel's textarea value.
         |> assign(:comments, load_comments(kind, record.id, actor, org))
         |> assign(:comment_block, nil)
         |> assign(:comment_draft, nil)
         # Internal-link suggestions (#377). `nil` = never opened; loading is
         # deferred to first open because it costs a pgvector query plus a
         # record read per neighbour, which no page-load should pay.
         |> assign(:seo_links, nil)
         |> assign(:seo_links_loading?, false)
         # Media picker (image blocks) + relationship pickers (taxonomy, siblings).
         # `picking` is nil (closed), a block index (fill that image block), or
         # `:new` (insert a new image block — opened from the editor chrome).
         |> assign(:picking, nil)
         |> assign(:picked, [])
         |> assign(:media_query, "")
         # nil = not searching (browse the mounted window); a list = DB search
         # results, so the picker also finds items beyond that window.
         |> assign(:picker_media, nil)
         |> assign(
           :media,
           # The picker grid needs only these fields; a select keeps 500
           # variants/EXIF-bearing rows out of the editor's heap. Images
           # only (#481 added non-image documents to the library, which the
           # image/gallery/featured/social-image pickers below have no way
           # to render or insert as an `<img>`) — filtered on `content_type`,
           # NOT `width`: a just-uploaded image has `width: nil` until
           # `Media.VariantWorker` runs (see `media_live.ex`), and that
           # window is common enough that a handful of pre-existing tests
           # seed images without ever setting it. `width` is still the right
           # signal for "does this item have a thumbnail to show" (the
           # library grid, `thumb_src/1`) — just not for "is this an image".
           #
           # A NULL `content_type` counts as an image, not excluded: every
           # row was implicitly an image before #481 (documents didn't
           # exist), and plenty of seed data/tests still create rows without
           # setting it. Only a row with a *known, non-image* content_type
           # is confidently a document, below.
           CMS.list_media_items!(
             actor: actor,
             tenant: org,
             query: [
               filter: expr(is_nil(content_type) or ilike(content_type, "image/%")),
               select: [:id, :url, :alt, :caption, :filename],
               sort: [inserted_at: :desc],
               limit: @max_media
             ]
           )
         )
         |> assign(
           :file_media,
           # The document counterpart of `:media` above (#481) — for the
           # file-block picker. `content_type`/`byte_size` are denormalized
           # onto the block at pick time (see `pick_file/2`), same as `alt`
           # is for an image block. Requires an EXPLICIT non-image
           # content_type (see the image filter's comment above) — a row
           # with no content_type at all defaults to the image bucket, not
           # this one. Documents only: video/audio/caption tracks (#494)
           # have their own list below.
           CMS.list_media_items!(
             actor: actor,
             tenant: org,
             query: [
               filter: document_filter(),
               select: [:id, :filename, :content_type, :byte_size, :audience],
               sort: [inserted_at: :desc],
               limit: @max_media
             ]
           )
         )
         |> assign(
           :av_media,
           # Playable media (#494) — video and audio, for the video/audio
           # block pickers. `duration_seconds` and `variants` come along
           # because the picker shows the length and the poster thumbnail,
           # and `duration_seconds` is denormalized onto the block at pick
           # time for the JSON-LD `duration`.
           CMS.list_media_items!(
             actor: actor,
             tenant: org,
             query: [
               filter: av_filter(),
               select: [
                 :id,
                 :filename,
                 :content_type,
                 :byte_size,
                 :audience,
                 :duration_seconds,
                 :variants
               ],
               sort: [inserted_at: :desc],
               limit: @max_media
             ]
           )
         )
         |> assign(:file_picking, nil)
         |> assign(:picker_files, nil)
         |> assign(:file_query, "")
         # The A/V picker fills one of three different field pairs on a video
         # block (the media itself, its poster, its caption track), so it
         # carries a `{block_id, field}` target rather than a bare block id
         # like `@file_picking` does — see `open_av_picker`.
         |> assign(:av_picking, nil)
         |> assign(:picker_av, nil)
         |> assign(:av_query, "")
         # Taxonomy pick-lists are scanned by eye, so they load in alphabetical
         # order rather than whatever Postgres hands back. Tags additionally
         # carry their group, which sections the picker (see `tag_picker/1`).
         |> assign(
           :categories,
           CMS.list_categories!(actor: actor, tenant: org, query: [sort: [name: :asc]])
         )
         |> assign(
           :tags,
           CMS.list_tags!(actor: actor, tenant: org, query: [sort: [name: :asc]])
         )
         # `TagGroup`'s primary read is already ordered by position then name.
         |> assign(:tag_groups, CMS.list_tag_groups!(actor: actor, tenant: org))
         |> assign(:audiences, audience_options())
         |> assign(:field_definitions, field_definitions)
         |> assign(:reference_options, reference_options(field_definitions, actor, org))
         # CRDT collab prototype: when enabled, rich-text blocks sync live
         # between editors over the collab channel (see KilnCMS.Collab.Crdt).
         |> assign(:collab_token, collab_token(actor))
         # From `record.id`, not the route param: the channel rebuilds the doc
         # key from the record it resolves, and a differently-cased id in the
         # URL would otherwise name the same document under a different key
         # (#655).
         |> assign(:collab_topic, "collab:#{kind}:#{record.id}")
         |> assign(:siblings, siblings(kind, id, actor, org))
         # Editorial tasks (#501): open tasks on this record (usually zero or
         # one), plus the org members eligible to be assigned one. Reloaded
         # after assign/complete; the assignee list is loaded once (an org's
         # editor roster doesn't change mid-session).
         |> assign(:tasks, load_tasks(kind, record.id, actor, org))
         |> assign(:assignable_users, assignable_users())
         |> assign(:task_assign_open?, assign_deep_link?)
         |> assign(:task_draft, %{})
         # Content releases (#500 / #836): the record's pending release, if any,
         # plus the releases it could be added to.
         |> assign_release_state(kind, record.id, actor, org)
         |> assign_record(record)
         |> open_settings_if_deep_linked(assign_deep_link?)}
    end
  end

  # See the `:inspector_tab` mount comment above for why this runs AFTER
  # `assign_record/2` rather than being folded into the initial assign.
  defp open_settings_if_deep_linked(socket, true), do: assign(socket, :inspector_tab, :settings)
  defp open_settings_if_deep_linked(socket, false), do: socket

  # The content type being edited: from the `:type` param on the generic
  # `/editor/content/:type/:id` route, or the `live_action` on the legacy
  # `/editor/pages|posts/:id` routes. Returns nil for an unknown type.
  defp content_kind(%{"type" => type}, socket) do
    # Resolve the type within the current site (epic #336) — a dynamic type name
    # only names a type on the org that defined it.
    case ContentTypes.get(type, org_id(socket.assigns.current_org)) do
      nil -> nil
      ct -> ct.type
    end
  end

  defp content_kind(_params, socket), do: socket.assigns.live_action

  # A pop-out preview window opened or closed — flip the broadcast gate.
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{event: "presence_diff", topic: "previewing:" <> _},
        socket
      ) do
    open? = Presence.previews_open?(socket.assigns.kind, socket.assigns.record.id)
    socket = assign(socket, :preview_open?, open?)
    # Catch the window up with the latest unsaved edits the moment it opens.
    if open?, do: broadcast_preview(socket)
    {:noreply, socket}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    editors = Presence.editors(socket.assigns.kind, socket.assigns.record.id)
    # Drop cursors for anyone who has left, so stale focus badges disappear.
    present = MapSet.new(editors, & &1.id)
    cursors = Map.filter(socket.assigns.cursors, fn {id, _} -> MapSet.member?(present, id) end)
    socket = assign(socket, editors: editors, cursors: cursors)

    # If the departing persister left us in charge while we hold live-synced
    # edits, take over persistence by scheduling the autosave we suppressed.
    socket =
      if socket.assigns.save_state == :synced and persister?(socket),
        do: mark_dirty(socket),
        else: socket

    {:noreply, socket}
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

  # Debounced draft autosave fired by the timer scheduled in `validate`.
  def handle_info(:autosave, socket), do: {:noreply, perform_autosave(socket)}

  # Drafting results. Note the double wrap: `start_async` wraps the function's
  # own return, so a successful generation arrives as `{:ok, {_version, {:ok, _}}}`.
  # All three arms must clear `seo_drafting?` or the button stays stuck forever.
  @impl true
  def handle_async(:seo_draft, {:ok, {version, result}}, socket) do
    socket = assign(socket, :seo_drafting?, false)

    cond do
      # A conflict reload or version restore replaced the form while we waited;
      # the suggestion describes content the author is no longer editing.
      version != socket.assigns.editor_version ->
        {:noreply, socket}

      match?({:ok, _draft}, result) ->
        {:ok, draft} = result
        {:noreply, assign(socket, :seo_drafts, draft)}

      true ->
        {:error, reason} = result
        {:noreply, put_flash(socket, :error, seo_error_message(reason))}
    end
  end

  def handle_async(:seo_links, {:ok, suggestions}, socket) do
    {:noreply,
     socket
     |> assign(:seo_links_loading?, false)
     |> assign(:seo_links, suggestions)}
  end

  def handle_async(:seo_links, {:exit, reason}, socket) do
    Logger.warning("Internal-link suggestion task exited: #{inspect(reason)}")

    # An empty list rather than nil: nil means "not loaded yet" and would make
    # the panel try again on every open.
    {:noreply, socket |> assign(:seo_links_loading?, false) |> assign(:seo_links, [])}
  end

  def handle_async(:seo_draft, {:exit, reason}, socket) do
    Logger.warning("SEO drafting task exited: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:seo_drafting?, false)
     |> put_flash(:error, gettext("Couldn't generate suggestions. Please try again."))}
  end

  # Block assist results (#60). Same double wrap as `:seo_draft`, and one extra
  # stamp: the *block id* the request was made for. `editor_version` catches a
  # conflict reload; the block id catches the author closing the panel and
  # opening another block's while the first was still running, which would
  # otherwise offer block A's prose under block B's Insert button.
  def handle_async(:assist, {:ok, {version, block_id, result}}, socket) do
    socket = assign(socket, :assist_running?, false)

    if version != socket.assigns.editor_version or block_id != socket.assigns.assist_block do
      # Silent, deliberately. Closing the panel or opening another block's
      # cancels the task (`cancel_assist/1`), so reaching here at all means the
      # generator reported inside the race window of an action the author took
      # on purpose. A flash would appear or not depending on timing.
      {:noreply, socket}
    else
      case result do
        {:ok, suggestion} -> {:noreply, assign(socket, :assist_result, suggestion)}
        {:error, reason} -> {:noreply, put_flash(socket, :error, assist_error_message(reason))}
      end
    end
  end

  # A run the author walked away from — see `cancel_assist/1`. Nothing to
  # report: they closed the panel, and `assist_running?` is already false.
  def handle_async(:assist, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  def handle_async(:assist, {:exit, reason}, socket) do
    Logger.warning("Block assist task exited: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:assist_running?, false)
     |> put_flash(:error, gettext("Couldn't generate text. Please try again."))}
  end

  defp assign_record(socket, record) do
    socket = assign(socket, :record, record)

    socket
    |> assign(:page_title, record.title)
    |> assign(:slug_customized?, slug_customized?(socket))
    |> assign(:form, build_form(record, socket.assigns.actor))
    |> seed_block_children(record)
    |> refresh_preview()
    |> load_versions()
    |> load_translations()
  end

  # Whether the slug is the author's own (pinned) or still auto-derived — while
  # not customized, editing a slug-source field re-derives the slug live
  # (WordPress-style). Published/scheduled content is always treated as pinned:
  # a title edit must never silently move a live URL. The `untitled-<n>`
  # scaffold slug stamped by the list view's "New" button counts as underived.
  defp slug_customized?(socket) do
    record = socket.assigns.record

    if record.state != :draft do
      true
    else
      derived =
        KilnCMS.CMS.Slugs.derive_base(
          socket.assigns.content_type.slug_pattern,
          slug_context(socket)
        )

      not KilnCMS.CMS.Slugs.underived?(record.slug, derived)
    end
  end

  # Keep the slug tracking its source fields until the author pins it by
  # typing in the slug field themselves (see `slug_customized?/1`). Clearing
  # the slug field unpins it — derivation resumes, and `DeriveSlug` fills any
  # blank on save. Which fields count as sources depends on the type's pattern
  # (`slug_targets/1`, computed at mount): category/date edits only re-derive
  # when the pattern actually uses those tokens.
  defp sync_slug(params, target, socket) do
    cond do
      target == ["form", "slug"] ->
        {params, assign(socket, :slug_customized?, String.trim(params["slug"] || "") != "")}

      target in socket.assigns.slug_targets and not socket.assigns.slug_customized? ->
        {Map.put(params, "slug", derive_unique_slug(socket, params)), socket}

      true ->
        {params, socket}
    end
  end

  defp slug_targets(ct) do
    [["form", "title"], ["form", "seo_keywords"]] ++
      if(Slug.Pattern.uses?(ct.slug_pattern, "category"),
        do: [["form", "category_id"]],
        else: []
      ) ++
      if(Slug.Pattern.uses_dates?(ct.slug_pattern), do: [["form", "scheduled_at"]], else: [])
  end

  # Derivation + pathauto-style dedupe, so the slug shown live is the one that
  # will actually save ("guide-kiln-2" when "guide-kiln" is taken). Shares
  # `Slugs.derive_base/2` with the resource-level `DeriveSlug` change.
  defp derive_unique_slug(socket, params) do
    base =
      KilnCMS.CMS.Slugs.derive_base(
        socket.assigns.content_type.slug_pattern,
        slug_context(socket, params)
      )

    if base == "",
      do: "",
      else: KilnCMS.CMS.Slugs.ensure_unique(base, slug_scope(socket))
  end

  # Token inputs for pattern expansion — from the live form params when given
  # (a keystroke), else the record (mount/reload). The date anchor mirrors
  # `DeriveSlug`: publish date, else the (live) scheduled date, else the
  # record's creation date — stable across sessions, so reopening a draft
  # tomorrow can't flip it to "pinned".
  defp slug_context(socket, params \\ nil) do
    record = socket.assigns.record

    %{
      title: param_or(params, "title", record.title),
      seo_keywords: param_or(params, "seo_keywords", Map.get(record, :seo_keywords)),
      category_slug: category_slug(socket, param_or(params, "category_id", record.category_id)),
      date: slug_date(record, params)
    }
  end

  defp param_or(nil, _key, fallback), do: fallback
  defp param_or(params, key, fallback), do: params[key] || fallback

  defp slug_date(record, params) do
    record.published_at || form_scheduled_at(params) || record.scheduled_at ||
      record.inserted_at
  end

  # The scheduling panel's (UTC) value as typed, so date tokens track it live.
  defp form_scheduled_at(nil), do: nil

  defp form_scheduled_at(params) do
    with value when is_binary(value) and value != "" <- params["scheduled_at"],
         {:ok, datetime, _offset} <- DateTime.from_iso8601(String.replace(value, " ", "T")) do
      datetime
    else
      _ -> nil
    end
  end

  # Category slugs resolve from the mount-time list (the same one the select
  # offers, so every pickable id is present). A rename by another user
  # mid-session isn't reflected until reopen — consistent with the rest of the
  # mount-scoped assigns.
  defp category_slug(socket, category_id) do
    Enum.find_value(socket.assigns.categories, fn category ->
      category.id == category_id && category.slug
    end)
  end

  defp slug_scope(socket) do
    KilnCMS.CMS.Slugs.unique_scope(
      socket.assigns.content_type,
      socket.assigns.record,
      socket.assigns.current_org
    )
  end

  # The full public path previewed under the slug field, live from the form.
  # The canonical URL previewed under the slug field: a multi-segment path
  # alias (#485) when one is typed, else the flat prefix + slug.
  defp live_public_path(form, content_type) do
    case form[:path_alias].value do
      alias_path when is_binary(alias_path) and alias_path != "" -> alias_path
      _blank -> KilnCMS.CMS.Slugs.public_path(content_type, form[:slug].value)
    end
  end

  # The slug-scoped slice of the SEO report (#456 is the inline slice of #476) —
  # the same findings, filtered to the field the slug input is responsible for,
  # so the hints stay next to the thing they describe.
  defp slug_report(report),
    do: %{report | findings: Enum.filter(report.findings, &(&1.field == :slug))}

  # Seed the socket-managed children of every stored `columns` block, keyed by the
  # block's stable id (#335). Children live in socket state (not bound form
  # inputs) because a `{:array, :map}` field isn't an AshPhoenix sub-form; they're
  # injected back into the form params on every validate/save so the form — and
  # thus the preview and the eventual write — stays in sync. See `inject_children/2`.
  defp seed_block_children(socket, record) do
    children =
      record.blocks
      |> KilnCMS.CMS.TypedBlocks.to_typed()
      |> Enum.filter(&match?(%KilnCMS.Blocks.Columns{}, &1))
      |> Map.new(fn %KilnCMS.Blocks.Columns{} = c -> {c.id, normalize_columns(c.columns)} end)

    # Rich-text bodies (Portable Text) held in socket state, keyed by block id
    # (or "idx-N" for a not-yet-saved block) and injected into the form params
    # on every validate/save/autosave — see inject_rich_bodies/2. Seeded from
    # the stored blocks on every record (re)load: the rendered form only
    # round-trips `legacy_html`, so without the seed a save that never touched
    # a PT-backed block would replace its `body` with the empty default. The
    # TipTap hook's pushes then overwrite the seeded entry as the author types.
    rich_bodies =
      record.blocks
      |> KilnCMS.CMS.TypedBlocks.to_typed()
      |> Enum.filter(&match?(%KilnCMS.Blocks.RichText{body: [_ | _]}, &1))
      |> Map.new(fn %KilnCMS.Blocks.RichText{} = b -> {b.id, b.body} end)

    socket
    |> assign(:block_children, children)
    |> assign(:rich_bodies, rich_bodies)
  end

  # Per-locale coverage for the Translations panel (only rendered when the
  # install has more than one locale).
  defp load_translations(socket) do
    assign(
      socket,
      :translations,
      KilnCMS.CMS.Translations.coverage(socket.assigns.kind, socket.assigns.record,
        actor: socket.assigns.actor,
        tenant: socket.assigns.current_org
      )
    )
  end

  # The inline preview HTML is computed once per *form change* and kept in an
  # assign — it's rendered twice (mobile + desktop copies), and recomputing the
  # full sanitize-and-render pipeline in the template ran it on every render,
  # including presence diffs and collaborator cursor events.
  #
  # The SEO body stats (#476) ride along: they need the same typed block list,
  # so deriving it once here serves both and keeps the analysis from ever going
  # stale against the preview.
  #
  # Deriving the stats costs ~40ms on a 500-block document, and this runs on
  # every keystroke — so it's gated on the body actually having changed. The
  # guard is a hash rather than an `_target` check at each call site: it can't
  # go stale when a new block-mutating event is added, and hashing is ~1ms
  # against the 40ms it saves when the author is only editing scalar fields.
  defp refresh_preview(socket) do
    typed =
      socket.assigns.form
      |> preview_block_maps()
      |> KilnCMS.CMS.TypedBlocks.to_typed()

    socket
    |> refresh_preview_html(typed)
    |> refresh_body_stats(typed)
    |> refresh_seo_report()
  end

  # The in-editor preview is a full block render of every block. Only pay for
  # it while the Preview tab is actually showing; otherwise mark it stale and
  # let switch_inspector_tab re-render on the way back. (nil = pre-mount, when
  # the Preview tab is the default, so render then too.)
  #
  # The SEO analysis above still runs either way — it feeds the grade badge in
  # the sidebar, which is visible regardless of which inspector tab is open.
  defp refresh_preview_html(socket, typed) do
    if socket.assigns[:inspector_tab] in [nil, :preview] do
      socket
      |> assign(:preview_html, preview_html(typed))
      |> assign(:preview_stale, false)
    else
      assign(socket, :preview_stale, true)
    end
  end

  defp refresh_body_stats(socket, typed) do
    # The claim rules are part of the digest, not just the blocks: the body
    # scan is memoized here, so switching claim checking on (or editing the
    # rules) while an editor session is open would otherwise leave that session
    # showing the previous scan — or no panel at all — until the author
    # happened to touch the body.
    digest = :erlang.phash2({typed, claim_signature()})

    if digest == socket.assigns[:seo_body_digest] do
      socket
    else
      body = Kiln.Advisory.Body.from_typed(typed)

      socket
      |> assign(:seo_body_digest, digest)
      |> assign(:seo_body_stats, body)
      # Scanning the whole document for every configured claim phrase is body
      # work, so it is memoized here with the rest of it (#377). The short
      # scalar fields are scanned per keystroke in `refresh_seo_report/1` and
      # merged in — see `KilnCMS.Compliance.merge/2`.
      |> assign(:claim_body_matches, scan_claims(body.text))
      |> refresh_link_targets()
    end
  end

  # `%{}` rather than `nil` when nothing matched, so the check can tell "scanned
  # and clean" from "nobody scanned" — which it reports as `:n_a`, because a
  # document nobody checked is not a document that is clean.
  defp scan_claims(text) do
    if KilnCMS.Compliance.enabled?(), do: KilnCMS.Compliance.scan(text), else: nil
  end

  defp claim_signature do
    if KilnCMS.Compliance.enabled?(), do: KilnCMS.Compliance.rules(), else: nil
  end

  # Resolving an internal link is a query per distinct path (#474), so it is
  # keyed on the *set of paths* rather than on the body digest: an author typing
  # a paragraph changes the body constantly and its links almost never. Nothing
  # here runs on a keystroke — `refresh_body_stats/2` has already short-circuited
  # on an unchanged body — and this narrows it further to a changed link set.
  defp refresh_link_targets(socket) do
    paths = socket.assigns.seo_body_stats.internal_link_paths
    locale = link_locale(socket)

    # Keyed on the locale as well as the paths: a link is judged in the locale
    # of the document that holds it, so changing the document's locale changes
    # every answer. Keying on paths alone would leave the panel reporting the
    # old locale's verdicts for the rest of the session.
    if {paths, locale} == socket.assigns[:link_paths] do
      socket
    else
      socket
      |> assign(:link_paths, {paths, locale})
      |> assign(
        :link_targets,
        KilnCMS.Links.Internal.resolve_all(
          paths,
          link_locale(socket),
          org_id(socket.assigns.current_org)
        )
      )
    end
  end

  # The locale a link is judged in: the *form's* value, because that is what
  # `refresh_seo_report/1` hands the analyzer. Reading the saved record's locale
  # instead would resolve links in one locale and report them in another.
  defp link_locale(socket) do
    case socket.assigns.form && AshPhoenix.Form.value(socket.assigns.form, :locale) do
      locale when is_binary(locale) and locale != "" -> locale
      _other -> socket.assigns.record.locale || KilnCMS.I18n.default_locale()
    end
  end

  # Cheap by comparison — the checks compare precomputed facts and a handful of
  # short fields — so this runs on every keystroke while the body walk above
  # only runs on a form change.
  #
  # "Precomputed" is the load-bearing word, and the reason a check must never
  # scan `body.text` itself: that puts full-document string work into every
  # validate, including the ones that only touched the title. `AllCaps` reads
  # `Body.capitalised_runs` for exactly this reason (#495).
  defp refresh_seo_report(socket) do
    form = socket.assigns.form

    fields = %{
      title: form[:title].value,
      slug: form[:slug].value,
      seo_title: form[:seo_title].value,
      seo_description: form[:seo_description].value,
      seo_keywords: form[:seo_keywords].value,
      seo_image: form[:seo_image].value,
      featured_image_id: form[:featured_image_id].value,
      locale: form[:locale].value
    }

    # One registry run, three views (#495, #377). SEO and accessibility overlap
    # heavily — headings, alt text and readability report into both — so
    # running the checks once and splitting the outcomes by lens is the
    # difference between paying for the shared ones once per keystroke and
    # paying twice. Compliance shares no checks with either, but rides the same
    # run rather than opening a second one.
    outcomes =
      KilnCMS.Seo.Analyzer.run(fields, socket.assigns.seo_body_stats,
        facts: %{
          link_targets: socket.assigns[:link_targets] || %{},
          claim_matches: claim_matches(socket, fields)
        }
      )

    body = socket.assigns.seo_body_stats

    socket
    |> assign(:seo_report, outcomes |> Registry.by_lens(:seo) |> Report.from_outcomes(body))
    |> assign(
      :a11y_report,
      outcomes |> Registry.by_lens(:accessibility) |> Report.from_outcomes(body)
    )
    |> assign(
      :compliance_report,
      outcomes |> Registry.by_lens(:compliance) |> Report.from_outcomes(body)
    )
  end

  # The scalar fields that get published as text (#377). Scanned here rather
  # than with the body because they change on every keystroke — but they are a
  # title and two meta fields, so one regex pass over a few hundred bytes, not
  # over the document.
  #
  # Gating them out would leave the panel and the publish gate disagreeing: the
  # gate scans the SEO description, and a claim there is the one that ships to
  # a search results page.
  @claim_scanned_fields [:title, :seo_title, :seo_description]

  defp claim_matches(socket, fields) do
    case socket.assigns[:claim_body_matches] do
      nil ->
        nil

      body_matches ->
        # Each field scanned separately, never joined. Concatenating them
        # invents phrases across the seam — a title ending "…at your own risk"
        # beside an SEO title starting "Free…" would report "risk free", which
        # appears nowhere in the document.
        @claim_scanned_fields
        |> Enum.reduce(body_matches, fn field, acc ->
          fields
          |> Map.get(field)
          |> to_string()
          |> KilnCMS.Compliance.scan()
          |> then(&KilnCMS.Compliance.merge(acc, &1))
        end)
    end
  end

  defp load_versions(socket) do
    opts = [
      actor: socket.assigns.actor,
      # Version twins are tenant-strict (#419) — history reads carry the org.
      tenant: socket.assigns.current_org,
      query: [
        filter: [version_source_id: socket.assigns.record.id],
        sort: [version_inserted_at: :desc],
        limit: 15
      ]
    ]

    versions = list_versions(socket.assigns.kind, opts)

    socket
    |> assign(:versions, versions)
    |> refresh_compare(versions)
  end

  # The record was re-read, so anything derived from it is stale. Two ways that
  # bites an open comparison:
  #
  #   * A picked version can be *gone* — autosave coalescing prunes superseded
  #     snapshots (#32) on every debounced save. Drop the pick, close the
  #     comparison, and say why; silently emptying the panel reads as a bug.
  #   * The "Current draft" side can have *moved* — a pending autosave firing
  #     while the modal is open leaves it describing a document that no longer
  #     exists, which is exactly what `build_compare/2` refuses to do elsewhere.
  #     Recompute rather than close: the editor is mid-read.
  defp refresh_compare(socket, versions) do
    picks = socket.assigns.compare_pick
    live = MapSet.new(versions, & &1.id)
    kept = Enum.filter(picks, &(&1 == @current_pick or MapSet.member?(live, &1)))

    cond do
      kept != picks and socket.assigns.compare ->
        socket
        |> assign(:compare_pick, kept)
        |> assign(:compare, nil)
        |> put_flash(:info, gettext("A version you were comparing was superseded."))

      kept != picks ->
        assign(socket, :compare_pick, kept)

      socket.assigns.compare ->
        case build_compare(socket, picks) do
          {:ok, compare} -> assign(socket, :compare, compare)
          :error -> assign(socket, :compare, nil)
        end

      true ->
        socket
    end
  end

  defp build_form(record, actor) do
    # Blocks are authored as native `Ash.Type.Union` member sub-forms (Kiln v2):
    # each block sub-form is a typed block resource (Heading/Image/…), so fields
    # bind straight to the typed attributes. The update is scoped to the record's
    # own org (epic #336) so a save stays in the site it was loaded from.
    record
    |> ensure_block_ids()
    |> AshPhoenix.Form.for_update(:update,
      actor: actor,
      tenant: record.org_id,
      forms: [auto?: true]
    )
    |> to_form()
  end

  # Backfill a stable id onto any block that reached the editor without one
  # (legacy content predating the uuid_primary_key), so every block can be
  # addressed by identity (picker/move/remove/duplicate carry `bid`).
  defp ensure_block_ids(%{blocks: blocks} = record) when is_list(blocks),
    do: %{record | blocks: Enum.map(blocks, &ensure_block_id/1)}

  defp ensure_block_ids(record), do: record

  defp ensure_block_id(%Ash.Union{value: value} = union),
    do: %{union | value: ensure_block_id(value)}

  defp ensure_block_id(%{id: nil} = block), do: %{block | id: Ash.UUID.generate()}
  defp ensure_block_id(block), do: block

  # The typed block module backing a block sub-form (its union member resource).
  # `inputs_for` yields a Phoenix.HTML.Form wrapping an AshPhoenix.Form; the
  # preview path holds the AshPhoenix.Form directly.
  defp block_member(%Phoenix.HTML.Form{source: source}), do: block_member(source)
  defp block_member(%AshPhoenix.Form{resource: resource}), do: resource

  # --- generic dispatch to the per-kind code interfaces (via the registry) ---

  defp fetch!(kind, id, actor, org) do
    # Scope the load to the current site's org (epic #336) so an editor on one
    # site's subdomain can only open that site's content.
    ContentTypes.get_record!(kind, id,
      actor: actor,
      tenant: org,
      load: [:category, :featured_image, :tags, related_name(kind)]
    )
  end

  # Other content of the same kind, for the "related content" picker. Bounded to
  # the same window as the media picker so a large library can't blow up the mount.
  # Only id + title — these fill a <select>; without the select, 500 siblings
  # would each carry their full blocks JSONB tree in this editor's heap.
  defp siblings(kind, id, actor, org) do
    kind
    |> ContentTypes.list!(
      actor: actor,
      tenant: org,
      query: [select: [:id, :title], sort: [updated_at: :desc], limit: @max_media]
    )
    |> Enum.reject(&(&1.id == id))
    # Recency picks *which* records make the capped window; title orders what
    # the editor then has to scan through.
    |> Enum.sort_by(& &1.title)
  end

  # `<select>` options for the consumer-facing audience (KilnCMS.CMS.Audiences):
  # `{humanized label, atom value}`. The select is only rendered when more than
  # one audience is configured (see the template).
  defp audience_options do
    Enum.map(KilnCMS.CMS.Audiences.all(), &{Phoenix.Naming.humanize(&1), &1})
  end

  # The self-referential m2m relationship/argument names follow the convention
  # `related_<type>s` / `related_<type>_ids`. `to_existing_atom` (rather than
  # interpolating a new atom) keeps this safe even though `kind` originates from
  # a route param — it's already registry-validated, and the atoms are defined
  # at compile time by `KilnCMS.CMS.Content`. Dynamic kinds (string names) all
  # live on the generic entry tier, so they resolve to its `related_entrys`.
  defp related_name(kind), do: String.to_existing_atom("related_#{interface_kind(kind)}s")
  defp related_field(kind), do: String.to_existing_atom("related_#{interface_kind(kind)}_ids")
  defp related_current(kind, record), do: Map.get(record, related_name(kind))

  defp interface_kind(kind) do
    case ContentTypes.get!(kind) do
      %{source: :dynamic} -> :entry
      ct -> ct.type
    end
  end

  # The Yjs fragment key for one rich-text block: its **stable block id**
  # (blocks carry a writable uuid primary key precisely so identity survives
  # reorders, restores and round-trips), so two sessions always bind the same
  # text to the same fragment regardless of block positions. Pre-id legacy
  # blocks (stored before ids existed and not yet backfilled) fall back to the
  # index — the old, positional behavior — until their next save assigns one.
  defp collab_fragment(bf) do
    case bf[:id] && bf[:id].value do
      id when is_binary(id) and id != "" -> "block-#{id}"
      _missing -> "block-idx-#{bf.index}"
    end
  end

  # Socket token for the CRDT collab prototype; nil (and thus no data-collab
  # attributes, no channel) when the flag is off. Mount is editor/admin-gated,
  # so a token only ever reaches an authorized editor.
  defp collab_token(actor) do
    if KilnCMS.Collab.Crdt.enabled?() do
      Phoenix.Token.sign(KilnCMSWeb.Endpoint, "collab", actor.id)
    end
  end

  # A dynamic kind's custom fields are scoped by its TypeDefinition, a compiled
  # kind's by its type atom (see FieldDefinition's two scopes). Resolved and read
  # under the current org (epic #336).
  defp field_definitions(kind, actor, org) do
    case ContentTypes.get!(kind, org_id(org)) do
      %{source: :dynamic, definition: definition} ->
        CMS.field_definitions_for_definition!(definition.id, actor: actor, tenant: org)

      ct ->
        CMS.field_definitions_for!(ct.type, actor: actor, tenant: org)
    end
  end

  # `ContentTypes.get!/2` keys the dynamic-type registry by a raw org_id.
  defp org_id(%{id: id}), do: id
  defp org_id(id) when is_binary(id), do: id

  # Pick-lists for `:reference` custom fields: per definition, the target
  # type's records as `{title, id}` options — narrow select and the same window
  # cap as the media picker, so a large library can't blow up the mount.
  defp reference_options(definitions, actor, org) do
    definitions
    |> Enum.filter(&(&1.field_type == :reference))
    |> Map.new(fn definition ->
      options =
        case ContentTypes.get(definition.target_type, org_id(org)) do
          nil ->
            []

          ct ->
            ct
            |> ContentTypes.list!(
              actor: actor,
              tenant: org,
              query: [select: [:id, :title], sort: [title: :asc], limit: @max_media]
            )
            |> Enum.map(&{&1.title, &1.id})
        end

      {definition.name, options}
    end)
  end

  # Options for the pick-list custom fields; other field types need none.
  defp custom_field_options(%{field_type: :media}, media, _refs),
    do: Enum.map(media, &{&1.filename, &1.id})

  defp custom_field_options(%{field_type: :reference, name: name}, _media, refs),
    do: Map.get(refs, name, [])

  defp custom_field_options(_definition, _media, _refs), do: []

  # Current ids for a (possibly unloaded) relationship list.
  defp current_ids(records) when is_list(records), do: Enum.map(records, & &1.id)
  defp current_ids(_), do: []

  # Selected values for a multi-select: the in-progress form value once the user
  # has touched it, otherwise the record's currently-linked ids. Without this
  # fallback an untouched submit would send an empty list and wipe the links.
  defp selected_ids(form, field, fallback) do
    case form[field].value do
      nil -> fallback
      list when is_list(list) -> list
      other -> [other]
    end
  end

  defp list_versions(kind, opts), do: ContentTypes.list_versions!(kind, opts)

  defp restore_version(kind, record, vid, actor),
    do: ContentTypes.restore_version(kind, record, vid, actor: actor, tenant: record.org_id)

  # ── Version compare (#467) ─────────────────────────────────────────────────

  # Resolves the two picked history entries into snapshots and diffs them.
  #
  # Reads carry the actor, not `authorize?: false`: the diff exposes a version's
  # whole `changes` payload, so it must be gated by the same version read policy
  # as the history list itself (`KilnCMS.CMS.VersionPolicies`). A forbidden read
  # raises rather than quietly diffing a partial history, which would render a
  # confident-looking diff of the wrong document.
  defp build_compare(socket, picks) do
    record = socket.assigns.record
    resource = record.__struct__
    opts = [actor: socket.assigns.actor, tenant: socket.assigns.current_org]

    with [_, _] = resolved <- Enum.map(picks, &resolve_pick(socket, &1)),
         false <- Enum.any?(resolved, &is_nil/1),
         [left, right] <- Enum.sort(resolved, &pick_before?/2),
         {:ok, old, new} <- snapshots(Module.concat(resource, Version), record, left, right, opts) do
      {:ok,
       %{
         diff: VersionDiff.between(old, new, resource),
         left: side(left),
         right: side(right)
       }}
    else
      _unusable -> :error
    end
  rescue
    error ->
      # `:error` level with the stacktrace, not `:warning`: Sentry's logger
      # handler is registered at the default `:error` threshold, so a warning
      # here would make every compare failure — a forbidden read, a broken
      # snapshot, a dead connection — invisible outside the raw prod log.
      Logger.error("version compare failed: #{Exception.format(:error, error, __STACKTRACE__)}")

      :error
  end

  defp resolve_pick(_socket, @current_pick), do: {:current, nil}

  defp resolve_pick(socket, version_id) do
    case Enum.find(socket.assigns.versions, &(&1.id == version_id)) do
      nil -> nil
      version -> {:version, version}
    end
  end

  defp snapshots(version_module, record, {:version, old}, {:version, new}, opts),
    do: VersionSnapshot.pair(version_module, record.id, old, new, opts)

  # The working draft is whatever the record holds now. The editor autosaves on a
  # debounce, so that is the saved state, not the keystroke in flight.
  defp snapshots(version_module, record, {:version, old}, {:current, _}, opts) do
    with {:ok, snapshot} <- VersionSnapshot.at(version_module, record.id, old, opts) do
      {:ok, snapshot, VersionSnapshot.current(record)}
    end
  end

  defp snapshots(_version_module, _record, _left, _right, _opts), do: :error

  # The draft is always the newer side, so a comparison reads before → after.
  # Two saved versions defer to `VersionSnapshot.before?/2` rather than
  # re-deriving the rule — it is the ordering authority for version history, and
  # a second copy here could drift out of agreement with the fold itself.
  defp pick_before?({:current, _}, _right), do: false
  defp pick_before?(_left, {:current, _}), do: true
  defp pick_before?({:version, left}, {:version, right}), do: VersionSnapshot.before?(left, right)

  defp side({:current, _}), do: %{label: gettext("Current draft"), version_id: nil}
  defp side({:version, version}), do: %{label: version_label(version), version_id: version.id}

  defp version_label(version) do
    "#{version.version_action_name} · " <>
      Calendar.strftime(version.version_inserted_at, "%Y-%m-%d %H:%M")
  end

  defp do_workflow(kind, verb, record, actor),
    do: ContentTypes.transition(kind, verb, record, actor: actor, tenant: record.org_id)

  @impl true
  def handle_event("validate", %{"form" => params} = event, socket) do
    # The columns children live in socket state (they aren't bound form inputs);
    # re-inject them so a keystroke's partial params can't wipe the nested tree.
    # GEO item rows (faq/how_to, #357) ARE bound inputs, but arrive as indexed
    # maps — normalize them to the lists their {:array, :map} fields cast.
    params =
      params
      |> inject_children(socket.assigns.block_children)
      |> inject_rich_bodies(socket.assigns.rich_bodies)
      |> normalize_item_rows()
      |> normalize_tag_ids()

    {params, socket} = sync_slug(params, event["_target"], socket)
    socket = assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, params))
    broadcast_preview(socket)
    {:noreply, mark_dirty(socket)}
  end

  # The TipTap hook pushes its document (debounced) instead of mirroring into a
  # form input: AshPhoenix only applies params for fields the rendered form
  # knows (_touched), so a hook-injected input is silently dropped. Convert to
  # Portable Text here and re-validate with the body injected — the same
  # server-held-state pattern as columns children (apply_children/2).
  def handle_event("rich_text_body", %{"doc" => doc} = event, socket) do
    key =
      case event["id"] do
        id when is_binary(id) and id != "" -> id
        _ -> "idx-#{event["idx"]}"
      end

    body = KilnCMS.Blocks.PortableText.from_tiptap(doc)
    rich_bodies = Map.put(socket.assigns.rich_bodies, key, body)

    # A pristine form has no "blocks" params yet — synthesize them from the
    # form's current values (full typed maps) so the injected body has a block
    # list to land in.
    base = AshPhoenix.Form.params(socket.assigns.form)

    base =
      case base["blocks"] do
        nil -> Map.put(base, "blocks", preview_block_maps(socket.assigns.form))
        _ -> base
      end

    params =
      base
      |> inject_children(socket.assigns.block_children)
      |> inject_rich_bodies(rich_bodies)

    {:noreply,
     socket
     |> assign(:rich_bodies, rich_bodies)
     |> assign(:form, AshPhoenix.Form.validate(socket.assigns.form, params))
     |> broadcast_preview_and_refresh()
     |> mark_dirty()}
  end

  # Right inspector rail (Theme A): switch the visible panel. Pure view state —
  # every panel stays mounted, so no form data is touched.
  def handle_event("switch_inspector_tab", %{"tab" => tab}, socket)
      when tab in ~w(settings preview history) do
    socket = assign(socket, :inspector_tab, String.to_existing_atom(tab))

    # Coming back to Preview after edits happened while it was hidden: catch it
    # up now (refresh_preview short-circuits everywhere else while off-tab).
    socket =
      if socket.assigns.inspector_tab == :preview and socket.assigns[:preview_stale] do
        refresh_preview(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  # Unknown/garbled tab value — ignore it rather than crash the editor.
  def handle_event("switch_inspector_tab", _params, socket), do: {:noreply, socket}

  def handle_event("field_focus", %{"field" => field}, socket) do
    broadcast_cursor(socket, field)
    {:noreply, assign(socket, :self_field, field)}
  end

  def handle_event("field_blur", _params, socket) do
    broadcast_cursor(socket, nil)
    {:noreply, assign(socket, :self_field, nil)}
  end

  # Open the media browser to fill a specific image block.
  # Open the media browser to fill a specific existing image block, addressed by
  # its stable id — the block is looked up again at pick time, so a reorder or
  # removal in between can't redirect the image to the wrong block (audit T5.1).
  def handle_event("open_picker", %{"bid" => bid}, socket) when is_binary(bid) and bid != "",
    do: {:noreply, assign(socket, :picking, {:block, bid})}

  def handle_event("open_picker", _params, socket), do: {:noreply, socket}

  # Open the media browser from the editor chrome to insert a *new* image block.
  def handle_event("open_media_browser", _params, socket),
    do: {:noreply, assign(socket, :picking, :new)}

  # Open the (searchable) media browser to choose the featured image (#154),
  # replacing the load-everything <select>.
  def handle_event("open_featured_picker", _params, socket),
    do: {:noreply, assign(socket, :picking, :featured)}

  def handle_event("clear_featured", _params, socket) do
    params = AshPhoenix.Form.params(socket.assigns.form) |> Map.put("featured_image_id", nil)

    {:noreply,
     socket
     |> assign(:form, AshPhoenix.Form.validate(socket.assigns.form, params))
     |> mark_dirty()}
  end

  # Open the media browser to choose the social (og:image) card image (#476),
  # replacing the bare URL box. The text input stays for off-site absolute URLs.
  def handle_event("open_seo_image_picker", _params, socket),
    do: {:noreply, assign(socket, :picking, :seo_image)}

  def handle_event("clear_seo_image", _params, socket),
    do: {:noreply, put_seo_image(socket, nil)}

  # Copy the featured image across rather than making the author pick it twice —
  # it is the fallback delivery would use anyway, made explicit and editable.
  def handle_event("use_featured_image", _params, socket) do
    case featured_image_url(socket) do
      nil -> {:noreply, socket}
      url -> {:noreply, put_seo_image(socket, url)}
    end
  end

  # Ask the configured generator for SEO suggestions (#60). Off unless an
  # operator configured a model; the control isn't rendered otherwise.
  def handle_event("seo_suggest", _params, socket) do
    # Ignore a re-click while a run is in flight: the disabled attribute is
    # client-side only, so a fast double-click (or a replayed event) would
    # otherwise start a second generation and bill for it.
    if socket.assigns.seo_drafting? or not socket.assigns.seo_enabled? do
      {:noreply, socket}
    else
      document = seo_document(socket)
      # The rate-limit bucket keys interpolate this, so it must be the id —
      # `current_org` is the Organization struct (Ash takes it as a tenant, but
      # a struct in a bucket key would blow up on String.Chars).
      org_id = org_id(socket.assigns.current_org)
      actor_id = socket.assigns.actor.id
      # Stamped so a result that lands after a conflict reload or a version
      # restore (both bump `editor_version`) can be recognized as stale.
      version = socket.assigns.editor_version

      {:noreply,
       socket
       |> assign(:seo_drafting?, true)
       # Clear the previous proposal, not just the dismissed set: emptying
       # `seo_dismissed` alone would re-render the *old* cards for the length of
       # the call (and permanently if it fails), letting "Use all" clobber
       # fields the author has since accepted and hand-edited.
       |> clear_seo_suggestions()
       |> start_async(:seo_draft, fn ->
         # Captures plain data only — never the socket or the form struct,
         # both of which are stale the moment an autosave rebuilds the form.
         {version, KilnCMS.Seo.draft(document, org_id: org_id, user_id: actor_id)}
       end)}
    end
  end

  # Load internal-link suggestions the first time the panel is opened. Repeat
  # opens reuse what's already there — the author can refresh explicitly.
  def handle_event("seo_links_refresh", _params, socket) do
    if socket.assigns.seo_links_loading?,
      do: {:noreply, socket},
      else: {:noreply, load_link_suggestions(socket)}
  end

  # The `Clipboard` JS hook pushes this after a successful copy. Without a
  # clause here the push would crash the LiveView — the hook predates this
  # view, so it had no handler until now.
  def handle_event("copied", _params, socket),
    do: {:noreply, put_flash(socket, :info, gettext("Copied to clipboard."))}

  def handle_event("seo_dismiss", %{"field" => field}, socket),
    do:
      {:noreply, assign(socket, :seo_dismissed, MapSet.put(socket.assigns.seo_dismissed, field))}

  def handle_event("seo_dismiss_all", _params, socket),
    do: {:noreply, socket |> assign(:seo_drafts, nil) |> assign(:seo_dismissed, MapSet.new())}

  def handle_event("seo_accept", %{"field" => field}, socket) do
    {socket, outcome} = apply_suggestion(socket, field)
    {:noreply, flash_outcomes(socket, [{field, outcome}])}
  end

  def handle_event("seo_accept_all", _params, socket) do
    # Only the cards still on screen. `suggested_fields/1` alone would also
    # re-apply fields the author already accepted (and possibly hand-edited)
    # or explicitly dismissed.
    {socket, outcomes} =
      socket
      |> pending_suggestions()
      |> Enum.reduce({socket, []}, fn field, {acc, outcomes} ->
        {acc, outcome} = apply_suggestion(acc, field)
        {acc, [{field, outcome} | outcomes]}
      end)

    {:noreply, flash_outcomes(socket, Enum.reverse(outcomes))}
  end

  # ── Block-level AI assist (#60) ───────────────────────────────────────────
  #
  # Two rules hold for every clause below.
  #
  # First, anything that can reach the provider or write to the document
  # re-checks `assist_enabled?` and the edit guards. The controls aren't
  # rendered when the feature is off, but "not rendered" is a client-side fact
  # and these are plain pushed events. (The panel-state clauses — close,
  # action, instruction, dismiss — deliberately don't: they only move socket
  # state that nothing renders while the feature is off, and guarding them
  # would suggest they were a boundary.)
  #
  # Second, every clause has a catch-all behind it. A pushed event missing its
  # key would otherwise raise FunctionClauseError, which takes the LiveView —
  # and the author's unsaved work — down with it.

  def handle_event("assist_open", %{"bid" => block_id}, socket)
      when is_binary(block_id) and block_id != "" do
    if socket.assigns.assist_enabled? do
      # `close_assist/1` rather than three inline assigns: the previous block's
      # suggestion describes content this block doesn't contain, and its Insert
      # button would put it somewhere it was never generated for. Sharing the
      # reset means a later assign can't be dropped from one path only.
      {:noreply, socket |> close_assist() |> assign(:assist_block, block_id)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("assist_open", _params, socket), do: {:noreply, socket}

  def handle_event("assist_close", _params, socket), do: {:noreply, close_assist(socket)}

  def handle_event("assist_action", %{"action" => action}, socket) do
    case KilnCMS.Assist.Action.fetch(action) do
      {:ok, %{id: id}} -> {:noreply, assign(socket, :assist_action, id)}
      # Never mints an atom from the pushed string; an unknown id is simply
      # ignored rather than becoming a selected action nothing can render.
      :error -> {:noreply, socket}
    end
  end

  def handle_event("assist_action", _params, socket), do: {:noreply, socket}

  # The instruction box lives inside the main content <form>, so LiveView
  # serializes that form alongside it. Only this one top-level key is read —
  # `validate` owns everything under "form" and is not fired by this binding.
  def handle_event("assist_instruction", params, socket) do
    instruction =
      case params["assist_instruction"] do
        # Clamped *here*, not only in `Request.new/1`. That clamp bounds what
        # reaches the provider; this bounds what the server holds. Without it a
        # crafted push parks an arbitrarily large string in socket assigns for
        # the life of the session — `maxlength` on the input is client-side.
        value when is_binary(value) ->
          value |> String.slice(0, KilnCMS.Assist.max_instruction_chars()) |> String.trim()

        _ ->
          ""
      end

    {:noreply,
     assign(socket, :assist_instruction, if(instruction == "", do: nil, else: instruction))}
  end

  def handle_event("assist_run", %{"bid" => block_id}, socket) when is_binary(block_id) do
    # Ignore a re-click while a run is in flight: the disabled attribute is
    # client-side only, so a fast double-click (or a replayed event) would
    # otherwise start a second generation and bill for it. The block id must
    # match the open panel, and must actually name a block on this form —
    # an unknown id degrades to an empty passage, which `:draft` accepts, so
    # without this check a crafted push buys a billed generation for nothing.
    if assist_runnable?(socket, block_id) do
      request = assist_request(socket, block_id)
      org_id = org_id(socket.assigns.current_org)
      actor_id = socket.assigns.actor.id
      version = socket.assigns.editor_version

      {:noreply,
       socket
       |> assign(:assist_running?, true)
       |> assign(:assist_result, nil)
       |> start_async(:assist, fn ->
         # Captures plain data only — never the socket or the form struct,
         # both of which are stale the moment an autosave rebuilds the form.
         {version, block_id, KilnCMS.Assist.run(request, org_id: org_id, user_id: actor_id)}
       end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("assist_run", _params, socket), do: {:noreply, socket}

  def handle_event("assist_dismiss", _params, socket),
    do: {:noreply, assign(socket, :assist_result, nil)}

  # Hand the suggestion to the block's TipTap editor as a client-side command.
  #
  # Deliberately NOT a server-side write to the block tree: rich text lives
  # under `phx-update="ignore"` with a shared Y.Doc, so writing prose into the
  # form here would force the document back into the editor, discarding the
  # author's cursor and undo stack and desynchronizing collaborators. The hook
  # applies it as an ordinary editor transaction — undoable, and correct under
  # collaboration — then pushes the new body back the usual way.
  def handle_event("assist_apply", %{"mode" => mode}, socket)
      when mode in ~w(insert replace) do
    case {socket.assigns.assist_result, socket.assigns.assist_block} do
      {%KilnCMS.Assist.Suggestion{} = suggestion, block_id} when is_binary(block_id) ->
        apply_assist(socket, block_id, mode, suggestion)

      _ ->
        {:noreply, socket}
    end
  end

  # A mode outside insert/replace is ignored, not left to fall through.
  def handle_event("assist_apply", _params, socket), do: {:noreply, socket}

  # ── Block-level editorial comments (#404) ───────────────────────────────────
  #
  # One thread per block; `RouteToBlockThread` on the resource is what makes
  # that true regardless of caller, so nothing here has to track which comment
  # is a reply to which — only ever "add a comment to this block" and "resolve
  # this block's thread". `comment_draft` is synced the same way
  # `assist_instruction` is: this panel sits inside the main content `<.form>`,
  # which can't nest another `<form>`, so the textarea keeps its own
  # unprefixed `phx-change` and the Send button reads the synced assign rather
  # than anything in the click event.

  def handle_event("comment_open", %{"bid" => block_id}, socket)
      when is_binary(block_id) and block_id != "" do
    {:noreply, socket |> close_comment_panel() |> assign(:comment_block, block_id)}
  end

  def handle_event("comment_open", _params, socket), do: {:noreply, socket}

  def handle_event("comment_close", _params, socket), do: {:noreply, close_comment_panel(socket)}

  def handle_event("comment_draft", params, socket) do
    {:noreply, assign(socket, :comment_draft, params["comment_body"])}
  end

  def handle_event("comment_add", %{"bid" => block_id}, socket)
      when is_binary(block_id) and block_id != "" do
    body = socket.assigns.comment_draft

    if is_binary(body) and String.trim(body) != "" do
      case CMS.add_comment(
             %{
               content_type: to_string(socket.assigns.kind),
               content_id: socket.assigns.record.id,
               block_id: block_id,
               body: body
             },
             actor: socket.assigns.actor,
             tenant: socket.assigns.current_org
           ) do
        {:ok, _comment} ->
          {:noreply, socket |> reload_comments() |> assign(:comment_draft, nil)}

        {:error, _error} ->
          {:noreply, put_flash(socket, :error, gettext("Couldn't add comment."))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("comment_add", _params, socket), do: {:noreply, socket}

  def handle_event("comment_resolve", %{"id" => id}, socket),
    do: resolve_comment_thread(socket, id, :resolve_comment)

  def handle_event("comment_unresolve", %{"id" => id}, socket),
    do: resolve_comment_thread(socket, id, :unresolve_comment)

  # ── Editorial tasks (#501) ───────────────────────────────────────────────
  def handle_event("task_assign_open", _params, socket),
    do: {:noreply, socket |> assign(:task_assign_open?, true) |> assign(:task_draft, %{})}

  def handle_event("task_assign_close", _params, socket),
    do: {:noreply, socket |> assign(:task_assign_open?, false) |> assign(:task_draft, %{})}

  def handle_event("task_draft_change", %{"task_assignee_id" => v}, socket),
    do: {:noreply, put_task_draft(socket, "assignee_id", v)}

  def handle_event("task_draft_change", %{"task_due_on" => v}, socket),
    do: {:noreply, put_task_draft(socket, "due_on", v)}

  def handle_event("task_draft_change", %{"task_note" => v}, socket),
    do: {:noreply, put_task_draft(socket, "note", v)}

  def handle_event("task_draft_change", _params, socket), do: {:noreply, socket}

  def handle_event("task_assign_submit", _params, socket) do
    draft = socket.assigns.task_draft

    attrs = %{
      content_type: to_string(socket.assigns.kind),
      content_id: socket.assigns.record.id,
      assignee_id: draft["assignee_id"],
      due_on: blank_to_nil(draft["due_on"]),
      note: blank_to_nil(draft["note"])
    }

    case CMS.assign_task(attrs, actor: socket.assigns.actor, tenant: socket.assigns.current_org) do
      {:ok, _task} ->
        {:noreply,
         socket
         |> reload_tasks()
         |> assign(:task_assign_open?, false)
         |> assign(:task_draft, %{})}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't assign that task."))}
    end
  end

  # No `<form>` for any of this — see `release_panel/1`. Each control carries its
  # own `phx-change` into `@release_draft`; the button is a plain `phx-click`.
  def handle_event("release_draft_change", %{"release_target" => v}, socket),
    do: {:noreply, put_release_draft(socket, "release_id", v)}

  def handle_event("release_draft_change", %{"release_action" => v}, socket),
    do: {:noreply, put_release_draft(socket, "action", v)}

  def handle_event("release_draft_change", _params, socket), do: {:noreply, socket}

  def handle_event("release_add", _params, socket) do
    draft = socket.assigns.release_draft
    release_id = draft["release_id"] || default_release_id(socket)

    attrs = %{
      release_id: release_id,
      content_type: to_string(socket.assigns.kind),
      content_id: socket.assigns.record.id,
      action: release_action(draft["action"])
    }

    case CMS.add_release_item(attrs,
           actor: socket.assigns.actor,
           tenant: socket.assigns.current_org
         ) do
      {:ok, _item} ->
        {:noreply,
         socket
         |> reload_release_state()
         |> put_flash(:info, gettext("Added to the release."))}

      # The reason matters here in a way it doesn't for most adds — "already in
      # another open release", "outside your content-type scope" and "release is
      # full" are all things the editor can act on.
      {:error, error} ->
        {:noreply, put_flash(socket, :error, release_error_message(error))}
    end
  end

  def handle_event("release_remove", _params, socket) do
    case socket.assigns.release_item do
      nil ->
        {:noreply, socket}

      item ->
        case CMS.cancel_release_item(item, %{},
               actor: socket.assigns.actor,
               tenant: socket.assigns.current_org
             ) do
          {:ok, _} ->
            {:noreply,
             socket
             |> reload_release_state()
             |> put_flash(:info, gettext("Removed from the release."))}

          {:error, _} ->
            {:noreply,
             put_flash(socket, :error, gettext("Couldn't remove it from that release."))}
        end
    end
  end

  def handle_event("task_complete", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.tasks, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      task ->
        case CMS.complete_task(task, %{}, actor: socket.assigns.actor) do
          {:ok, _task} ->
            {:noreply, reload_tasks(socket)}

          {:error, _error} ->
            {:noreply, put_flash(socket, :error, gettext("Couldn't update that task."))}
        end
    end
  end

  # The gallery's picker is multi-select (#482): a gallery is built from several
  # images at once, and re-opening a drawer per image turns "add these eight" into
  # eight round trips through a modal.
  def handle_event("open_gallery_picker", %{"bid" => bid}, socket)
      when is_binary(bid) and bid != "",
      do: {:noreply, socket |> assign(:picking, {:gallery, bid}) |> assign(:picked, [])}

  def handle_event("open_gallery_picker", _params, socket), do: {:noreply, socket}

  # Selection is an ordered list, not a set: the order images are clicked is the
  # order they land in the gallery, which is the least surprising thing a
  # multi-select can do and saves a reorder afterwards.
  def handle_event("toggle_pick", %{"id" => id, "url" => url}, socket) do
    picked = socket.assigns.picked

    picked =
      if Enum.any?(picked, &(&1.id == id)),
        do: Enum.reject(picked, &(&1.id == id)),
        else: picked ++ [%{id: id, url: url}]

    {:noreply, assign(socket, :picked, picked)}
  end

  def handle_event("add_picked_images", %{"bid" => bid}, socket) do
    case socket.assigns.picked do
      [] ->
        {:noreply, reset_picker(socket)}

      picked ->
        # Alt is left blank deliberately rather than seeded from the library
        # item: `MediaItem.alt` is the library-wide description, and what ships
        # is the block's own. Pre-filling it would make a per-placement
        # description look already written, and the publish gate (#403) is what
        # asks for it — better it asks than that a stale default sails past.
        rows = for image <- picked, do: %{"url" => image.url, "media_id" => image.id, "alt" => ""}

        {:noreply, socket} = update_gallery_images(socket, bid, &(&1 ++ rows))
        {:noreply, reset_picker(socket)}
    end
  end

  def handle_event("close_picker", _params, socket),
    do: {:noreply, reset_picker(socket)}

  # Live-filter the browser grid as the user types.
  def handle_event("search_media", %{"q" => q}, socket) do
    results =
      if q == "",
        do: nil,
        else: search_media(q, socket.assigns.actor, socket.assigns.current_org)

    {:noreply, socket |> assign(:media_query, q) |> assign(:picker_media, results)}
  end

  # Set the social card image from the library (#476).
  def handle_event("pick_image", %{"index" => "seo_image", "url" => url}, socket),
    do: {:noreply, socket |> put_seo_image(url) |> reset_picker()}

  # Set the featured image from the library (#154).
  def handle_event("pick_image", %{"index" => "featured", "id" => media_id}, socket) do
    params = AshPhoenix.Form.params(socket.assigns.form) |> Map.put("featured_image_id", media_id)

    {:noreply,
     socket
     |> assign(:form, AshPhoenix.Form.validate(socket.assigns.form, params))
     |> reset_picker()
     |> mark_dirty()}
  end

  # Insert a library image as a brand-new image block (browser opened from the
  # editor chrome): the URL becomes the block content and its id is stashed in
  # `data` so delivery can build srcset.
  def handle_event("pick_image", %{"index" => "new", "id" => media_id, "url" => url}, socket) do
    form =
      AshPhoenix.Form.add_form(socket.assigns.form, socket.assigns.form.name <> "[blocks]",
        params: %{
          "_union_type" => "image",
          "id" => Ash.UUID.generate(),
          "url" => url,
          "media_id" => media_id
        }
      )

    socket = socket |> assign(:form, form) |> reset_picker()
    broadcast_preview(socket)
    {:noreply, mark_dirty(socket)}
  end

  # Fill the existing image block identified by `bid`. Its current position is
  # resolved from the live form now, not captured when the picker opened, so a
  # concurrent reorder/removal can't misdirect the image (audit T5.1).
  def handle_event("pick_image", %{"index" => "block", "bid" => bid} = p, socket) do
    %{"id" => media_id, "url" => url} = p

    case block_index_by_id(socket.assigns.form, bid) do
      nil ->
        # The target block is gone (removed by a co-editor) — drop the pick.
        {:noreply, reset_picker(socket)}

      index ->
        # Rebuild the FULL block set from the live form (each block as an input
        # map keyed by its stable id), then merge the image into the target. A
        # pristine form's `params` carries no blocks at all, so a partial update
        # would drop every other block — this carries them all through, ids intact
        # (the same full-set pattern the inline preview + in-context editor use).
        blocks =
          socket.assigns.form
          |> full_blocks_input()
          |> List.update_at(index, &Map.merge(&1, %{"url" => url, "media_id" => media_id}))

        params =
          socket.assigns.form
          |> AshPhoenix.Form.params()
          |> Map.put("blocks", blocks)

        socket = socket |> revalidate(params) |> reset_picker()
        broadcast_preview(socket)
        {:noreply, mark_dirty(socket)}
    end
  end

  # Open the file-library drawer to fill a specific `:file` block (#481).
  # Mirrors `open_picker`/"pick_image" for images, but a distinct assign
  # (`@file_picking`) rather than reusing `@picking` — the two libraries
  # (`@media` images-only, `@file_media` documents-only, see mount) are
  # filtered opposites of each other, so one picker component can't serve
  # both without threading a mode flag through every existing `@picking`
  # match in this module.
  def handle_event("open_file_picker", %{"bid" => bid}, socket) when is_binary(bid) and bid != "",
    do: {:noreply, assign(socket, :file_picking, bid)}

  def handle_event("open_file_picker", _params, socket), do: {:noreply, socket}

  def handle_event("close_file_picker", _params, socket), do: {:noreply, reset_picker(socket)}

  # Live-filter the file-picker grid as the user types.
  def handle_event("search_file_media", %{"q" => q}, socket) do
    results =
      if q == "",
        do: nil,
        else: search_media(q, socket.assigns.actor, socket.assigns.current_org, :file)

    {:noreply, socket |> assign(:file_query, q) |> assign(:picker_files, results)}
  end

  # Fill the file block identified by `@file_picking` from the library.
  # `content_type`/`byte_size`/`filename` are looked up server-side from the
  # actor-authorized `MediaItem` rather than trusted from the click payload —
  # denormalizing a client-supplied size/type onto the block would let it
  # display something that doesn't match what `MediaDownloadController`
  # actually serves. A direct `get_media_item` here, not a lookup in
  # `@file_media`/`@picker_files`: a search result outside the mounted
  # window lives ONLY in `@picker_files`, and an id present in neither list
  # (a stale click, or a co-editor's concurrent delete) must still resolve
  # correctly rather than silently no-op.
  def handle_event("pick_file", %{"id" => media_id}, socket) do
    bid = socket.assigns.file_picking
    actor = socket.assigns.actor
    org = socket.assigns.current_org

    with {:ok, item} <- CMS.get_media_item(media_id, actor: actor, tenant: org),
         index when not is_nil(index) <- block_index_by_id(socket.assigns.form, bid) do
      blocks =
        socket.assigns.form
        |> full_blocks_input()
        |> List.update_at(
          index,
          &Map.merge(&1, %{
            "media_id" => item.id,
            "filename" => item.filename,
            "content_type" => item.content_type,
            "byte_size" => item.byte_size
          })
        )

      params = socket.assigns.form |> AshPhoenix.Form.params() |> Map.put("blocks", blocks)

      socket = socket |> revalidate(params) |> reset_picker()
      broadcast_preview(socket)
      {:noreply, mark_dirty(socket)}
    else
      _ -> {:noreply, reset_picker(socket)}
    end
  end

  # Open the A/V drawer to fill one field pair of a video/audio block (#494).
  #
  # `field` distinguishes the three things a video block picks from a library:
  # the video itself, its poster image, and its WebVTT caption track. They
  # need three different libraries (`:av`, `:image`, `:captions`) and write
  # three different field pairs, so the target is `{block_id, field}` — one
  # drawer parameterized, rather than three near-identical copies of the
  # `@file_picking` machinery.
  def handle_event("open_av_picker", %{"bid" => bid, "field" => field}, socket)
      when is_binary(bid) and bid != "" and field in ~w(media poster captions) do
    {:noreply, assign(socket, :av_picking, {bid, field})}
  end

  def handle_event("open_av_picker", _params, socket), do: {:noreply, socket}

  def handle_event("close_av_picker", _params, socket), do: {:noreply, reset_picker(socket)}

  # Live-filter the A/V picker grid as the user types, against whichever
  # library the open target wants.
  def handle_event("search_av_media", %{"q" => q}, socket) do
    results =
      if q == "",
        do: nil,
        else:
          search_media(
            q,
            socket.assigns.actor,
            socket.assigns.current_org,
            av_picker_kind(socket.assigns.av_picking)
          )

    {:noreply, socket |> assign(:av_query, q) |> assign(:picker_av, results)}
  end

  # Fill the field pair identified by `@av_picking`. Everything denormalized
  # onto the block is read server-side from the actor-authorized `MediaItem`,
  # never trusted from the click payload — same reasoning as `pick_file`, and
  # the same direct `get_media_item` rather than a lookup in the mounted list
  # (a search result outside the mounted window lives only in `@picker_av`).
  def handle_event("pick_av", %{"id" => media_id}, socket) do
    with {bid, field} <- socket.assigns.av_picking,
         {:ok, item} <-
           CMS.get_media_item(media_id,
             actor: socket.assigns.actor,
             tenant: socket.assigns.current_org
           ),
         index when not is_nil(index) <- block_index_by_id(socket.assigns.form, bid) do
      blocks =
        socket.assigns.form
        |> full_blocks_input()
        |> List.update_at(index, &Map.merge(&1, av_block_patch(field, item)))

      params = socket.assigns.form |> AshPhoenix.Form.params() |> Map.put("blocks", blocks)

      socket = socket |> revalidate(params) |> reset_picker()
      broadcast_preview(socket)
      {:noreply, mark_dirty(socket)}
    else
      _ -> {:noreply, reset_picker(socket)}
    end
  end

  # A columns block carries a socket-managed child tree, so it's inserted with a
  # stable id (seeded into `block_children`) and a default two-column layout.
  # `after` (a block id, "start", or absent) positions the new block (B2).
  def handle_event("add_block", %{"type" => "columns"} = p, socket) do
    id = Ash.UUID.generate()
    cols = [%{"blocks" => []}, %{"blocks" => []}]

    form =
      socket.assigns.form
      |> AshPhoenix.Form.add_form(socket.assigns.form.name <> "[blocks]",
        params: %{"_union_type" => "columns", "id" => id, "columns" => cols}
      )
      |> position_new_block(p["after"])

    socket =
      socket
      |> assign(:form, form)
      |> assign(:block_children, Map.put(socket.assigns.block_children, id, cols))

    broadcast_preview(socket)
    {:noreply, socket |> refresh_preview() |> mark_dirty()}
  end

  def handle_event("add_block", %{"type" => type} = p, socket) do
    # Every block carries a stable id from the moment it's added, so the picker,
    # delete, and keyboard-move can address it by identity rather than by a
    # position that a concurrent reorder can invalidate (audit T5.1/T5.2). The
    # optional `after` anchor lets it land inline rather than only at the end (B2).
    form =
      socket.assigns.form
      |> AshPhoenix.Form.add_form(socket.assigns.form.name <> "[blocks]",
        params: %{"_union_type" => type, "id" => Ash.UUID.generate()}
      )
      |> position_new_block(p["after"])

    socket = assign(socket, :form, form)
    broadcast_preview(socket)
    {:noreply, socket |> refresh_preview() |> mark_dirty()}
  end

  # Duplicate the block with stable id `bid`: copy its full field set, give the
  # copy (and, for a columns block, its nested children) fresh ids, and drop it in
  # right after the original.
  def handle_event("duplicate_block", %{"bid" => bid}, socket) do
    case Enum.find(
           full_blocks_input(socket.assigns.form),
           &(to_string(&1["id"]) == to_string(bid))
         ) do
      nil ->
        {:noreply, socket}

      source ->
        new_id = Ash.UUID.generate()
        copy = Map.put(source, "id", new_id)
        children = dup_children(socket.assigns.block_children[bid])

        form =
          socket.assigns.form
          |> AshPhoenix.Form.add_form(socket.assigns.form.name <> "[blocks]", params: copy)
          |> position_new_block(bid)

        block_children =
          if children,
            do: Map.put(socket.assigns.block_children, new_id, children),
            else: socket.assigns.block_children

        socket = socket |> assign(:form, form) |> assign(:block_children, block_children)

        # Re-inject the copy's fresh-id children into the form params now, so a draft
        # autosave firing before the next validate persists the duplicate's own
        # children rather than the original's (do_autosave submits raw params).
        socket = revalidate(socket, AshPhoenix.Form.params(socket.assigns.form))
        broadcast_preview(socket)

        {:noreply, socket |> refresh_preview() |> mark_dirty()}
    end
  end

  # No `bid` (a block that reached the editor without a stable id) — no-op rather
  # than crash the session (audit theme 4). ensure_block_ids/1 backfills on load,
  # so this is defence in depth.
  def handle_event("duplicate_block", _params, socket), do: {:noreply, socket}

  # ── GEO item rows (faq items / how_to steps, #357) ──────────────────────────
  # Rows are bound form inputs; add/remove mutate the form params directly (the
  # same targeted-update pattern as `pick_image` at an index), so there's no
  # parallel socket state to keep in sync.

  def handle_event("item_row_add", %{"index" => index, "field" => field}, socket)
      when field in @row_fields do
    update_item_rows(socket, index, field, &(&1 ++ [%{}]))
  end

  def handle_event(
        "item_row_remove",
        %{"index" => index, "field" => field, "item" => item},
        socket
      )
      when field in @row_fields do
    update_item_rows(socket, index, field, &List.delete_at(&1, to_int(item)))
  end

  # ── gallery image rows (#482) ───────────────────────────────────────────────

  def handle_event("gallery_remove", %{"bid" => bid, "item" => item}, socket) do
    update_gallery_images(socket, bid, &List.delete_at(&1, to_int(item)))
  end

  def handle_event("gallery_move", %{"bid" => bid, "item" => item, "dir" => dir}, socket) do
    from = to_int(item)
    to = if dir == "up", do: from - 1, else: from + 1

    update_gallery_images(socket, bid, fn images ->
      # BOTH ends checked. `to_int/1` accepts a negative, and `Enum.at(images,
      # -1)` is the last row rather than an error — so an unchecked `from` moves
      # the wrong image, and one past the end inserts a `nil` into an
      # `{:array, :map}` the resource refuses to save.
      bounds = 0..(length(images) - 1)//1

      if from in bounds and to in bounds do
        moved = Enum.at(images, from)
        images |> List.delete_at(from) |> List.insert_at(to, moved)
      else
        images
      end
    end)
  end

  # The client reports the new order as a list of the *previous* row indices,
  # and the server rebuilds from those — never from row content, which the
  # client could have edited between the drag and the event.
  def handle_event("gallery_reorder", %{"bid" => bid, "order" => order}, socket)
      when is_list(order) do
    update_gallery_images(socket, bid, fn images ->
      # Deduped and rejected by INDEX, never by value. Two rows pointing at the
      # same media item are identical maps, so matching on the map itself
      # collapses them into one and then drops both from the tail — a drag on a
      # gallery holding one image twice would silently delete a copy.
      indices =
        order
        |> Enum.map(&to_int/1)
        |> Enum.filter(&(&1 in 0..(length(images) - 1)//1))
        |> Enum.uniq()

      # Any row the client failed to mention keeps its place at the end rather
      # than being dropped: a stale or partial order must not delete images.
      unmentioned = Enum.reject(0..(length(images) - 1)//1, &(&1 in indices))

      for index <- indices ++ Enum.to_list(unmentioned), do: Enum.at(images, index)
    end)
  end

  def handle_event("gallery_reorder", _params, socket), do: {:noreply, socket}

  # Remove the block with stable id `bid`. Resolving the id to a path now (rather
  # than trusting a path captured at render) means an in-flight reorder can't turn
  # a delete click into a delete of the wrong block (audit T5.2).
  def handle_event("remove_block", %{"bid" => bid}, socket) do
    case block_index_by_id(socket.assigns.form, bid) do
      nil ->
        {:noreply, socket}

      index ->
        path = "#{socket.assigns.form.name}[blocks][#{index}]"

        {:noreply,
         socket
         |> assign(:form, AshPhoenix.Form.remove_form(socket.assigns.form, path))
         |> prune_block_children()
         |> mark_dirty()}
    end
  end

  def handle_event("remove_block", _params, socket), do: {:noreply, socket}

  def handle_event("reorder", %{"order" => order}, socket) do
    form = AshPhoenix.Form.sort_forms(socket.assigns.form, [:blocks], order)
    {:noreply, socket |> assign(:form, form) |> mark_dirty()}
  end

  # Keyboard-accessible alternative to drag-and-drop reordering (#171): swap a
  # block with its neighbour and announce the new position to screen readers.
  # The moved block is identified by its stable id and resolved to a live index
  # here, so the swap can't act on the wrong block after a reorder (T4.3/T5.2).
  def handle_event("move_block", %{"bid" => bid, "dir" => dir}, socket) do
    count = blocks_count(socket.assigns.form)

    # Bounds-check BOTH ends: an unknown id no-ops, and a source at either edge
    # can't wrap to the opposite end via Enum.at/-1 (audit T4.3).
    with i when is_integer(i) <- block_index_by_id(socket.assigns.form, bid),
         true <- i < count,
         j when j >= 0 and j < count <- if(dir == "up", do: i - 1, else: i + 1) do
      order = 0..(count - 1) |> Enum.map(&to_string/1) |> swap_at(i, j)
      form = AshPhoenix.Form.sort_forms(socket.assigns.form, [:blocks], order)

      {:noreply,
       socket
       |> assign(:form, form)
       |> mark_dirty()
       |> assign(
         :moved_announcement,
         gettext("Moved block to position %{pos} of %{count}", pos: j + 1, count: count)
       )}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("move_block", _params, socket), do: {:noreply, socket}

  # ── columns container editing (#335) ────────────────────────────────────────
  # These mutate the socket-managed child tree of a `columns` block, then re-sync
  # it into the form (so the live preview + save reflect it). Blocks and columns
  # are addressed by their stable ids; nothing here relies on positional indices
  # surviving a concurrent reorder.

  def handle_event("col_add_child", %{"id" => id, "col" => col, "type" => type}, socket)
      when type in @nested_child_types do
    # Address the target column by a real index; a garbled `col` no-ops rather
    # than silently landing the child in column 0 (the old `to_int` fallback).
    case parse_index(col) do
      {:ok, ci} ->
        bc = update_column(socket.assigns.block_children, id, ci, &append_child(&1, type))
        {:noreply, apply_children(socket, bc)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("col_remove_child", %{"id" => id, "child" => child_id}, socket) do
    bc =
      update_columns(socket.assigns.block_children, id, fn blocks ->
        Enum.reject(blocks, &(&1["id"] == child_id))
      end)

    {:noreply, apply_children(socket, bc)}
  end

  def handle_event(
        "col_update_child",
        %{"id" => id, "child" => child_id, "field" => field} = p,
        socket
      ) do
    value = Map.get(p, "value", "")

    bc =
      update_columns(socket.assigns.block_children, id, fn blocks ->
        Enum.map(blocks, &maybe_put_field(&1, child_id, field, value))
      end)

    {:noreply, apply_children(socket, bc)}
  end

  # Nested SortableJS drop: `cols` is the new child-id order of every column of
  # this block. Rebuild each column from the flat id→child map so a child can
  # move within or across the block's columns without losing its edits.
  def handle_event("col_reorder", %{"id" => id, "cols" => cols}, socket) when is_list(cols) do
    bc = Map.update(socket.assigns.block_children, id, [], &rebuild_columns(&1, cols))
    {:noreply, apply_children(socket, bc)}
  end

  def handle_event("col_add_column", %{"id" => id}, socket) do
    bc =
      Map.update(socket.assigns.block_children, id, [%{"blocks" => []}], fn cols ->
        if length(cols) >= @max_columns, do: cols, else: cols ++ [%{"blocks" => []}]
      end)

    {:noreply, apply_children(socket, bc)}
  end

  def handle_event("col_remove_column", %{"id" => id, "col" => col}, socket) do
    case parse_index(col) do
      {:ok, ci} ->
        bc = Map.update(socket.assigns.block_children, id, [], &drop_column(&1, ci))
        {:noreply, apply_children(socket, bc)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("save", %{"form" => params}, socket) do
    socket = cancel_autosave_timer(socket)

    params =
      params
      |> inject_children(socket.assigns.block_children)
      |> inject_rich_bodies(socket.assigns.rich_bodies)
      |> normalize_item_rows()
      |> normalize_tag_ids()

    result =
      EditorTelemetry.span(:save, %{kind: socket.assigns.kind}, fn ->
        AshPhoenix.Form.submit(socket.assigns.form, params: params)
      end)

    case result do
      {:ok, record} ->
        # Re-fetch so the relationship pickers reflect the saved links (the
        # submit result doesn't carry loaded relationships).
        reloaded =
          fetch!(socket.assigns.kind, record.id, socket.assigns.actor, socket.assigns.current_org)

        {:noreply,
         socket
         |> assign_record(reloaded)
         |> assign(:save_state, :saved)
         |> put_flash(:info, gettext("Saved."))}

      {:error, form} ->
        if stale_conflict?(form) do
          {:noreply, flag_conflict(socket)}
        else
          {:noreply,
           socket
           |> assign(:form, form)
           |> put_flash(:error, gettext("Please fix the errors below."))}
        end
    end
  end

  # Discard local changes and reload the latest saved version, clearing the
  # conflict. (The simplest safe resolution — a merge UI is future work.)
  def handle_event("reload_conflict", _params, socket) do
    record =
      fetch!(
        socket.assigns.kind,
        socket.assigns.record.id,
        socket.assigns.actor,
        socket.assigns.current_org
      )

    {:noreply,
     socket
     |> assign_record(record)
     |> reset_editors()
     |> assign(:conflict, false)
     |> assign(:save_state, :saved)
     |> put_flash(:info, gettext("Reloaded the latest version."))}
  end

  def handle_event("workflow", %{"action" => action}, socket) do
    {:noreply, run_workflow(socket, action)}
  end

  # One-click translation: duplicate this record's content into a new draft in
  # the target locale and jump to its editor.
  def handle_event("create_translation", %{"locale" => locale}, socket) do
    %{kind: kind, record: record, actor: actor} = socket.assigns

    translation =
      KilnCMS.CMS.Translations.create_translation!(kind, record, locale,
        actor: actor,
        tenant: record.org_id
      )

    {:noreply,
     socket
     |> put_flash(:info, gettext("Draft translation created (%{locale}).", locale: locale))
     |> push_navigate(to: ~p"/editor/content/#{kind}/#{translation.id}")}
  rescue
    _error ->
      {:noreply, put_flash(socket, :error, gettext("Couldn't create that translation."))}
  end

  # ── Version compare (#467) ─────────────────────────────────────────────────

  def handle_event("toggle_compare", %{"version_id" => version_id}, socket) do
    picks = socket.assigns.compare_pick

    picks =
      cond do
        version_id in picks -> List.delete(picks, version_id)
        length(picks) < 2 -> picks ++ [version_id]
        # Two is the comparison. Picking a third retires the older choice rather
        # than making the editor clear the selection first.
        true -> tl(picks) ++ [version_id]
      end

    {:noreply, assign(socket, :compare_pick, picks)}
  end

  def handle_event("open_compare", _params, socket) do
    case build_compare(socket, socket.assigns.compare_pick) do
      {:ok, compare} ->
        {:noreply, assign(socket, :compare, compare)}

      :error ->
        {:noreply,
         socket
         |> assign(:compare, nil)
         |> put_flash(:error, gettext("Couldn't compare those versions."))}
    end
  end

  def handle_event("close_compare", _params, socket) do
    {:noreply, assign(socket, :compare, nil)}
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
        {:noreply,
         socket
         |> assign_record(record)
         |> reset_editors()
         |> assign(:save_state, :saved)
         # Restore can be fired from inside the compare modal; the diff it was
         # showing describes a document that no longer exists.
         |> assign(:compare, nil)
         |> assign(:compare_pick, [])
         |> put_flash(:info, gettext("Restored that version."))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, restore_error_message(error))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't restore that version."))}
    end
  end

  # A restore can fail for a reason the editor can act on — a category deleted or
  # a media item trashed since the version was written (#691) — and collapsing
  # every failure into one flash left them with a dead end instead of a fix.
  defp restore_error_message(error) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.filter(&match?(%{field: field} when not is_nil(field), &1))
    |> Enum.map_join(" ", &"#{VersionDiffComponents.field_label(&1.field)} #{&1.message}.")
    |> case do
      "" -> gettext("Couldn't restore that version.")
      message -> message
    end
  end

  # Force rich-text blocks to remount (new element id) so TipTap reloads from the
  # replaced form rather than keeping its `phx-update="ignore"` content (#135).
  # Bump the editor generation (remounts rich-text hooks) and drop everything
  # derived from the content the author is walking away from.
  #
  # AI suggestions must go with it: both callers — a conflict reload and a
  # version restore — replace the form wholesale, and `reload_conflict` also
  # clears `:conflict`, which is what `accept_suggestion/2` guards on. Left in
  # place, a proposal generated from the *discarded* content stays clickable
  # and would overwrite the record that was just reloaded.
  defp reset_editors(socket) do
    socket
    |> update(:editor_version, &(&1 + 1))
    |> clear_seo_suggestions()
    |> close_assist()
    |> assign(:seo_links, nil)
  end

  defp clear_seo_suggestions(socket) do
    socket
    |> assign(:seo_drafts, nil)
    |> assign(:seo_dismissed, MapSet.new())
  end

  # Same reasoning as the SEO clear above, one step further: the remount gives
  # every rich-text block a new element id, so a suggestion left on screen would
  # target a hook that no longer exists — the Insert click would silently do
  # nothing.
  defp close_assist(socket) do
    socket
    |> cancel_assist()
    |> assign(:assist_block, nil)
    |> assign(:assist_result, nil)
    |> assign(:assist_instruction, nil)
  end

  # `assist_running?` is one flag for the whole view, so an abandoned run would
  # otherwise refuse every other block's Generate click for the length of the
  # timeout — 45s by default — with no message and a spinner the author never
  # started. Closing the panel means the result has nowhere to land, so drop
  # the task rather than wait it out.
  defp cancel_assist(%{assigns: %{assist_running?: true}} = socket),
    do: socket |> cancel_async(:assist) |> assign(:assist_running?, false)

  defp cancel_assist(socket), do: socket

  # ── Block-level editorial comments (#404): handle_event helpers ────────────

  defp resolve_comment_thread(socket, id, action) do
    case Enum.find(socket.assigns.comments, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      comment ->
        case apply(CMS, action, [comment, %{}, [actor: socket.assigns.actor]]) do
          {:ok, _} ->
            {:noreply, reload_comments(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Couldn't update that comment thread."))}
        end
    end
  end

  defp reload_comments(socket) do
    comments =
      load_comments(
        socket.assigns.kind,
        socket.assigns.record.id,
        socket.assigns.actor,
        socket.assigns.current_org
      )

    assign(socket, :comments, comments)
  end

  # Batch-loads `:author` on the whole list in one query rather than once per
  # comment at render time (`comment_author_label/1` reads it back off the
  # struct — no per-row load in the template). `authorize?: false` on the load
  # only: `User`'s read policy is self-only (`id == actor(:id)`), so showing
  # who wrote a comment — ordinary display data, not sensitive — would
  # otherwise fail to load for every author but the viewer themselves. The
  # comment list itself is still policy-checked normally.
  defp load_comments(kind, record_id, actor, org) do
    to_string(kind)
    |> CMS.list_comments_for!(record_id, actor: actor, tenant: org)
    |> Ash.load!(:author, authorize?: false, tenant: org)
  end

  # ── Editorial tasks (#501): handle_event helpers ────────────────────────────

  defp load_tasks(kind, record_id, actor, org) do
    to_string(kind)
    |> CMS.list_tasks_for!(record_id, actor: actor, tenant: org)
    |> Enum.filter(&(&1.status == :open))
    |> Ash.load!(:assignee, authorize?: false, tenant: org)
  end

  defp reload_tasks(socket) do
    tasks =
      load_tasks(
        socket.assigns.kind,
        socket.assigns.record.id,
        socket.assigns.actor,
        socket.assigns.current_org
      )

    assign(socket, :tasks, tasks)
  end

  defp put_task_draft(socket, key, value),
    do: assign(socket, :task_draft, Map.put(socket.assigns.task_draft, key, value))

  # ── Content releases (#500 / #836) ──────────────────────────────────────────

  # A record sits in at most one unshipped release (the partial unique index on
  # `release_items`), so this is a single row or nothing. The pickable list is
  # the editable releases; adding is refused server-side for a type outside the
  # editor's scope, which is what actually enforces it — the picker just doesn't
  # need to know.
  defp assign_release_state(socket, kind, record_id, actor, org) do
    item =
      to_string(kind)
      |> CMS.list_pending_release_items_for_content!(record_id, actor: actor, tenant: org)
      |> List.first()

    socket
    |> assign(:release_item, item)
    |> assign(:release_of_item, release_of(item, actor, org))
    |> assign(:releases, CMS.list_editable_releases!(actor: actor, tenant: org))
    |> assign(:release_draft, %{})
  end

  defp reload_release_state(socket) do
    assign_release_state(
      socket,
      socket.assigns.kind,
      socket.assigns.record.id,
      socket.assigns.actor,
      socket.assigns.current_org
    )
  end

  defp release_of(nil, _actor, _org), do: nil

  defp release_of(item, actor, org) do
    case CMS.get_release(item.release_id, actor: actor, tenant: org) do
      {:ok, release} -> release
      _ -> nil
    end
  end

  defp put_release_draft(socket, key, value),
    do: assign(socket, :release_draft, Map.put(socket.assigns.release_draft, key, value))

  # The select renders the first release preselected, but a browser that never
  # fires `change` (the editor accepts the default) leaves the draft empty — so
  # the button falls back to what the select is actually showing.
  defp default_release_id(socket) do
    case socket.assigns.releases do
      [%{id: id} | _] -> id
      _ -> nil
    end
  end

  defp release_action("unpublish"), do: :unpublish
  defp release_action(_publish), do: :publish

  # The reason is worth surfacing here — "already in another open release",
  # "outside your content-type scope" and "release is full" are all things the
  # editor can act on, and a generic failure would send them hunting.
  #
  # Read off the error STRUCTS rather than `Exception.message/1`: Ash renders a
  # multi-line breakdown with breadcrumbs and a stacktrace, so splitting that on
  # newlines puts `:gen_server.handle_msg/3` in the flash.
  defp release_error_message(%{errors: errors}) when is_list(errors) do
    errors
    |> Enum.map(&leaf_message/1)
    |> Enum.find(&(is_binary(&1) and &1 != ""))
    |> case do
      nil -> generic_release_error()
      reason -> gettext("Couldn't add it to that release: %{reason}", reason: reason)
    end
  end

  defp release_error_message(_error), do: generic_release_error()

  defp leaf_message(%{message: message}) when is_binary(message), do: message
  defp leaf_message(_error), do: nil

  defp generic_release_error, do: gettext("Couldn't add it to that release.")

  # Org editors/admins — the roster a task can be assigned to (viewers can't
  # act on content, so they're excluded). `authorize?: false`: OrgMembership's
  # read policy is self-only (same reasoning as `load_comments/4`'s author
  # load), so listing the roster for a dropdown needs a system read.
  defp assignable_users do
    Accounts.User
    |> Ash.Query.filter(role in [:editor, :admin])
    |> Ash.read!(authorize?: false)
    |> Enum.sort_by(&user_label/1)
    |> Enum.map(&{user_label(&1), &1.id})
  end

  defp user_label(%{name: name}) when is_binary(name) and name != "", do: name
  defp user_label(%{email: email}), do: to_string(email)

  defp close_comment_panel(socket) do
    socket
    |> assign(:comment_block, nil)
    |> assign(:comment_draft, nil)
  end

  defp run_workflow(socket, action)
       when action in ~w(submit return publish unpublish archive unarchive) do
    # `publish` gets its own event; the rest share `:workflow` (tagged by action)
    # so the publish hot path is isolated in the metrics.
    {event, meta} =
      if action == "publish",
        do: {:publish, %{kind: socket.assigns.kind}},
        else: {:workflow, %{kind: socket.assigns.kind, action: action}}

    result =
      EditorTelemetry.span(event, meta, fn ->
        do_workflow(socket.assigns.kind, action, socket.assigns.record, socket.assigns.actor)
      end)

    case result do
      {:ok, record} ->
        socket
        |> cancel_autosave_timer()
        |> assign_record(record)
        |> assign(:save_state, :saved)
        |> put_flash(:info, gettext("Updated to %{state}.", state: state_label(record.state)))

      _ ->
        put_flash(socket, :error, gettext("That action isn't allowed right now."))
    end
  end

  defp run_workflow(socket, _action), do: socket

  # --- dirty tracking + draft autosave ----------------------------------------

  # Every form-mutating event funnels through here. Drafts autosave;
  # published/in-review/archived content is changed deliberately via the
  # explicit Save button, so for those we only flip the dirty indicator
  # (and the UnsavedGuard hook warns before navigating away).
  #
  # Under active collaboration (CRDT prototype), only ONE editor persists:
  # concurrent autosaves would race the optimistic lock even though the
  # rich-text content has already converged. The persister's TipTap mirrors
  # remote CRDT edits into its own form, so its autosave covers everyone's
  # typing; the others show `:synced` instead of autosaving (their edits to
  # non-CRDT fields still save via the explicit Save button).
  defp mark_dirty(socket) do
    socket = refresh_preview(socket)

    cond do
      not draft?(socket) ->
        assign(socket, :save_state, :unsaved)

      collab_active?(socket) and not persister?(socket) ->
        socket
        |> cancel_autosave_timer()
        |> assign(:save_state, :synced)

      true ->
        socket
        |> cancel_autosave_timer()
        |> assign(:autosave_timer, Process.send_after(self(), :autosave, @autosave_debounce_ms))
        # `:saving` from the moment of edit — the change is queued to autosave,
        # like a "Saving…" indicator (#136). Resolves to `:saved`/`:error` on
        # flush.
        |> assign(:save_state, :saving)
    end
  end

  # More than one editor present with the CRDT prototype on — text edits flow
  # through the shared Y.Doc rather than each session's form.
  defp collab_active?(socket),
    do: socket.assigns.collab_token != nil and length(socket.assigns.editors) > 1

  # The designated persisting editor: lowest user id among those present — the
  # same deterministic tie-break the advisory field locks use, so every
  # session elects the same one without coordination.
  defp persister?(%{assigns: %{editors: []}}), do: true

  defp persister?(socket) do
    socket.assigns.actor.id ==
      socket.assigns.editors |> Enum.map(& &1.id) |> Enum.min()
  end

  defp perform_autosave(%{assigns: %{save_state: :saving}} = socket) do
    cond do
      not draft?(socket) ->
        assign(socket, :autosave_timer, nil)

      # A lower-id editor joined between scheduling and firing — stand down;
      # they persist from here.
      collab_active?(socket) and not persister?(socket) ->
        socket |> assign(:autosave_timer, nil) |> assign(:save_state, :synced)

      true ->
        do_autosave(socket)
    end
  end

  # Stale timer (already saved, or state moved on) — no-op.
  defp perform_autosave(socket), do: assign(socket, :autosave_timer, nil)

  defp do_autosave(socket) do
    socket = assign(socket, :autosave_timer, nil)

    # Submit the current edits through the dedicated `:autosave` action (kept
    # distinct from the explicit Save's `:update` so its PaperTrail versions
    # are tagged and coalesced). A throwaway form mirrors the live one's
    # params, leaving `socket.assigns.form` intact for the Save button.
    autosave_form =
      AshPhoenix.Form.for_update(socket.assigns.record, :autosave,
        actor: socket.assigns.actor,
        tenant: socket.assigns.record.org_id,
        forms: [auto?: true]
      )

    # Form.params/1 only round-trips fields the rendered form knows (_touched),
    # so the socket-held state — columns children and pushed rich-text bodies —
    # must be re-injected here exactly as the explicit Save does; without this
    # an autosave persisted rich_text blocks with `body: []`/`legacy_html: ""`
    # and silently wiped the prose.
    params =
      socket.assigns.form
      |> AshPhoenix.Form.params()
      |> inject_children(socket.assigns.block_children)
      |> inject_rich_bodies(socket.assigns.rich_bodies)

    result =
      EditorTelemetry.span(:autosave, %{kind: socket.assigns.kind}, fn ->
        AshPhoenix.Form.submit(autosave_form, params: params)
      end)

    case result do
      {:ok, record} ->
        reloaded =
          fetch!(socket.assigns.kind, record.id, socket.assigns.actor, socket.assigns.current_org)

        socket |> assign_record(reloaded) |> assign(:save_state, :saved)

      {:error, form} ->
        handle_autosave_error(socket, form)
    end
  end

  # Someone else saved first → stop autosaving and surface the conflict rather
  # than retrying (which would keep losing). Otherwise mark the draft as failing
  # validation (`:error`) so the indicator says so (#136); the next edit
  # reschedules a retry.
  defp handle_autosave_error(socket, form) do
    if stale_conflict?(form),
      do: flag_conflict(socket),
      else: assign(socket, :save_state, :error)
  end

  # Stop autosaving and put the editor into a conflict state until the user
  # reloads. Surface a flash so a blocked Save gets immediate feedback (#137) —
  # the Save button is also disabled while `@conflict` is set.
  defp flag_conflict(socket) do
    socket
    |> cancel_autosave_timer()
    |> assign(:conflict, true)
    |> assign(:save_state, :unsaved)
    |> put_flash(
      :error,
      gettext("This content changed elsewhere. Reload to get the latest before saving.")
    )
  end

  # True when a failed submit was rejected by the optimistic lock (the record
  # changed underneath us), as opposed to ordinary validation errors. The
  # `StaleRecord` error has no form-field representation, so unwrap the
  # Phoenix.HTML.Form → AshPhoenix.Form → Ash.Changeset to read its errors.
  defp stale_conflict?(form), do: form |> changeset_errors() |> Enum.any?(&stale_error?/1)

  defp changeset_errors(%Phoenix.HTML.Form{source: source}), do: changeset_errors(source)
  defp changeset_errors(%AshPhoenix.Form{source: source}), do: changeset_errors(source)
  defp changeset_errors(%Ash.Changeset{errors: errors}), do: errors
  defp changeset_errors(_other), do: []

  defp stale_error?(%Ash.Error.Changes.StaleRecord{}), do: true

  defp stale_error?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &stale_error?/1)

  defp stale_error?(_other), do: false

  defp cancel_autosave_timer(socket) do
    if ref = socket.assigns.autosave_timer, do: Process.cancel_timer(ref)
    assign(socket, :autosave_timer, nil)
  end

  defp draft?(socket), do: socket.assigns.record.state == :draft

  # Number of block sub-forms currently in the form (#171 keyboard reorder).
  defp blocks_count(form) do
    case AshPhoenix.Form.value(form, :blocks) do
      list when is_list(list) -> length(list)
      _ -> 0
    end
  end

  # Current positional index of the block whose stable id is `bid`, or nil if no
  # block carries it. Resolves against the live nested forms (which reflect the
  # id from either loaded data or add-form params, and the current order after a
  # reorder) rather than a position captured at render time — this is what makes
  # the picker/delete/move resilient to a concurrent reorder (audit T5.1/T5.2).
  defp block_index_by_id(form, bid) do
    bid = to_string(bid)

    form
    |> ash_form()
    |> Map.get(:forms, %{})
    |> Map.get(:blocks, [])
    |> List.wrap()
    |> Enum.find_index(fn sub -> to_string(AshPhoenix.Form.value(sub, :id)) == bid end)
  end

  # Move a just-appended block (currently last) to the requested insert position
  # (B2 inline insertion): `nil`/absent leaves it at the end (append), "start"
  # moves it to the top, and a block id moves it directly after that block. The
  # anchor id is resolved against the live forms, so insertion stays correct even
  # if the list was reordered since the "+" was rendered.
  defp position_new_block(form, anchor) when anchor in [nil, ""], do: form
  defp position_new_block(form, "start"), do: reposition_last(form, 0)

  defp position_new_block(form, anchor) do
    case block_index_by_id(form, anchor) do
      nil -> form
      i -> reposition_last(form, i + 1)
    end
  end

  # Reorder the block sub-forms so the last one (the newly added block) sits at
  # `target`, preserving the order of the others.
  defp reposition_last(form, target) do
    last = blocks_count(form) - 1
    target = target |> max(0) |> min(last)
    existing = if last > 0, do: Enum.map(0..(last - 1), &to_string/1), else: []
    order = List.insert_at(existing, target, to_string(last))
    AshPhoenix.Form.sort_forms(form, [:blocks], order)
  end

  # A copy of a columns block's socket-managed child tree with every nested child
  # re-keyed, so a duplicated columns block's children stay independent of the
  # original's (block duplication).
  defp dup_children(columns) when is_list(columns) do
    Enum.map(columns, fn column ->
      blocks =
        column
        |> Map.get("blocks", [])
        |> Enum.map(&Map.put(&1, "id", Ash.UUID.generate()))

      Map.put(column, "blocks", blocks)
    end)
  end

  defp dup_children(_), do: nil

  # `socket.assigns.form` is a Phoenix.HTML.Form wrapping the AshPhoenix.Form
  # (nested forms live on the latter); unwrap so we can read the block sub-forms.
  defp ash_form(%Phoenix.HTML.Form{source: %AshPhoenix.Form{} = source}), do: source
  defp ash_form(%AshPhoenix.Form{} = form), do: form

  # The complete current block set as a list of union input maps (string keys,
  # `_union_type` discriminator, stable `id`), read from the live sub-forms. This
  # is the payload a caller merges a targeted edit into so that validating it
  # preserves every other block and its identity — a form that hasn't been
  # submitted has empty `params`, so a partial blocks param would drop the rest.
  defp full_blocks_input(form) do
    form
    |> ash_form()
    |> Map.get(:forms, %{})
    |> Map.get(:blocks, [])
    |> List.wrap()
    |> Enum.map(&block_input_map/1)
  end

  defp block_input_map(%AshPhoenix.Form{} = sub), do: block_field_map(sub, "_union_type")

  # The declared fields of a block sub-form as a string-keyed map, tagged with its
  # block type under `type_key` and carrying the stable `id`. The only thing that
  # varies between the union-input shape (`_union_type`) and the typed-preview
  # shape (`_type`) is that key, so both go through here.
  defp block_field_map(%AshPhoenix.Form{} = sub, type_key) do
    mod = block_member(sub)

    Kiln.Block.Info.fields(mod)
    |> Map.new(fn field -> {to_string(field.name), AshPhoenix.Form.value(sub, field.name)} end)
    |> Map.put(type_key, to_string(Kiln.Block.Info.name(mod)))
    |> Map.put("id", AshPhoenix.Form.value(sub, :id))
  end

  # Swap the two list elements at positions `i` and `j`.
  defp swap_at(list, i, j) do
    a = Enum.at(list, i)
    b = Enum.at(list, j)

    list
    |> List.replace_at(i, b)
    |> List.replace_at(j, a)
  end

  # Re-run form validation with the socket-held child blocks re-injected and GEO
  # item rows normalized — the shared path for events that rebuild block params
  # (e.g. an image pick) so a partial update can't drop the nested tree.
  defp revalidate(socket, params) do
    params = params |> inject_children(socket.assigns.block_children) |> normalize_item_rows()
    assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, params))
  end

  # Drop any socket-held child state whose parent block no longer exists in the
  # live form (e.g. after a block delete), so stale children can't resurface.
  defp prune_block_children(socket) do
    live_ids =
      socket.assigns.form
      |> AshPhoenix.Form.params()
      |> Map.get("blocks")
      |> block_param_ids()
      |> MapSet.new()

    pruned = Map.filter(socket.assigns.block_children, fn {id, _} -> id in live_ids end)
    assign(socket, :block_children, pruned)
  end

  defp block_param_ids(blocks) when is_map(blocks),
    do: blocks |> Map.values() |> block_param_ids()

  defp block_param_ids(blocks) when is_list(blocks), do: Enum.flat_map(blocks, &block_param_id/1)
  defp block_param_ids(_blocks), do: []

  defp block_param_id(%{"id" => id}) when is_binary(id), do: [id]
  defp block_param_id(_block), do: []

  # Push the current title + blocks to any open decoupled preview windows.
  # Skipped entirely while no window is watching (audit P-M2) — otherwise every
  # editor paid the full typed→legacy block conversion per debounced keystroke
  # for a payload nobody received.
  defp broadcast_preview(%{assigns: %{preview_open?: false}} = socket), do: socket

  defp broadcast_preview(socket) do
    form = socket.assigns.form

    payload = %{
      title: AshPhoenix.Form.value(form, :title) || "",
      excerpt: socket.assigns.has_excerpt && AshPhoenix.Form.value(form, :excerpt),
      blocks: preview_blocks(form)
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

  # ── GEO item rows: params helpers (#357) ────────────────────────────────────

  # Apply `fun` to the item list of one block (by index) and re-validate.
  defp update_item_rows(socket, index, field, fun) do
    # The FULL block set, not a partial params write. `AshPhoenix.Form.params/1`
    # is `only_touched?`, so a form freshly loaded from a saved record carries no
    # `blocks` key at all — and `validate/2` rebuilds the sub-forms from the keys
    # it is given, so writing `%{"blocks" => %{"0" => …}}` deletes every other
    # block in the document. `pick_image` already carries the full set through
    # for exactly this reason; these buttons need it just as much, and more
    # often, since the gallery's only route to its first image is one of them.
    #
    # Rebuilding also resolves the "params or stored value?" question: each
    # block's input map already carries its rows, whether they came from the
    # record or from something the editor typed.
    blocks = full_blocks_input(socket.assigns.form)
    index = to_int(index)

    case Enum.at(blocks, index) do
      nil ->
        {:noreply, socket}

      block ->
        current = block |> Map.get(field) |> stringify_rows()
        blocks = List.replace_at(blocks, index, Map.put(block, field, fun.(current)))

        params =
          socket.assigns.form
          |> AshPhoenix.Form.params()
          |> Map.put("blocks", blocks)

        socket = revalidate(socket, params)
        broadcast_preview(socket)
        {:noreply, mark_dirty(socket)}
    end
  end

  defp stringify_rows(value) do
    value
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(&Map.new(&1, fn {k, v} -> {to_string(k), v} end))
  end

  # Resolve the block id to an index *now* rather than trusting one captured at
  # render, for the reason `remove_block` gives: an in-flight reorder must not
  # turn a click on one block into an edit of another.
  defp update_gallery_images(socket, bid, fun) do
    case block_index_by_id(socket.assigns.form, bid) do
      nil -> {:noreply, socket}
      index -> update_item_rows(socket, index, "images", fun)
    end
  end

  # Item rows are bound inputs, so a DOM submit delivers them as indexed maps
  # (`"items" => %{"0" => %{…}}`) — convert to the ordered lists the blocks'
  # `{:array, :map}` fields cast. Non-numeric keys (the always-present sentinel
  # that keeps the param submitted when every row is removed) are dropped.
  defp normalize_item_rows(params) do
    # `Map.update/4` would *insert* a nil `blocks` key on block-less params
    # (title-only edits), which AshPhoenix's nested-form validate chokes on.
    case params do
      %{"blocks" => blocks} when is_map(blocks) ->
        Map.put(params, "blocks", Map.new(blocks, fn {k, b} -> {k, normalize_block_items(b)} end))

      %{"blocks" => blocks} when is_list(blocks) ->
        Map.put(params, "blocks", Enum.map(blocks, &normalize_block_items/1))

      _ ->
        params
    end
  end

  defp normalize_block_items(%{} = block) do
    # `images` is the gallery's row field. It is not in `@row_fields` because it
    # is not edited by `item_rows_editor/1` — but it is still an indexed map on
    # the wire, so it needs the same flattening or a gallery loses every image
    # on save.
    Enum.reduce(@row_fields ++ ["images"], block, fn key, block ->
      case block do
        %{^key => %{} = indexed} -> Map.put(block, key, indexed_items_to_list(indexed))
        _ -> block
      end
    end)
  end

  defp normalize_block_items(other), do: other

  defp indexed_items_to_list(indexed) do
    indexed
    |> Enum.filter(fn {k, v} -> is_map(v) and Regex.match?(~r/\A\d+\z/, k) end)
    |> Enum.sort_by(fn {k, _v} -> String.to_integer(k) end)
    |> Enum.map(fn {_k, v} -> v end)
  end

  # ── columns children: socket state ⇄ form params ────────────────────────────

  # Re-sync the socket-managed children into the form (keeping the preview + a
  # future save current), then refresh the preview and mark the doc dirty. The
  # form's own params carry every other field, so injecting the children over
  # them is a lossless round-trip.
  defp apply_children(socket, block_children) do
    params =
      socket.assigns.form
      |> AshPhoenix.Form.params()
      |> inject_children(block_children)

    socket
    |> assign(:block_children, block_children)
    |> assign(:form, AshPhoenix.Form.validate(socket.assigns.form, params))
    |> broadcast_preview_and_refresh()
    |> mark_dirty()
  end

  defp broadcast_preview_and_refresh(socket) do
    socket = refresh_preview(socket)
    broadcast_preview(socket)
    socket
  end

  # Set the `columns` param of every `columns` block to its socket-managed
  # children, matched by the block's stable id. Tolerates params where `blocks`
  # is the usual indexed map or a list.
  defp inject_children(params, block_children) when map_size(block_children) == 0, do: params

  defp inject_children(params, block_children) do
    Map.update(params, "blocks", params["blocks"], fn
      blocks when is_map(blocks) ->
        Map.new(blocks, fn {k, v} -> {k, inject_block(v, block_children)} end)

      blocks when is_list(blocks) ->
        Enum.map(blocks, &inject_block(&1, block_children))

      other ->
        other
    end)
  end

  # Overlay pending rich-text bodies (Portable Text lists, from the TipTap
  # hook's rich_text_body pushes) onto the block params, matched by block id —
  # falling back to the positional key for blocks that haven't been saved yet.
  # legacy_html is cleared in the same stroke: body becomes this block's single
  # source of truth (the cast enforces the same rule).
  defp inject_rich_bodies(params, rich_bodies) when map_size(rich_bodies) == 0, do: params
  defp inject_rich_bodies(%{"blocks" => nil} = params, _rich_bodies), do: params

  defp inject_rich_bodies(%{"blocks" => _} = params, rich_bodies) do
    Map.update(params, "blocks", params["blocks"], fn
      blocks when is_map(blocks) ->
        Map.new(blocks, fn {k, v} -> {k, inject_rich_body(v, k, rich_bodies)} end)

      blocks when is_list(blocks) ->
        blocks
        |> Enum.with_index()
        |> Enum.map(fn {v, i} -> inject_rich_body(v, to_string(i), rich_bodies) end)

      other ->
        other
    end)
  end

  defp inject_rich_bodies(params, _rich_bodies), do: params

  defp inject_rich_body(%{} = block, key, rich_bodies) do
    case rich_bodies[block["id"]] || rich_bodies["idx-" <> key] do
      nil -> block
      body -> block |> Map.put("body", body) |> Map.put("legacy_html", "")
    end
  end

  defp inject_rich_body(other, _key, _rich_bodies), do: other

  defp inject_block(%{} = block, block_children) do
    case block["id"] && Map.get(block_children, block["id"]) do
      nil -> block
      cols -> Map.put(block, "columns", cols)
    end
  end

  defp inject_block(other, _block_children), do: other

  # Apply `fun` to the child-block list of one column (by index) of a block.
  defp update_column(block_children, block_id, col_index, fun) do
    Map.update(block_children, block_id, [], fn cols ->
      List.update_at(cols, col_index, &update_col_blocks(&1, fun))
    end)
  end

  # Apply `fun` to every column's child-block list of a block.
  defp update_columns(block_children, block_id, fun) do
    Map.update(block_children, block_id, [], fn cols ->
      Enum.map(cols, &update_col_blocks(&1, fun))
    end)
  end

  defp update_col_blocks(col, fun) do
    Map.update(col || %{"blocks" => []}, "blocks", [], fn blocks -> fun.(List.wrap(blocks)) end)
  end

  # Rebuild every column of a block from a per-column list of child ids (a nested
  # drag result), preserving each child's current attrs by id.
  defp rebuild_columns(current, cols) do
    by_id = current |> Enum.flat_map(& &1["blocks"]) |> Map.new(&{&1["id"], &1})
    Enum.map(cols, fn ids -> %{"blocks" => pick_children(by_id, ids)} end)
  end

  defp pick_children(by_id, ids),
    do: ids |> List.wrap() |> Enum.map(&by_id[&1]) |> Enum.reject(&is_nil/1)

  # Set `field` on the child whose id matches; leave every other child untouched.
  defp maybe_put_field(%{"id" => id} = child, id, field, value),
    do: put_child_field(child, field, value)

  defp maybe_put_field(child, _id, _field, _value), do: child

  # Normalize a stored/def columns value to the editor shape: a non-empty list of
  # `%{"blocks" => [child maps]}`, every child carrying a stable id (backfilled if
  # a legacy child lacks one, so the nested Sortable can address it).
  defp normalize_columns(cols) do
    case List.wrap(cols) do
      [] ->
        [%{"blocks" => []}, %{"blocks" => []}]

      list ->
        Enum.map(list, fn col ->
          blocks =
            col
            |> child_blocks_of()
            |> Enum.map(&ensure_child_id/1)

          %{"blocks" => blocks}
        end)
    end
  end

  defp child_blocks_of(col) when is_map(col),
    do: (Map.get(col, "blocks") || Map.get(col, :blocks) || []) |> List.wrap()

  defp child_blocks_of(_), do: []

  defp ensure_child_id(child) do
    child = stringify_child(child)
    Map.put_new_lazy(child, "id", &Ash.UUID.generate/0)
  end

  defp stringify_child(%{} = child), do: Map.new(child, fn {k, v} -> {to_string(k), v} end)
  defp stringify_child(_), do: %{}

  # A fresh child block map (string keys) with its type-appropriate defaults.
  defp new_child(type) do
    base = %{"_type" => type, "id" => Ash.UUID.generate()}

    case type do
      "heading" -> Map.merge(base, %{"text" => "", "level" => 2})
      "rich_text" -> Map.merge(base, %{"legacy_html" => "", "body" => []})
      "quote" -> Map.merge(base, %{"text" => "", "citation" => ""})
      "image" -> Map.merge(base, %{"url" => "", "alt" => ""})
      "embed" -> Map.merge(base, %{"url" => ""})
      _ -> base
    end
  end

  # Drop the tag picker's hidden sentinel (see `tag_picker/1`). It exists so an
  # all-unchecked group still submits `tag_ids`, which is the difference between
  # "detach every tag" and "the field was never touched" — but `""` is not a
  # uuid, so it must not reach the changeset.
  defp normalize_tag_ids(%{"tag_ids" => ids} = params) when is_list(ids),
    do: Map.put(params, "tag_ids", Enum.reject(ids, &(&1 == "")))

  defp normalize_tag_ids(params), do: params

  # Coerce an editable child field, keeping `level` an integer (headings clamp on
  # render, so an out-of-range value is harmless, but a non-integer would fail the
  # embedded cast).
  defp put_child_field(child, "level", value), do: Map.put(child, "level", to_int(value))
  defp put_child_field(child, field, value), do: Map.put(child, field, value)

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp to_int(_), do: 0

  # Parse a non-negative integer index from a client value, or :error — so a
  # stale/garbled index no-ops instead of silently acting on position 0 (which
  # `to_int/1` would do).
  defp parse_index(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp parse_index(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_index(_value), do: :error

  defp append_child(blocks, _type) when length(blocks) >= @max_children_per_column, do: blocks
  defp append_child(blocks, type), do: blocks ++ [new_child(type)]

  # Keep at least one column so the block stays a valid container.
  defp drop_column(cols, _ci) when length(cols) <= 1, do: cols
  defp drop_column(cols, ci), do: List.delete_at(cols, ci)

  # The media id currently on an image block sub-form, if any.
  defp media_id_of(bf), do: bf[:media_id].value

  # Safe `src` for the image-block preview: a pasted URL is untrusted, so it must
  # clear the same scheme allowlist as delivery before we echo it back. Returns
  # nil (image hidden) for rejected schemes like `javascript:`/`data:`.
  defp safe_preview_src(url), do: KilnCMS.HTMLSanitizer.safe_image_src(url)

  defp reset_picker(socket) do
    socket
    |> assign(:picking, nil)
    |> assign(:picked, [])
    |> assign(:media_query, "")
    |> assign(:picker_media, nil)
    |> assign(:file_picking, nil)
    |> assign(:file_query, "")
    |> assign(:picker_files, nil)
    |> assign(:av_picking, nil)
    |> assign(:av_query, "")
    |> assign(:picker_av, nil)
  end

  # ── AI-assisted SEO drafting (#60) ────────────────────────────────────────

  # The projection handed to the generator, built from the *live* form so an
  # unsaved draft can be described. `preview_block_maps/1` already gives the
  # editor's current typed blocks, including unsaved rich-text bodies.
  defp seo_document(socket) do
    form = socket.assigns.form

    KilnCMS.Seo.Document.new(%{
      title: AshPhoenix.Form.value(form, :title),
      excerpt: socket.assigns.has_excerpt && AshPhoenix.Form.value(form, :excerpt),
      blocks: preview_block_maps(form),
      # The *record's* locale, not the admin UI's — otherwise a French page
      # gets English metadata because the editor was browsing in English.
      locale: AshPhoenix.Form.value(form, :locale),
      content_type: socket.assigns.content_type.label,
      seo_title: AshPhoenix.Form.value(form, :seo_title),
      seo_description: AshPhoenix.Form.value(form, :seo_description),
      seo_keywords: AshPhoenix.Form.value(form, :seo_keywords)
    })
  end

  defp load_link_suggestions(socket) do
    record = socket.assigns.record
    actor = socket.assigns.actor
    # Paths the body already links to, so we don't suggest a link that's there.
    linked = socket.assigns.seo_body_stats.internal_link_paths

    socket
    |> assign(:seo_links_loading?, true)
    |> start_async(:seo_links, fn ->
      KilnCMS.Seo.Links.suggest(record, actor: actor, exclude_paths: linked)
    end)
  end

  # Why the suggestion list came back empty — an unexplained empty panel reads
  # as broken, and the usual cause (a draft that has never been indexed) is
  # both common and fixable.
  defp link_empty_reason(record) do
    cond do
      record.state != :published and is_nil(record.published_at) ->
        gettext("Publish this page to index it — suggestions come from indexed content.")

      not KilnCMS.Search.semantic?() ->
        gettext("No related pages matched. Enabling semantic search improves these results.")

      true ->
        gettext("No related pages found yet.")
    end
  end

  # Which fields the current draft actually proposes, in display order.
  defp suggested_fields(nil), do: []

  defp suggested_fields(draft) do
    Enum.filter(
      ~w(seo_title seo_description seo_keywords),
      &(suggested_value(draft, &1) not in [nil, ""])
    )
  end

  defp suggested_value(nil, _field), do: nil
  defp suggested_value(draft, "seo_title"), do: draft.seo_title
  defp suggested_value(draft, "seo_description"), do: draft.seo_description

  defp suggested_value(draft, "seo_keywords"),
    do: KilnCMS.Seo.Draft.keywords_string(draft)

  defp suggested_value(_draft, _field), do: nil

  # Accept one proposed value into the form.
  #
  # Three guards, none of which the UI alone can provide:
  #
  #   * the collaborative field lock is advisory — a readonly input still
  #     submits — so a disabled button is not a boundary. A replayed event or a
  #     stale DOM reaches here, and without this check it would silently
  #     overwrite whatever a peer is typing.
  #   * a conflicted editor can't save at all, so writing into it would only
  #     bury the suggestion behind a reload.
  #   * params are recomputed from the form *now*, never snapshotted when the
  #     generation started — a 5s call spans two debounced autosaves, after
  #     which the form has been rebuilt with a bumped `lock_version`.
  # Returns `{socket, outcome}` rather than flashing inline: "Use all" applies
  # several fields in one click, and letting each one `put_flash` meant the last
  # write silently overwrote the message about a field that was *skipped* — the
  # author was told keywords applied while a locked title had been dropped.
  defp apply_suggestion(socket, field) do
    value = suggested_value(socket.assigns.seo_drafts, field)

    cond do
      is_nil(value) or value == "" ->
        {socket, :nothing_to_apply}

      socket.assigns.conflict ->
        {socket, :conflict}

      field_locked?(locked_fields(socket), field) ->
        {socket, :locked}

      true ->
        params = socket.assigns.form |> AshPhoenix.Form.params() |> Map.put(field, value)
        {params, socket, outcome} = maybe_sync_slug(field, params, socket)

        socket =
          socket
          |> assign(:form, AshPhoenix.Form.validate(socket.assigns.form, params))
          |> assign(:seo_dismissed, MapSet.put(socket.assigns.seo_dismissed, field))
          |> mark_dirty()

        {socket, outcome}
    end
  end

  # The suggestion cards still on screen, in display order.
  defp pending_suggestions(socket) do
    socket.assigns.seo_drafts
    |> suggested_fields()
    |> Enum.reject(&(&1 in socket.assigns.seo_dismissed))
  end

  # One message for the whole click, naming what was skipped and why.
  defp flash_outcomes(socket, outcomes) do
    cond do
      Enum.any?(outcomes, &(elem(&1, 1) == :conflict)) ->
        put_flash(
          socket,
          :error,
          gettext("Reload to resolve the editing conflict before applying suggestions.")
        )

      locked = Enum.filter(outcomes, &(elem(&1, 1) == :locked)) ->
        flash_locked(socket, locked, outcomes)

      true ->
        socket
    end
  end

  defp flash_locked(socket, [], outcomes), do: flash_slug(socket, outcomes)

  defp flash_locked(socket, locked, _outcomes) do
    put_flash(
      socket,
      :info,
      ngettext(
        "Another editor is editing %{fields} right now, so it wasn't applied.",
        "Another editor is editing %{fields} right now, so they weren't applied.",
        length(locked),
        fields: Enum.map_join(locked, ", ", &seo_field_label(elem(&1, 0)))
      )
    )
  end

  defp flash_slug(socket, outcomes) do
    if Enum.any?(outcomes, &(elem(&1, 1) == :slug_pinned)) do
      put_flash(
        socket,
        :info,
        gettext("Keywords applied. The slug was left unchanged because this content is live.")
      )
    else
      socket
    end
  end

  # `seo_keywords` is a slug source (`slug_targets/1`), so *typing* it
  # re-derives the slug. Accepting a suggestion has to make a deliberate
  # choice, because neither "always" nor "never" is right:
  #
  #   * on a draft that has never been published there is no live URL to break,
  #     and not re-deriving would diverge from what typing the same value does;
  #   * on anything published, silently moving a live URL because an AI
  #     proposed a keyphrase would be indefensible — so it's left alone and
  #     the author is told.
  #
  # `sync_slug/3` already no-ops when the author has pinned the slug, so a
  # hand-written slug is safe in both branches.
  defp maybe_sync_slug("seo_keywords", params, socket) do
    record = socket.assigns.record

    if record.state == :draft and is_nil(record.published_at) do
      # Keep `sync_slug/3`'s socket — it carries the `slug_customized?` flag.
      {params, socket} = sync_slug(params, ["form", "seo_keywords"], socket)
      {params, socket, :applied}
    else
      {params, socket, :slug_pinned}
    end
  end

  defp maybe_sync_slug(_field, params, socket), do: {params, socket, :applied}

  defp seo_error_message(:too_short),
    do: gettext("There isn't enough content yet to suggest metadata from.")

  defp seo_error_message(:disabled),
    do: gettext("AI suggestions aren't configured.")

  defp seo_error_message({:rate_limited, retry_after_ms}),
    do:
      gettext("Too many suggestions requested. Try again in %{seconds}s.",
        seconds: max(div(retry_after_ms, 1000), 1)
      )

  defp seo_error_message(_reason),
    do: gettext("Couldn't generate suggestions. Please try again.")

  # ── Block-level AI assist (#60) ───────────────────────────────────────────

  # The conflict and field-lock checks are re-run *here*, not just on the
  # button, for the same reason `apply_suggestion/2` and `put_seo_image/2` do
  # it: a stale DOM or a replayed event beats a rendered `disabled`, and
  # "replace" wipes the shared Y.Doc fragment under whoever else is in it.
  defp apply_assist(socket, block_id, mode, suggestion) do
    cond do
      socket.assigns.conflict ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("This content changed elsewhere. Reload before applying suggestions.")
         )}

      assist_block_locked?(socket, block_id) ->
        {:noreply,
         put_flash(socket, :info, gettext("Another editor is editing this block right now."))}

      true ->
        {:noreply,
         socket
         |> push_event("assist:apply", %{
           block_id: block_id,
           mode: mode,
           paragraphs: suggestion.paragraphs
         })
         |> close_assist()
         |> mark_dirty()}
    end
  end

  # Whether a run may start: the feature on, nothing already in flight, the id
  # matching the open panel, and the id naming a rich-text block on this form.
  defp assist_runnable?(socket, block_id) do
    socket.assigns.assist_enabled? and
      not socket.assigns.assist_running? and
      socket.assigns.assist_block == block_id and
      not is_nil(assist_block_form(socket.assigns.form, block_id))
  end

  # The block's own `body` field is the one a peer locks, so that is the lock
  # this checks — the same field name the rich-text host renders its lock ring
  # from.
  defp assist_block_locked?(socket, block_id) do
    case assist_block_form(socket.assigns.form, block_id) do
      nil ->
        false

      subform ->
        # Built from the sub-form's own name rather than `subform[:body].name`:
        # these come from `AshPhoenix.Form.value/2`, not `inputs_for`, so they
        # are raw `%AshPhoenix.Form{}` structs that Access refuses. Same string
        # either way — it is what the rich-text host renders its lock ring from.
        field_locked?(locked_fields(socket), subform.name <> "[body]")
    end
  end

  # The one **rich-text** sub-form carrying `block_id`.
  #
  # Scoped to the form being edited, so a pushed id can only ever name a block
  # of this record — and to rich text, because that is the only type that
  # renders a panel and mounts a hook to deliver to. Without the type check an
  # image block's id passed every guard: it bought a billed generation over the
  # block's caption, then pushed the result at a `data-block-id` no hook owns,
  # so nothing was inserted and the record was marked dirty anyway.
  defp assist_block_form(form, block_id) do
    case AshPhoenix.Form.value(form, :blocks) do
      forms when is_list(forms) ->
        Enum.find(
          forms,
          &(AshPhoenix.Form.value(&1, :id) == block_id and rich_text_subform?(&1))
        )

      _ ->
        nil
    end
  end

  # The same helper the template gates the panel on, so the two can't disagree.
  defp rich_text_subform?(subform), do: block_type_string(subform) == "rich_text"

  # The projection handed to the generator, built from the *live* form so an
  # unsaved block can be worked on.
  #
  # Only the named block's text is sent. The page's title, excerpt and headings
  # go too — they are what keeps the generated voice consistent with the rest of
  # the page — but no other block's prose does, so a fifty-block page ships one
  # block, not fifty.
  #
  # `BlockText.to_text/1` over the single block, not `Body.compute/1`: that
  # computes twelve facts (syllables, sentences, link paths, alt-text gaps) and
  # keeps one, and it runs synchronously in the LiveView process before
  # `start_async` — i.e. it blocks the author's own keystrokes. `:text` is
  # literally `BlockText.to_text/1` (see `Kiln.Advisory.Body.from_typed/1`), so
  # the output is identical.
  defp assist_request(socket, block_id) do
    form = socket.assigns.form

    text =
      form
      |> assist_block_form(block_id)
      |> List.wrap()
      |> Enum.map(&block_full_map/1)
      |> KilnCMS.CMS.BlockText.to_text()

    KilnCMS.Assist.Request.new(%{
      action: socket.assigns.assist_action,
      instruction: socket.assigns.assist_instruction,
      text: text,
      title: AshPhoenix.Form.value(form, :title),
      excerpt: socket.assigns.has_excerpt && AshPhoenix.Form.value(form, :excerpt),
      headings: Enum.map(socket.assigns.seo_body_stats.headings, & &1.text),
      content_type: socket.assigns.content_type.label,
      # The *record's* locale, not the admin UI's — otherwise a French page
      # gets English prose because the editor was browsing in English.
      locale: AshPhoenix.Form.value(form, :locale)
    })
  end

  defp assist_action_label(:draft), do: gettext("Draft")
  defp assist_action_label(:continue), do: gettext("Continue")
  defp assist_action_label(:summarize), do: gettext("Summarize")
  defp assist_action_label(:rewrite), do: gettext("Improve")
  defp assist_action_label(:shorten), do: gettext("Shorten")
  defp assist_action_label(:expand), do: gettext("Expand")

  defp assist_action_hint(:draft),
    do: gettext("Writes new prose from your instruction. Describe what this section should say.")

  defp assist_action_hint(:continue),
    do: gettext("Carries on from where this block stops, in the same voice.")

  defp assist_action_hint(:summarize),
    do: gettext("Condenses this block into a single short paragraph.")

  defp assist_action_hint(:rewrite),
    do: gettext("Rewrites this block more clearly, keeping every fact and roughly the length.")

  defp assist_action_hint(:shorten), do: gettext("Cuts this block to about half its length.")

  defp assist_action_hint(:expand),
    do: gettext("Adds detail drawn from this block and the rest of the page.")

  defp assist_action_hint(_action), do: ""

  defp assist_error_message(:too_short),
    do:
      gettext("This block needs at least %{count} characters to work from.",
        count: KilnCMS.Assist.Request.min_text_chars()
      )

  defp assist_error_message(:no_instruction),
    do: gettext("Describe what this section should say, then try again.")

  defp assist_error_message(:disabled), do: gettext("AI assist isn't configured.")

  defp assist_error_message(:empty),
    do: gettext("The model returned nothing usable. Try again, or rephrase your instruction.")

  defp assist_error_message({:rate_limited, retry_after_ms}),
    do:
      gettext("Too many requests. Try again in %{seconds}s.",
        seconds: max(div(retry_after_ms, 1000), 1)
      )

  defp assist_error_message(_reason),
    do: gettext("Couldn't generate text. Please try again.")

  # Write `seo_image` from a server-side action (picker / featured-image copy).
  #
  # The advisory field lock is re-checked *here*, not just on the button: the
  # lock makes the input readonly but readonly inputs still submit, so a write
  # that bypassed this would silently clobber whatever a peer is typing. A
  # stale DOM or replayed event beats the disabled attribute; it doesn't beat
  # this.
  defp put_seo_image(socket, url) do
    if field_locked?(locked_fields(socket), "seo_image") do
      put_flash(
        socket,
        :info,
        gettext("Another editor is editing the social image right now.")
      )
    else
      params = AshPhoenix.Form.params(socket.assigns.form) |> Map.put("seo_image", url)

      socket
      |> assign(:form, AshPhoenix.Form.validate(socket.assigns.form, params))
      |> mark_dirty()
    end
  end

  # The featured image's URL, resolved through the picker window first and only
  # then the database — the window holds the most recent items, so the common
  # case costs no query, while an older featured image still resolves.
  defp featured_image_url(socket) do
    case AshPhoenix.Form.value(socket.assigns.form, :featured_image_id) do
      nil -> nil
      id -> media_url(socket, to_string(id))
    end
  end

  defp media_url(socket, id) do
    case Enum.find(socket.assigns.media, &(to_string(&1.id) == id)) do
      %{url: url} ->
        url

      nil ->
        case CMS.get_media_item(id,
               actor: socket.assigns.actor,
               tenant: socket.assigns.current_org
             ) do
          {:ok, %{url: url}} -> url
          _ -> nil
        end
    end
  end

  # Accessible tag picker (#153): a labeled checkbox group replacing the native
  # <select multiple> (no ⌘/Ctrl needed). Each tag is its own labeled control;
  # the array submits under the same `tag_ids[]` name the relationship expects.
  #
  # Tags are sectioned by their `TagGroup` — collapsible, alphabetical within a
  # section, with a client-side filter box — so a large vocabulary stays
  # scannable. Groups may be scoped to certain content types; groups that don't
  # apply to `kind` are omitted.
  attr :form, :any, required: true
  attr :tags, :list, required: true
  attr :tag_groups, :list, required: true
  attr :kind, :any, required: true
  attr :record, :any, required: true

  defp tag_picker(assigns) do
    # What's *persisted* on the record, as distinct from what's currently
    # ticked. The rescue section below keys on this, so unchecking a tag can't
    # delete its own checkbox.
    attached = assigns.record.tags |> current_ids() |> Enum.map(&to_string/1)

    # `@tags` is loaded once at mount and never refreshed, but `record.tags` is
    # (every autosave's `fetch!`). So a tag created and attached after mount — a
    # collaborator, another tab — is in `record.tags` but not `@tags`, renders
    # no checkbox, and the next save submits `tag_ids` without it, which
    # `append_and_remove` reads as "detach me" (#522). Render from the union of
    # the two so every attached tag always has a control; the sections and the
    # empty-state guard both key on it, not on the stale `@tags` alone.
    pickable = all_pickable_tags(assigns.tags, assigns.record.tags)

    selected =
      assigns.form
      |> selected_ids(:tag_ids, current_ids(assigns.record.tags))
      |> Enum.map(&to_string/1)

    assigns =
      assigns
      |> assign(:selected, selected)
      |> assign(:no_tags?, pickable == [])
      |> assign(
        :sections,
        tag_sections(pickable, assigns.tag_groups, assigns.kind, selected, attached)
      )
      |> assign(:name, assigns.form[:tag_ids].name <> "[]")

    ~H"""
    <fieldset id="tag-picker" phx-hook="TagFilter" data-tag-filter>
      <legend class="mb-1 block text-sm font-medium text-base-content">{gettext("Tags")}</legend>
      <p :if={@no_tags?} class="text-xs text-base-content/70">{gettext("No tags yet.")}</p>

      <%!-- Browsers omit an all-unchecked checkbox group from the payload
            entirely, which `selected_ids/3` can only read as "untouched" — so
            the last tag could never be removed. This sentinel keeps the key
            present; `normalize_tag_ids/1` drops it before the changeset. --%>
      <input :if={not @no_tags?} type="hidden" name={@name} value="" />

      <div :if={not @no_tags?} class="space-y-2">
        <%!-- Unnamed so it never serializes into the changeset, and wrapped in
              phx-update="ignore" so a re-render can't clobber what's typed.
              Unnamed does NOT stop the enclosing form's phx-change from firing,
              though — the TagFilter hook stops propagation for that. --%>
        <div phx-update="ignore" id="tag-picker-filter">
          <input
            type="search"
            data-tag-filter-input
            placeholder={gettext("Filter tags…")}
            aria-label={gettext("Filter tags")}
            autocomplete="off"
            class="field-input w-full"
          />
        </div>

        <%!-- `data-tag-open-default` is the server's own choice, re-rendered on
              every patch — what the filter hook restores to when the box is
              cleared (it can't stash that on the element itself; morphdom would
              drop it). --%>
        <details
          :for={section <- @sections}
          data-tag-section
          data-tag-open-default={to_string(section.open?)}
          open={section.open?}
          class="rounded border border-base-content/15"
        >
          <summary class="cursor-pointer px-2 py-1.5 text-sm font-medium">
            {section.label}
            <span class="font-normal text-base-content/60">
              ({gettext("%{selected} of %{total}",
                selected: section.selected_count,
                total: length(section.tags)
              )})
            </span>
          </summary>
          <p :if={section.note} class="px-2 pb-1 text-xs text-base-content/60">{section.note}</p>
          <div class="flex flex-wrap gap-2 p-2 pt-1">
            <label
              :for={tag <- section.tags}
              data-tag-item={String.downcase(tag.name)}
              class="inline-flex cursor-pointer items-center gap-1.5 rounded border border-base-content/20 px-2 py-1 text-sm hover:bg-base-200"
            >
              <input
                type="checkbox"
                name={@name}
                value={tag.id}
                checked={to_string(tag.id) in @selected}
                class="size-4 rounded border border-base-content/30 accent-primary"
              />
              {tag.name}
            </label>
          </div>
        </details>

        <p data-tag-filter-empty hidden class="text-xs text-base-content/70">
          {gettext("No tags match that filter.")}
        </p>
      </div>
    </fieldset>
    """
  end

  # The org's tags (loaded at mount) unioned with the ones this record actually
  # carries (refreshed on every autosave), deduplicated by id and preserving the
  # org order so the sections still sort as before. A record tag missing from
  # the org list is one attached since mount — without it the picker can't
  # render its checkbox, and an unrendered checkbox is a silent detach (#522).
  defp all_pickable_tags(org_tags, record_tags) do
    known = MapSet.new(org_tags, & &1.id)
    org_tags ++ Enum.reject(record_tags, &MapSet.member?(known, &1.id))
  end

  # Bucket the org's tags into the picker's sections.
  #
  # A group applies to this content type when its `content_types` is empty
  # ("every type") or names `kind`. Non-applicable groups are hidden — EXCEPT
  # for tags already on the record, which are collected into a trailing
  # "Also attached" section.
  #
  # That last part is load-bearing, not a nicety: tags are written with
  # `manage_relationship(:tag_ids, :tags, type: :append_and_remove)`, so a
  # checkbox that isn't rendered isn't submitted, and the link is *removed*.
  # Narrowing a group's content types after the fact would otherwise silently
  # strip tags off existing content the next time someone hit Save.
  defp tag_sections(tags, groups, kind, selected, attached) do
    kind = to_string(kind)
    known_ids = MapSet.new(groups, & &1.id)
    applicable = Enum.filter(groups, &applies_to?(&1, kind))
    applicable_ids = MapSet.new(applicable, & &1.id)
    by_bucket = Enum.group_by(tags, &bucket_for(&1, known_ids, applicable_ids))

    grouped =
      Enum.map(applicable, fn group ->
        section(group.name, Map.get(by_bucket, {:group, group.id}, []), selected)
      end)

    ungrouped = section(gettext("Ungrouped"), Map.get(by_bucket, :ungrouped, []), selected)

    # Out-of-scope groups contribute only what the record ALREADY carries.
    # Keyed on `attached` (the persisted set) rather than `selected` (the live
    # ticks): keying on the latter meant unchecking a tag here emptied the
    # section, `Enum.reject` deleted it, and there was no control left to undo
    # with — an irreversible detach one mis-click away.
    orphaned_tags =
      by_bucket
      |> Map.get(:out_of_scope, [])
      |> Enum.filter(&(to_string(&1.id) in attached))

    orphaned =
      section(
        gettext("Also attached"),
        orphaned_tags,
        selected,
        gettext("Already on this item, from a group scoped to other content types.")
      )

    Enum.reject(grouped ++ [ungrouped, orphaned], &(&1.tags == []))
  end

  # Which section a tag belongs in. A `tag_group_id` that resolves to no loaded
  # group — a dangling pointer, or one written across tenants (the FK has no
  # org component) — falls back to "Ungrouped" rather than vanishing: an
  # unrendered checkbox is a checkbox that isn't submitted, and
  # `append_and_remove` reads that as "detach me".
  defp bucket_for(%{tag_group_id: nil}, _known_ids, _applicable_ids), do: :ungrouped

  defp bucket_for(%{tag_group_id: id}, known_ids, applicable_ids) do
    cond do
      MapSet.member?(applicable_ids, id) -> {:group, id}
      MapSet.member?(known_ids, id) -> :out_of_scope
      true -> :ungrouped
    end
  end

  defp applies_to?(%{content_types: []}, _kind), do: true
  defp applies_to?(%{content_types: types}, kind) when is_list(types), do: kind in types
  defp applies_to?(_group, _kind), do: true

  # Sections holding a selection start expanded, so what's already on the item
  # is visible without clicking through every group.
  defp section(label, tags, selected, note \\ nil) do
    count = Enum.count(tags, &(to_string(&1.id) in selected))

    %{label: label, tags: tags, selected_count: count, open?: count > 0, note: note}
  end

  # Featured-image chooser (#154): a thumbnail of the current selection plus a
  # button that opens the searchable media picker, replacing a <select> that
  # loaded every asset. The id is carried in a hidden input so it still submits.
  # One input for an admin-defined custom field (KilnCMS.CMS.FieldDefinition).
  # Inputs are named into the content form's `custom_fields` map
  # (`form[custom_fields][<name>]`); the write change coerces/validates them.
  attr :definition, :map, required: true
  attr :name, :string, required: true
  attr :value, :any, required: true
  attr :errors, :list, default: []
  attr :options, :list, default: []

  # Media / reference pick-lists: the select posts the target id; the stored
  # value is the write-time snapshot map (see ApplyCustomFields), so the
  # current selection is its "id".
  defp custom_field_input(%{definition: %{field_type: type}} = assigns)
       when type in [:media, :reference] do
    assigns = assign(assigns, :selected_id, snapshot_id(assigns.value))

    ~H"""
    <div>
      <label for={cf_id(@definition)} class="mb-1 block text-sm font-medium">
        {@definition.label}
      </label>
      <select
        id={cf_id(@definition)}
        name={@name}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@errors != [] && cf_errors_id(@definition)}
        class="field-select"
      >
        <option value="">{gettext("— None —")}</option>
        <option :for={{label, id} <- @options} value={id} selected={@selected_id == id}>
          {label}
        </option>
      </select>
      <p :if={@definition.help_text} class="mt-1 text-xs text-base-content/60">
        {@definition.help_text}
      </p>
      <.custom_field_errors_list definition={@definition} errors={@errors} />
    </div>
    """
  end

  defp custom_field_input(%{definition: %{field_type: :boolean}} = assigns) do
    assigns = assign(assigns, :checked, assigns.value in [true, "true", "1", "on"])

    ~H"""
    <div>
      <label class="flex items-center gap-2 text-sm">
        <%!-- hidden "false" first so an unchecked box still submits a value (last wins) --%>
        <input type="hidden" name={@name} value="false" />
        <input
          type="checkbox"
          name={@name}
          value="true"
          checked={@checked}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@errors != [] && cf_errors_id(@definition)}
        />
        <span class="font-medium">{@definition.label}</span>
        <span :if={@definition.help_text} class="text-base-content/60">— {@definition.help_text}</span>
      </label>
      <.custom_field_errors_list definition={@definition} errors={@errors} />
    </div>
    """
  end

  defp custom_field_input(%{definition: %{field_type: :select}} = assigns) do
    ~H"""
    <div>
      <label for={cf_id(@definition)} class="mb-1 block text-sm font-medium">
        {@definition.label}
      </label>
      <select
        id={cf_id(@definition)}
        name={@name}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@errors != [] && cf_errors_id(@definition)}
        class="field-select"
      >
        <option value="">{gettext("— None —")}</option>
        <option :for={opt <- @definition.options} value={opt} selected={to_string(@value) == opt}>
          {opt}
        </option>
      </select>
      <p :if={@definition.help_text} class="mt-1 text-xs text-base-content/60">
        {@definition.help_text}
      </p>
      <.custom_field_errors_list definition={@definition} errors={@errors} />
    </div>
    """
  end

  defp custom_field_input(%{definition: %{field_type: :text}} = assigns) do
    ~H"""
    <div>
      <label for={cf_id(@definition)} class="mb-1 block text-sm font-medium">
        {@definition.label}
      </label>
      <textarea
        id={cf_id(@definition)}
        name={@name}
        required={@definition.required}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@errors != [] && cf_errors_id(@definition)}
        class="field-input"
      >{@value}</textarea>
      <p :if={@definition.help_text} class="mt-1 text-xs text-base-content/60">
        {@definition.help_text}
      </p>
      <.custom_field_errors_list definition={@definition} errors={@errors} />
    </div>
    """
  end

  # Everything else is registry-driven. A composite field type
  # (`Kiln.FieldType` declaring `input_parts/1`, e.g. `:geolocation`) renders a
  # labelled input per part; anything else renders a single `<input>`.
  defp custom_field_input(assigns) do
    case field_type_parts(assigns.definition) do
      [] -> scalar_custom_field_input(assigns)
      parts -> composite_custom_field_input(assign(assigns, :parts, parts))
    end
  end

  # The composite parts a field type declares, or `[]` for core/scalar types.
  # `input_parts/1` is optional on `Kiln.FieldType` (a hand-rolled `@behaviour`
  # module from an out-of-tree plugin may predate it), so fall back to a scalar
  # input rather than crashing on an undefined function.
  #
  # `Code.ensure_loaded?/1` is not optional here: `function_exported?/3` answers
  # false for a module that is compiled but not yet *loaded*, and nothing loads
  # a field-type module at runtime — the registry is built at compile time and
  # only carries the atom. Without it, the first editor render after boot
  # silently degrades a composite field to a single text input, and submitting
  # that input wipes the stored value.
  defp field_type_parts(definition) do
    with module when not is_nil(module) <- KilnCMS.CMS.FieldTypes.get(definition.field_type),
         true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :input_parts, 1) do
      module.input_parts(definition)
    else
      _no_parts -> []
    end
  end

  # Each part is named into the field's own map —
  # `…[custom_fields][<field>][<part>]` — so the whole map arrives at `cast/2`
  # as a unit. A fieldset rather than a label, because the group has several
  # controls and only the legend names them all.
  defp composite_custom_field_input(assigns) do
    ~H"""
    <fieldset aria-required={@definition.required && "true"}>
      <legend class="mb-1 block text-sm font-medium">{@definition.label}</legend>
      <div class="grid grid-cols-2 gap-2">
        <div :for={part <- @parts}>
          <.composite_part
            definition={@definition}
            part={part}
            name={@name}
            value={@value}
            errors={@errors}
          />
        </div>
      </div>
      <p :if={@definition.help_text} class="mt-1 text-xs text-base-content/60">
        {@definition.help_text}
      </p>
      <.custom_field_errors_list definition={@definition} errors={@errors} />
    </fieldset>
    """
  end

  # A boolean part (`type: "checkbox"`) is not a text input with a different
  # `type=`. On a checkbox `value=` is what gets *submitted*, not what is
  # *checked* — binding the stored value there means a saved `all_day: true`
  # reopens unchecked, and a stored `false` renders `value="false"`, so ticking
  # the box submits the string "false" and the flag can never be turned on.
  #
  # So: a fixed `value="true"` and `checked` from the stored value.
  #
  # And deliberately **no** hidden `false` companion, which is the usual Phoenix
  # pairing. `ApplyCustomFields.blank_for?/2` calls a composite field empty when
  # every part is blank, and `"false"` is not blank — so the companion made an
  # untouched widget look filled-in, and an *optional* `datetime_range` field
  # made every document of its type unsaveable with "start is required". An
  # absent key already means false to `cast/2`, so unticking needs nothing.
  defp composite_part(%{part: %{type: "checkbox"}} = assigns) do
    ~H"""
    <label class="mt-5 flex items-center gap-2 text-xs text-base-content/70">
      <input
        id={cf_part_id(@definition, @part)}
        type="checkbox"
        name={"#{@name}[#{@part.key}]"}
        value="true"
        checked={composite_part_checked?(@value, @part.key)}
        aria-describedby={@errors != [] && cf_errors_id(@definition)}
        class="size-4 rounded border border-base-content/30 accent-primary"
        {Map.get(@part, :attrs, %{})}
      />
      {@part.label}
    </label>
    """
  end

  defp composite_part(assigns) do
    ~H"""
    <label for={cf_part_id(@definition, @part)} class="mb-0.5 block text-xs text-base-content/70">
      {@part.label}
    </label>
    <input
      id={cf_part_id(@definition, @part)}
      type={Map.get(@part, :type, "text")}
      name={"#{@name}[#{@part.key}]"}
      value={composite_part_value(@value, @part.key)}
      required={@definition.required && Map.get(@part, :required?, true)}
      aria-invalid={@errors != [] && "true"}
      aria-describedby={@errors != [] && cf_errors_id(@definition)}
      class="field-input"
      {Map.get(@part, :attrs, %{})}
    />
    """
  end

  # The same spellings `Kiln.FieldType` implementations accept, because a value
  # arrives here either fresh from the form (a string) or round-tripped out of
  # jsonb (a boolean).
  defp composite_part_checked?(value, key) do
    case composite_part_value(value, key) do
      true -> true
      binary when is_binary(binary) -> String.downcase(binary) in ~w(true 1 on yes)
      _other -> false
    end
  end

  # A plain `<input>`. Plugin and built-in field types (`Kiln.FieldType`) pick
  # their HTML input kind + extra attributes (min/max/step/readonly/…) via the
  # registry; core types map below.
  defp scalar_custom_field_input(assigns) do
    definition = assigns.definition

    {input_type, extra} =
      case KilnCMS.CMS.FieldTypes.get(definition.field_type) do
        nil -> {custom_input_type(definition.field_type), %{}}
        module -> {module.input_type(), module.input_attrs(definition)}
      end

    extra =
      if input_type == "number" and definition.field_type == :float,
        do: Map.put_new(extra, :step, "any"),
        else: extra

    assigns = assigns |> assign(:input_type, input_type) |> assign(:extra, extra)

    ~H"""
    <div>
      <label for={cf_id(@definition)} class="mb-1 block text-sm font-medium">
        {@definition.label}
      </label>
      <input
        id={cf_id(@definition)}
        type={@input_type}
        name={@name}
        value={@value}
        required={@definition.required}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@errors != [] && cf_errors_id(@definition)}
        class="field-input"
        {@extra}
      />
      <p :if={@definition.help_text} class="mt-1 text-xs text-base-content/60">
        {@definition.help_text}
      </p>
      <.custom_field_errors_list definition={@definition} errors={@errors} />
    </div>
    """
  end

  attr :definition, :map, required: true
  attr :errors, :list, required: true

  defp custom_field_errors_list(assigns) do
    ~H"""
    <div :if={@errors != []} id={cf_errors_id(@definition)}>
      <p :for={message <- @errors} class="mt-1 flex items-center gap-1 text-xs text-error">
        <.icon name="hero-exclamation-circle" class="size-4" /> {message}
      </p>
    </div>
    """
  end

  defp cf_id(definition), do: "custom-field-#{definition.name}"
  defp cf_errors_id(definition), do: "custom-field-#{definition.name}-errors"
  defp cf_part_id(definition, part), do: "custom-field-#{definition.name}-#{part.key}"

  # One part of a composite value: the stored/mid-edit map's entry for that key.
  # The value may still be the raw param map during a validate round-trip, so
  # accept string keys only (jsonb and form params both give strings).
  defp composite_part_value(value, key) when is_map(value), do: Map.get(value, key)
  defp composite_part_value(_value, _key), do: nil

  # The current selection for a pick-list field: the stored snapshot's id, or
  # the raw id while a change is mid-validate.
  defp snapshot_id(%{"id" => id}), do: id
  defp snapshot_id(id) when is_binary(id) and id != "", do: id
  defp snapshot_id(_other), do: nil

  defp custom_input_type(:integer), do: "number"
  defp custom_input_type(:float), do: "number"
  defp custom_input_type(:date), do: "date"
  defp custom_input_type(:datetime), do: "datetime-local"
  defp custom_input_type(:url), do: "url"
  defp custom_input_type(_), do: "text"

  # Current value of one custom field, from the form's `custom_fields` map
  # (param value mid-edit, otherwise the record's stored value). Keys are always
  # strings (jsonb / form params).
  defp custom_field_value(form, name) do
    case AshPhoenix.Form.value(form, :custom_fields) do
      map when is_map(map) -> Map.get(map, name)
      _ -> nil
    end
  end

  # Validation messages `ApplyCustomFields` attached for one definition — the
  # errors land on the `:custom_fields` attribute with the field's name in
  # `value`, so they'd otherwise never render anywhere (audit U-H2).
  defp custom_field_errors(form, name) do
    form
    |> changeset_errors()
    |> Enum.filter(fn
      %Ash.Error.Changes.InvalidAttribute{field: :custom_fields, value: value} -> value == name
      _ -> false
    end)
    |> Enum.map(& &1.message)
  end

  defp any_custom_field_errors?(form, definitions),
    do: Enum.any?(definitions, &(custom_field_errors(form, &1.name) != []))

  attr :draft, :any, required: true
  attr :fields, :list, required: true
  attr :dismissed, :any, required: true
  attr :locked_fields, :any, required: true

  # Proposed values, one card per field, each accepted or dismissed on its own.
  # Nothing here writes anything — every value needs a human click, which is
  # the primary control on a generated string reaching a public `<meta>` tag.
  defp seo_suggestions(assigns) do
    assigns = assign(assigns, :pending, Enum.reject(assigns.fields, &(&1 in assigns.dismissed)))

    ~H"""
    <div :if={@pending != []} class="mt-2 space-y-2">
      <div class="flex items-center justify-between gap-2">
        <span class="text-xs font-medium text-base-content/70">
          {gettext("Suggestions")}
        </span>
        <div class="flex items-center gap-2">
          <button type="button" phx-click="seo_accept_all" class="text-xs underline">
            {gettext("Use all")}
          </button>
          <button
            type="button"
            phx-click="seo_dismiss_all"
            class="text-xs text-base-content/60 underline"
          >
            {gettext("Dismiss")}
          </button>
        </div>
      </div>

      <div
        :for={field <- @pending}
        class="rounded border border-base-content/15 bg-base-200/40 p-2"
      >
        <p class="text-xs font-medium text-base-content/60">{seo_field_label(field)}</p>
        <p class="mt-0.5 text-xs break-words">{seo_suggestion_value(@draft, field)}</p>
        <div class="mt-1.5 flex items-center gap-2">
          <button
            type="button"
            phx-click="seo_accept"
            phx-value-field={field}
            disabled={field_locked?(@locked_fields, field)}
            class="btn btn-sm btn-default"
          >
            {gettext("Use")}
          </button>
          <button
            type="button"
            phx-click="seo_dismiss"
            phx-value-field={field}
            class="text-xs text-base-content/60 hover:text-base-content"
          >
            {gettext("Dismiss")}
          </button>
          <span class="ml-auto text-xs text-base-content/50">
            {seo_suggestion_length(@draft, field)}
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp seo_field_label("seo_title"), do: gettext("SEO title")
  defp seo_field_label("seo_description"), do: gettext("SEO description")
  defp seo_field_label("seo_keywords"), do: gettext("SEO keywords")
  defp seo_field_label(field), do: field

  defp seo_suggestion_value(draft, field), do: suggested_value(draft, field)

  # Character count against the band the analyzer checks, so the author can see
  # a proposal is in range before accepting it.
  defp seo_suggestion_length(draft, field) do
    length = draft |> suggested_value(field) |> to_string() |> String.length()

    case field do
      "seo_title" -> "#{length}/#{KilnCMS.Seo.title_max()}"
      "seo_description" -> "#{length}/#{KilnCMS.Seo.description_max()}"
      _ -> ""
    end
  end

  attr :block_id, :string, required: true
  attr :open?, :boolean, required: true
  attr :action, :atom, required: true
  attr :running?, :boolean, required: true
  attr :result, :any, default: nil
  attr :egress?, :boolean, required: true
  attr :provider, :string, default: nil
  attr :conflict, :boolean, required: true

  # Per-block AI assist (#60): the second half of this issue, the first being
  # the metadata drafting in the SEO panel.
  #
  # Sits *outside* the block's `phx-update="ignore"` host — LiveView cannot
  # patch inside one, so a panel rendered in there would never update. The
  # suggestion is shown as plain paragraphs and applied only by a human click,
  # which is the primary control on generated prose reaching a published page.
  defp assist_panel(assigns) do
    ~H"""
    <div class="mt-2">
      <%!-- `type="button"` is mandatory: this sits inside the main <.form>, so
            the default type would submit it. --%>
      <button
        type="button"
        phx-click={if @open?, do: "assist_close", else: "assist_open"}
        phx-value-bid={@block_id}
        aria-expanded={to_string(@open?)}
        class="inline-flex items-center gap-1 rounded border border-base-content/20 px-2 py-0.5 text-xs hover:bg-base-200"
      >
        <.icon name="hero-sparkles" class="size-3.5" />{gettext("AI assist")}
      </button>

      <div
        :if={@open?}
        class="mt-2 space-y-2 rounded border border-base-content/15 bg-base-200/40 p-2"
      >
        <div
          role="group"
          aria-label={gettext("What should the model do?")}
          class="flex flex-wrap gap-1"
        >
          <button
            :for={action <- KilnCMS.Assist.Action.all()}
            type="button"
            phx-click="assist_action"
            phx-value-action={action.id}
            aria-pressed={to_string(@action == action.id)}
            class={[
              "rounded border px-2 py-0.5 text-xs",
              if(@action == action.id,
                do: "border-primary bg-primary text-primary-content",
                else: "border-base-content/20 hover:bg-base-200"
              )
            ]}
          >
            {assist_action_label(action.id)}
          </button>
        </div>

        <p class="text-xs text-base-content/70">{assist_action_hint(@action)}</p>

        <%!-- Unprefixed name, so the main form's `validate` (which reads only
              "form") never sees it; its own phx-change keeps typing here from
              marking the record dirty.

              `phx-debounce="blur"`, not a millisecond value: this input sits
              inside the main content form, and LiveView serializes the WHOLE
              enclosing form on every change — title, every SEO field, every
              block's inputs. On a timer that is the entire form uploaded every
              few hundred milliseconds so the server can read one key. Clicking
              Generate blurs the input first, so the value still lands before
              the run.

              The value is deliberately NOT fed back: the browser owns the text
              (the panel is freshly mounted each time it opens, always empty),
              which keeps `@assist_instruction` out of the block comprehension —
              reading it there re-rendered and re-sent every block on the page
              per keystroke — and keeps the server from fighting the caret. --%>
        <%!-- A textarea, not a text input: a single-line input inside a form
              that has a submit button submits it on Enter, so typing an
              instruction and pressing Enter saved the record — publishing to
              the live URL — instead of generating anything. --%>
        <textarea
          name="assist_instruction"
          rows="2"
          phx-change="assist_instruction"
          phx-debounce="blur"
          maxlength={KilnCMS.Assist.max_instruction_chars()}
          aria-label={gettext("Instruction for the model")}
          placeholder={gettext("Optional: what should it say? (required for Draft)")}
          class="field-input text-xs"
        ></textarea>

        <div class="flex items-center gap-2">
          <button
            type="button"
            phx-click="assist_run"
            phx-value-bid={@block_id}
            disabled={@running? or @conflict}
            class="btn btn-sm btn-default"
          >
            {gettext("Generate")}
            <.icon
              :if={@running?}
              name="hero-arrow-path"
              class="ml-1 size-3 motion-safe:animate-spin"
            />
          </button>
          <button
            type="button"
            phx-click="assist_close"
            class="text-xs text-base-content/60 underline hover:text-base-content"
          >
            {gettext("Close")}
          </button>
        </div>

        <%!-- Standing, non-dismissible: the operator chose a third-party
              provider, the editor clicking didn't. --%>
        <p :if={@egress?} class="text-xs text-warning">
          {gettext(
            "Text is generated by %{provider}. This block's content, the page's title and headings, and your instruction are sent to that provider.",
            provider: @provider
          )}
        </p>

        <div :if={@result} class="rounded border border-base-content/15 bg-base-100 p-2">
          <p class="text-xs font-medium text-base-content/60">
            {gettext("Suggestion")} · {ngettext("%{count} word", "%{count} words", @result.word_count,
              count: @result.word_count
            )}
          </p>
          <%!-- Rendered as text nodes, never raw: a model talked into emitting
                markup shows the markup, which nobody clicks Insert on. --%>
          <p :for={paragraph <- @result.paragraphs} class="mt-1 text-xs break-words">
            {paragraph}
          </p>
          <p :if={@result.truncated?} class="mt-1 text-xs text-base-content/50">
            {gettext("Cut to fit the length limit.")}
          </p>
          <div class="mt-2 flex flex-wrap items-center gap-2">
            <button
              type="button"
              phx-click="assist_apply"
              phx-value-mode="insert"
              class="btn btn-sm btn-default"
            >
              {gettext("Insert at cursor")}
            </button>
            <button
              type="button"
              phx-click="assist_apply"
              phx-value-mode="replace"
              data-confirm={
                gettext("Replace everything in this block? You can undo it in the editor.")
              }
              class="rounded border border-base-content/20 px-2 py-0.5 text-xs hover:bg-base-200"
            >
              {gettext("Replace block")}
            </button>
            <button
              type="button"
              phx-click="assist_dismiss"
              class="text-xs text-base-content/60 underline hover:text-base-content"
            >
              {gettext("Dismiss")}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :tasks, :list, required: true
  attr :open?, :boolean, required: true
  attr :draft, :map, required: true
  attr :assignable_users, :list, required: true

  # Editorial tasks (#501): the whole record's open tasks (usually zero or
  # one — v1 doesn't cap it), plus an inline "+ Assign" form. Document-level,
  # not block-level (unlike `comment_panel/1` below) — a task is "who owns
  # getting this whole piece of content done," not feedback on one block.
  #
  # No `<form>` here, same reason `comment_panel/1` avoids one (see its own
  # moduledoc note): this whole section lives inside the page's own
  # `id="page-editor"` form, and HTML doesn't allow nested forms — a nested
  # `<form phx-submit=…>` silently gets dropped by the parser (its child
  # inputs survive, the tag itself vanishes), so `phx-submit` never fires.
  # Each field tracks its own `phx-change` into `@draft`; the submit button
  # is a plain `phx-click` reading that assign server-side.
  defp task_list(assigns) do
    ~H"""
    <div class="space-y-2">
      <p :if={@tasks == []} class="text-xs text-base-content/60">
        {gettext("No open tasks.")}
      </p>

      <ul :if={@tasks != []} class="space-y-2">
        <li :for={task <- @tasks} class="rounded border border-base-content/15 p-2 text-xs">
          <div class="flex items-center justify-between gap-2">
            <span class="font-medium">{user_label(task.assignee)}</span>
            <button
              type="button"
              phx-click="task_complete"
              phx-value-id={task.id}
              class="text-primary hover:underline"
            >
              {gettext("Mark done")}
            </button>
          </div>
          <p :if={task.due_on} class="text-base-content/60">
            {gettext("Due %{date}", date: Date.to_iso8601(task.due_on))}
          </p>
          <p :if={task.note} class="mt-1 text-base-content/70">{task.note}</p>
        </li>
      </ul>

      <button
        :if={!@open?}
        type="button"
        phx-click="task_assign_open"
        class="btn btn-sm btn-default"
      >
        {gettext("+ Assign")}
      </button>

      <div :if={@open?} class="space-y-2 rounded border border-base-content/15 p-2">
        <select name="task_assignee_id" phx-change="task_draft_change" class="select select-sm w-full">
          <option value="">{gettext("Assign to…")}</option>
          <option
            :for={{label, id} <- @assignable_users}
            value={id}
            selected={@draft["assignee_id"] == id}
          >
            {label}
          </option>
        </select>
        <input
          type="date"
          name="task_due_on"
          phx-change="task_draft_change"
          value={@draft["due_on"]}
          class="input input-sm w-full"
        />
        <textarea
          name="task_note"
          phx-change="task_draft_change"
          phx-debounce="blur"
          placeholder={gettext("Note (optional)")}
          class="textarea textarea-sm w-full"
        >{@draft["note"]}</textarea>
        <div class="flex justify-end gap-2">
          <button type="button" phx-click="task_assign_close" class="btn btn-sm btn-default">
            {gettext("Cancel")}
          </button>
          <button type="button" phx-click="task_assign_submit" class="btn btn-sm btn-primary">
            {gettext("Assign")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :item, :map, default: nil
  attr :release, :map, default: nil
  attr :releases, :list, required: true
  attr :draft, :map, required: true

  # Content releases (#500 / #836): which release this record is queued in, or a
  # picker to put it in one — the editor-side half of "add to release", which
  # until now existed only as a bulk action on the content list.
  #
  # No `<form>`, for the reason `task_list/1` and `comment_panel/1` spell out:
  # this renders inside the page's own `id="page-editor"` form, HTML forbids
  # nested forms, and the parser silently drops the tag (keeping its inputs), so
  # `phx-submit` would never fire and the button would appear to do nothing.
  defp release_panel(assigns) do
    ~H"""
    <div class="space-y-2">
      <%= if @item do %>
        <div class="rounded border border-base-content/15 p-2 text-xs">
          <p class="font-medium">
            <.link :if={@release} navigate={~p"/editor/releases/#{@release.id}"} class="link">
              {@release.name}
            </.link>
            <span :if={!@release}>{gettext("In a release")}</span>
          </p>
          <p class="mt-1 text-base-content/70">
            {if @item.action == :unpublish,
              do: gettext("Will be unpublished when the release goes live."),
              else: gettext("Will be published when the release goes live.")}
          </p>
          <button
            type="button"
            phx-click="release_remove"
            class="mt-2 text-primary hover:underline"
          >
            {gettext("Remove from release")}
          </button>
        </div>
      <% else %>
        <p :if={@releases == []} class="text-xs text-base-content/60">
          {gettext("No open releases.")}
          <.link navigate={~p"/editor/releases"} class="link">{gettext("Create one")}</.link>
        </p>

        <div :if={@releases != []} class="space-y-2">
          <select
            name="release_target"
            phx-change="release_draft_change"
            aria-label={gettext("Release")}
            class="select select-sm w-full"
          >
            <option
              :for={release <- @releases}
              value={release.id}
              selected={@draft["release_id"] == release.id}
            >
              {release.name}
            </option>
          </select>
          <select
            name="release_action"
            phx-change="release_draft_change"
            aria-label={gettext("On go-live")}
            class="select select-sm w-full"
          >
            <option value="publish" selected={@draft["action"] != "unpublish"}>
              {gettext("Publish on go-live")}
            </option>
            <option value="unpublish" selected={@draft["action"] == "unpublish"}>
              {gettext("Unpublish on go-live")}
            </option>
          </select>
          <button type="button" phx-click="release_add" class="btn btn-sm btn-default w-full">
            {gettext("Add to release")}
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  attr :block_id, :string, required: true
  attr :comments, :list, required: true
  attr :open?, :boolean, required: true
  attr :draft, :string, default: nil

  # Block-level editorial comment thread (#404) — same toggle-button-into-
  # inline-panel shape as `assist_panel/1` above, and the same reason the
  # textarea keeps its own unprefixed `phx-change`/`phx-debounce="blur"`
  # rather than living inside a `<form>`: this sits inside the main content
  # form, which can't nest one.
  #
  # Unlike `assist_panel/1`, rendered for every block type (outside all the
  # per-type conditionals) — a comment can land on any block, not just rich
  # text.
  defp comment_panel(assigns) do
    thread = thread_for_block(assigns.comments, assigns.block_id)
    assigns = assign(assigns, :thread, thread)

    ~H"""
    <div class="mt-2">
      <button
        type="button"
        phx-click={if @open?, do: "comment_close", else: "comment_open"}
        phx-value-bid={@block_id}
        aria-expanded={to_string(@open?)}
        class={[
          "inline-flex items-center gap-1 rounded border px-2 py-0.5 text-xs hover:bg-base-200",
          if(thread_resolved?(@thread),
            do: "border-base-content/20 text-base-content/50",
            else: "border-base-content/20"
          )
        ]}
      >
        <.icon name="hero-chat-bubble-left-right" class="size-3.5" />
        {if @thread == [],
          do: gettext("Comment"),
          else:
            ngettext("%{count} comment", "%{count} comments", length(@thread), count: length(@thread))}
        <span :if={thread_resolved?(@thread)} class="text-success">
          · {gettext("Resolved")}
        </span>
      </button>

      <div
        :if={@open?}
        class="mt-2 space-y-2 rounded border border-base-content/15 bg-base-200/40 p-2"
      >
        <div :if={@thread == []} class="text-xs text-base-content/60">
          {gettext("No comments on this block yet.")}
        </div>

        <div :for={comment <- @thread} class="rounded bg-base-100 p-2 text-xs">
          <div class="flex items-center justify-between gap-2 text-base-content/60">
            <span>{comment_author_label(comment)}</span>
            <time datetime={DateTime.to_iso8601(comment.inserted_at)}>
              {Calendar.strftime(comment.inserted_at, "%b %-d, %H:%M")}
            </time>
          </div>
          <%!-- Rendered as a text node, never raw markup: a comment is
                editor-typed prose, not HTML. --%>
          <p class="mt-1 break-words">{comment.body}</p>
          <button
            :if={is_nil(comment.thread_id)}
            type="button"
            phx-click={if comment.resolved_at, do: "comment_unresolve", else: "comment_resolve"}
            phx-value-id={comment.id}
            class="mt-1 text-base-content/60 underline hover:text-base-content"
          >
            {if comment.resolved_at, do: gettext("Reopen thread"), else: gettext("Resolve thread")}
          </button>
        </div>

        <%!-- See `assist_panel/1`'s textarea for why this is unprefixed with
              its own phx-change/phx-debounce="blur" rather than a nested
              <form>: the Send button reads @comment_draft (synced on blur),
              never anything from its own click event. --%>
        <textarea
          name="comment_body"
          rows="2"
          phx-change="comment_draft"
          phx-debounce="blur"
          aria-label={gettext("Write a comment")}
          placeholder={gettext("Write a comment…")}
          class="field-input text-xs"
        >{@draft}</textarea>

        <div class="flex items-center gap-2">
          <button
            type="button"
            phx-click="comment_add"
            phx-value-bid={@block_id}
            class="btn btn-sm btn-default"
          >
            {gettext("Send")}
          </button>
          <button
            type="button"
            phx-click="comment_close"
            class="text-xs text-base-content/60 underline hover:text-base-content"
          >
            {gettext("Close")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  # This block's thread, oldest first — the root (if any) followed by its
  # replies. `RouteToBlockThread` guarantees every comment sharing a block id
  # already belongs to the same one thread, so no grouping-by-thread-id is
  # needed here; `comments` is already sorted by `inserted_at` from
  # `list_comments_for!`.
  defp thread_for_block(comments, block_id),
    do: Enum.filter(comments, &(&1.block_id == block_id))

  # A thread with no comments yet is not "resolved" — there's nothing to
  # reopen. Otherwise resolved iff its root (thread_id: nil) carries a
  # resolved_at.
  defp thread_resolved?([]), do: false
  defp thread_resolved?(thread), do: Enum.any?(thread, &(is_nil(&1.thread_id) and &1.resolved_at))

  defp comment_author_label(%{author: %{name: name}}) when is_binary(name) and name != "",
    do: name

  defp comment_author_label(%{author: %{email: email}}) when not is_nil(email),
    do: to_string(email)

  defp comment_author_label(_comment), do: gettext("Someone")

  attr :form, :any, required: true
  attr :media, :list, required: true
  attr :current_org, :any, required: true

  # How a shared link to this page will look (#476).
  #
  # The fallbacks here mirror `KilnCMSWeb.ContentController.render_content_body/6`
  # exactly — title falls back to `title`, description and image do **not** fall
  # back at all. A preview that flattered the record by inventing fallbacks
  # delivery doesn't have would be worse than no preview.
  defp social_card(assigns) do
    image = AshPhoenix.Form.value(assigns.form, :seo_image)
    title = AshPhoenix.Form.value(assigns.form, :seo_title)
    fallback_title = AshPhoenix.Form.value(assigns.form, :title)

    assigns =
      assigns
      |> assign(:card_image, blank_to_nil(image))
      |> assign(:card_title, blank_to_nil(title) || blank_to_nil(fallback_title))
      |> assign(
        :card_description,
        blank_to_nil(AshPhoenix.Form.value(assigns.form, :seo_description))
      )
      |> assign(:card_host, public_host(assigns.current_org))

    ~H"""
    <div>
      <span class="mb-1 block text-sm font-medium text-base-content">
        {gettext("Social preview")}
      </span>
      <div class="overflow-hidden rounded border border-base-content/15">
        <img
          :if={@card_image}
          src={@card_image}
          alt=""
          class="aspect-[1.91/1] w-full bg-base-200 object-cover"
        />
        <div
          :if={!@card_image}
          class="flex aspect-[1.91/1] w-full items-center justify-center bg-base-200 text-xs text-base-content/50"
        >
          {gettext("No social image")}
        </div>
        <div class="space-y-0.5 border-t border-base-content/10 p-2">
          <p class="text-xs uppercase text-base-content/50">{@card_host}</p>
          <p class="truncate text-sm font-medium">
            {@card_title || gettext("Untitled")}
          </p>
          <p class="line-clamp-2 text-xs text-base-content/70">
            {@card_description || gettext("No description — search engines will write their own.")}
          </p>
        </div>
      </div>
    </div>
    """
  end

  defp blank_to_nil(value) do
    case String.trim(to_string(value || "")) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp public_host(org) do
    case URI.parse(KilnCMSWeb.Tenant.base_url(org)) do
      %URI{host: host} when is_binary(host) -> host
      _ -> ""
    end
  end

  attr :form, :any, required: true
  attr :media, :list, required: true

  defp featured_image_field(assigns) do
    id = AshPhoenix.Form.value(assigns.form, :featured_image_id)

    assigns =
      assigns
      |> assign(:field, assigns.form[:featured_image_id])
      |> assign(:selected, Enum.find(assigns.media, &(to_string(&1.id) == to_string(id))))

    ~H"""
    <div>
      <span class="mb-1 block text-sm font-medium text-base-content">
        {gettext("Featured image")}
      </span>
      <input type="hidden" name={@field.name} value={@field.value} />
      <div class="mt-1 flex flex-wrap items-center gap-3">
        <img
          :if={@selected}
          src={@selected.url}
          alt=""
          class="h-16 w-16 rounded border border-base-content/10 object-cover"
        />
        <span class="text-sm text-base-content/70">
          {(@selected && @selected.filename) || gettext("None selected")}
        </span>
        <button
          type="button"
          phx-click="open_featured_picker"
          class="btn btn-sm btn-default"
        >
          {gettext("Choose from library")}
        </button>
        <button
          :if={@selected}
          type="button"
          phx-click="clear_featured"
          class="text-sm text-base-content/70 hover:text-error"
        >
          {gettext("Remove")}
        </button>
      </div>
    </div>
    """
  end

  # Server-side substring search over filename/alt/caption (audit U-M2): finds
  # items beyond the mounted picker window, and matches partial input as the
  # user types (the library's `:search` action is whole-word tsquery, less
  # forgiving for a live picker). %, _ and \ in the input match literally.
  #
  # `kind` filters to the same image/document split the mounted `@media`/
  # `@file_media` lists use (#481) — the image picker must never surface a
  # document it can't render as an `<img>`, and vice versa.
  defp search_media(q, actor, org, kind \\ :image) do
    pattern = "%" <> String.replace(q, ~r/([\\%_])/, "\\\\\\1") <> "%"

    text_filter =
      expr(ilike(filename, ^pattern) or ilike(alt, ^pattern) or ilike(caption, ^pattern))

    CMS.list_media_items!(
      actor: actor,
      tenant: org,
      query: [
        filter: search_kind_filter(kind, text_filter),
        select: search_select(kind),
        sort: [inserted_at: :desc],
        limit: @max_media
      ]
    )
  end

  # Same kind split as the mounted `@media`/`@file_media`/`@av_media` lists
  # above, by `content_type` rather than `width` — see that comment. Every
  # clause here has a twin in the mount filters; `KilnCMS.MediaKind` is the
  # prose version of the same rule, but a filter has to run in Postgres.
  # Which library an open A/V drawer is browsing. `nil` (drawer closed) still
  # has to answer something, and `:av` is the harmless default — the search
  # result is discarded when the drawer isn't open.
  defp av_picker_kind({_bid, "poster"}), do: :image
  defp av_picker_kind({_bid, "captions"}), do: :captions
  defp av_picker_kind(_target), do: :av

  # The block fields each pick writes. `duration_seconds` rides along with the
  # media itself (it feeds the JSON-LD `duration` and the editor's summary
  # line) but is NOT written for the poster or the track — the poster's own
  # length is meaningless and a `.vtt` has none.
  defp av_block_patch("media", item) do
    %{
      "media_id" => item.id,
      "duration_seconds" => item.duration_seconds,
      # A pasted external URL and a library item are alternatives, not layers
      # (see `KilnCMS.Blocks.Video`'s `src/1`): leaving a stale `url` behind
      # would be invisible until the item was later cleared.
      "url" => nil
    }
  end

  defp av_block_patch("poster", item),
    do: %{"poster_media_id" => item.id, "poster_url" => nil}

  defp av_block_patch("captions", item),
    do: %{"captions_media_id" => item.id, "captions_label" => item.alt || item.filename}

  defp search_kind_filter(:image, text_filter),
    do: expr((is_nil(content_type) or ilike(content_type, "image/%")) and ^text_filter)

  # `:file` is "a document", NOT "not an image" — video, audio and caption
  # tracks (#494) are all non-image and none of them belongs in a picker whose
  # block renders a download link.
  defp search_kind_filter(:file, text_filter),
    do: expr(^document_filter() and ^text_filter)

  defp search_kind_filter(:av, text_filter),
    do: expr(^av_filter() and ^text_filter)

  defp search_kind_filter(:captions, text_filter),
    do: expr(content_type == "text/vtt" and ^text_filter)

  defp search_select(:image), do: [:id, :url, :alt, :caption, :filename]
  defp search_select(:file), do: [:id, :filename, :content_type, :byte_size, :audience]

  defp search_select(kind) when kind in [:av, :captions],
    do: [:id, :filename, :content_type, :byte_size, :audience, :duration_seconds, :variants]

  @doc false
  # Shared by the mount lists and the live search, so the two can't drift.
  # Both are plain `content_type` predicates: a NULL content_type is an image
  # (see the mount comment) and so is excluded from each.
  def document_filter do
    expr(
      not is_nil(content_type) and not ilike(content_type, "image/%") and
        not ilike(content_type, "video/%") and not ilike(content_type, "audio/%") and
        content_type != "text/vtt"
    )
  end

  @doc false
  def av_filter,
    do: expr(ilike(content_type, "video/%") or ilike(content_type, "audio/%"))

  # The `phx-value-index` for a pick button: "new" inserts a fresh image block
  # (browser opened from the chrome), an integer fills that existing block.
  defp pick_index(:new), do: "new"
  defp pick_index({:gallery, _id}), do: "gallery"
  defp pick_index(:featured), do: "featured"
  defp pick_index(:seo_image), do: "seo_image"
  defp pick_index({:block, _id}), do: "block"
  defp pick_index(_), do: ""

  # The target block's stable id for a per-block pick; nil for featured/new picks
  # (so no `phx-value-bid` attribute is emitted for those).
  defp pick_block_id({:block, id}), do: id
  defp pick_block_id({:gallery, id}), do: id
  defp pick_block_id(_), do: nil

  attr :block_types, :list, required: true
  attr :id, :string, default: "block-inserter"

  attr :anchor, :string,
    default: nil,
    doc: "insert anchor: a block id, \"start\", or nil (append)"

  attr :compact, :boolean, default: false, doc: "slim inline \"+\" trigger vs the full button"
  attr :global_key, :boolean, default: false, doc: "this instance owns the global \"/\" shortcut"

  # Notion-style slash-command block inserter (#29). The trigger button (or the
  # `/` shortcut, handled by the `BlockInserter` JS hook) opens a filterable,
  # keyboard-navigable menu listing every registered block type. Each option is a
  # real `add_block` button, so it works without JS and is directly testable;
  # the hook layers on filtering, arrow-key navigation, and ARIA wiring.
  #
  # Rendered once as the main "Add block" trigger (append) and again inline in
  # each block card as a compact "+" (B2 inline insertion). `after` rides along on
  # every option so the same menu can append or insert at a gap; only the main
  # instance owns the global "/" shortcut (`global_key`) so inline copies don't
  # all fire at once.
  defp block_inserter(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="BlockInserter"
      data-inserter-global={@global_key && "true"}
      class="relative"
    >
      <button
        :if={!@compact}
        type="button"
        data-inserter-trigger
        aria-haspopup="listbox"
        aria-expanded="false"
        aria-controls={"#{@id}-list"}
        class="inline-flex items-center gap-1.5 rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
      >
        <.icon name="hero-plus" class="size-4" />
        {gettext("Add block")}
        <kbd class="ml-1 rounded border border-base-content/20 px-1.5 text-xs opacity-60">/</kbd>
      </button>
      <button
        :if={@compact}
        type="button"
        data-inserter-trigger
        aria-haspopup="listbox"
        aria-expanded="false"
        aria-controls={"#{@id}-list"}
        aria-label={gettext("Insert block here")}
        class="group/ins flex w-full items-center gap-2 py-1 text-base-content/30 hover:text-base-content/70"
      >
        <span class="h-px flex-1 bg-current opacity-30 transition group-hover/ins:opacity-60"></span>
        <span class="inline-flex items-center gap-1 text-xs">
          <.icon name="hero-plus-circle" class="size-4" />{gettext("Insert")}
        </span>
        <span class="h-px flex-1 bg-current opacity-30 transition group-hover/ins:opacity-60"></span>
      </button>

      <div
        data-inserter-menu
        hidden
        class="absolute left-0 z-20 mt-1 w-72 rounded-lg border border-base-content/15 bg-base-100 p-1 shadow-lg"
      >
        <div class="p-1">
          <input
            type="text"
            data-inserter-search
            role="combobox"
            aria-autocomplete="list"
            aria-expanded="true"
            aria-controls={"#{@id}-list"}
            placeholder={gettext("Filter blocks…")}
            class="w-full rounded border border-base-content/20 bg-base-100 px-2 py-1 text-sm focus:outline-none focus:ring-2 focus:ring-primary/40"
          />
        </div>

        <ul
          id={"#{@id}-list"}
          data-inserter-list
          role="listbox"
          aria-label={gettext("Insert block")}
          class="max-h-72 overflow-y-auto"
        >
          <li :for={bt <- @block_types} role="presentation" data-inserter-option data-label={bt.label}>
            <button
              type="button"
              id={"#{@id}-item-#{bt.type}"}
              role="option"
              aria-selected="false"
              tabindex="-1"
              phx-click="add_block"
              phx-value-type={bt.type}
              phx-value-after={@anchor}
              data-inserter-item
              class="flex w-full items-start gap-2 rounded px-2 py-1.5 text-left text-sm hover:bg-base-200 aria-selected:bg-base-200"
            >
              <.icon name={bt.icon} class="mt-0.5 size-5 shrink-0 opacity-70" />
              <span class="min-w-0">
                <span class="block font-medium">{bt.label}</span>
                <span class="block truncate text-xs opacity-60">{bt.description}</span>
              </span>
            </button>
          </li>
        </ul>

        <p data-inserter-empty hidden class="px-3 py-2 text-sm opacity-60">
          {gettext("No blocks match.")}
        </p>
      </div>
    </div>
    """
  end

  attr :index, :any, required: true
  attr :media, :list, required: true
  attr :results, :list, default: nil
  attr :query, :string, required: true
  attr :picked, :list, default: []

  # Media-library browser as a right-side drawer (Theme D). It slides in beside the
  # editor rather than a full-screen modal that blanks the whole surface, so you
  # keep your place while choosing. Reachable from the editor chrome (insert a new
  # image block, `index = :new`), the featured-image field (`:featured`), or an
  # image block (`{:block, id}`). Browse + search + insert; while a query is active
  # `results` (a DB search) replaces the browse window.
  defp image_picker(assigns) do
    assigns =
      assigns
      |> assign(:visible, assigns.results || assigns.media)
      |> assign(:multi?, match?({:gallery, _id}, assigns.index))

    ~H"""
    <div class="fixed inset-0 z-50" phx-window-keydown="close_picker" phx-key="Escape">
      <%!-- A light scrim dims the editor without hiding it — the drawer is to the
            side, not over everything — and clicking it closes the drawer. --%>
      <div class="absolute inset-0 bg-black/20" phx-click="close_picker" aria-hidden="true"></div>
      <div
        id="image-picker-dialog"
        phx-hook="FocusTrap"
        role="dialog"
        aria-modal="true"
        aria-labelledby="image-picker-title"
        tabindex="-1"
        class="drawer-in absolute inset-y-0 right-0 flex w-full max-w-md flex-col border-l border-base-content/10 bg-base-100 shadow-xl"
      >
        <div class="flex items-center justify-between gap-4 border-b border-base-content/10 p-4">
          <h2 id="image-picker-title" class="text-lg font-medium">{picker_title(@index)}</h2>
          <button
            type="button"
            phx-click="close_picker"
            aria-label={gettext("Close")}
            class="rounded p-1 text-base-content/70 hover:bg-base-200 hover:text-base-content"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <div class="flex-1 overflow-y-auto p-4">
          <form :if={@media != []} id="media-browser-filter" phx-change="search_media" class="mb-3">
            <input
              type="text"
              name="q"
              value={@query}
              placeholder={gettext("Search by filename, alt or caption")}
              aria-label={gettext("Search by filename, alt text or caption")}
              phx-debounce="150"
              autocomplete="off"
              class="w-full rounded border border-base-content/20 bg-transparent px-3 py-1.5 text-sm"
            />
          </form>

          <p :if={@media == []} class="text-sm text-base-content/60">
            {gettext("No media yet — upload some in the")} <.link
              navigate={~p"/media"}
              class="underline"
            >{gettext("media library")}</.link>.
          </p>
          <p :if={@media != [] and @visible == []} class="text-sm text-base-content/60">
            {gettext("No media matches “%{query}”.", query: @query)}
          </p>

          <div :if={@visible != []} class="grid grid-cols-2 gap-3 sm:grid-cols-3">
            <button
              :for={item <- @visible}
              type="button"
              phx-click={if @multi?, do: "toggle_pick", else: "pick_image"}
              phx-value-index={pick_index(@index)}
              phx-value-bid={pick_block_id(@index)}
              phx-value-id={item.id}
              phx-value-url={item.url}
              title={item.filename}
              aria-pressed={@multi? && to_string(picked_position(@picked, item.id) != nil)}
              class={[
                "group relative overflow-hidden rounded border hover:ring-2 hover:ring-primary",
                if(picked_position(@picked, item.id),
                  do: "border-primary ring-2 ring-primary",
                  else: "border-base-content/10"
                )
              ]}
            >
              <img
                src={item.url}
                alt={item.alt || item.filename}
                loading="lazy"
                class="aspect-square w-full object-cover"
              />
              <%!-- The number, not a tick: in a multi-select whose order becomes
                    the gallery order, "which one did I click third" is the thing
                    an editor actually needs to see. --%>
              <span
                :if={position = picked_position(@picked, item.id)}
                class="absolute right-1 top-1 flex size-6 items-center justify-center rounded-full bg-primary text-xs font-semibold text-primary-content"
              >
                {position}
              </span>
            </button>
          </div>
        </div>

        <div
          :if={@multi?}
          class="flex items-center justify-between gap-3 border-t border-base-content/10 p-4"
        >
          <p class="text-sm text-base-content/70">
            {ngettext("%{count} image selected", "%{count} images selected", length(@picked))}
          </p>
          <button
            type="button"
            phx-click="add_picked_images"
            phx-value-bid={pick_block_id(@index)}
            disabled={@picked == []}
            class="rounded bg-primary px-3 py-1.5 text-sm font-medium text-primary-content disabled:opacity-40"
          >
            {gettext("Add to gallery")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  # The document counterpart of `image_picker/1` (#481) — a single-select
  # drawer over the (documents-only) file library, filling the `:file` block
  # identified by `@file_picking`. No multi-select, no "insert new from
  # chrome" shortcut, and no thumbnail grid (a badge per file instead) —
  # deliberately smaller than the image picker, since a document doesn't
  # preview the way an image does and v1 scopes to "pick from the palette,
  # then fill it in", not every entry point images have.
  attr :files, :list, required: true
  attr :results, :any, required: true
  attr :query, :string, required: true

  defp file_picker(assigns) do
    assigns = assign(assigns, :visible, assigns.results || assigns.files)

    ~H"""
    <div class="fixed inset-0 z-50" phx-window-keydown="close_file_picker" phx-key="Escape">
      <div
        class="absolute inset-0 bg-black/20"
        phx-click="close_file_picker"
        aria-hidden="true"
      >
      </div>
      <div
        id="file-picker-dialog"
        phx-hook="FocusTrap"
        role="dialog"
        aria-modal="true"
        aria-labelledby="file-picker-title"
        tabindex="-1"
        class="drawer-in absolute inset-y-0 right-0 flex w-full max-w-md flex-col border-l border-base-content/10 bg-base-100 shadow-xl"
      >
        <div class="flex items-center justify-between gap-4 border-b border-base-content/10 p-4">
          <h2 id="file-picker-title" class="text-lg font-medium">{gettext("Choose a file")}</h2>
          <button
            type="button"
            phx-click="close_file_picker"
            aria-label={gettext("Close")}
            class="rounded p-1 text-base-content/70 hover:bg-base-200 hover:text-base-content"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <div class="flex-1 overflow-y-auto p-4">
          <form
            :if={@files != []}
            id="file-browser-filter"
            phx-change="search_file_media"
            class="mb-3"
          >
            <input
              type="text"
              name="q"
              value={@query}
              placeholder={gettext("Search by filename")}
              aria-label={gettext("Search by filename")}
              phx-debounce="150"
              autocomplete="off"
              class="w-full rounded border border-base-content/20 bg-transparent px-3 py-1.5 text-sm"
            />
          </form>

          <p :if={@files == []} class="text-sm text-base-content/60">
            {gettext("No documents yet — upload a PDF in the")} <.link
              navigate={~p"/media"}
              class="underline"
            >{gettext("media library")}</.link>.
          </p>
          <p :if={@files != [] and @visible == []} class="text-sm text-base-content/60">
            {gettext("No documents match “%{query}”.", query: @query)}
          </p>

          <ul :if={@visible != []} class="space-y-1">
            <li :for={item <- @visible}>
              <button
                type="button"
                phx-click="pick_file"
                phx-value-id={item.id}
                title={item.filename}
                class="flex w-full items-center gap-2 rounded border border-base-content/10 px-3 py-2 text-left text-sm hover:border-primary hover:bg-base-200"
              >
                <.icon name="hero-document" class="size-5 shrink-0 text-base-content/60" />
                <span class="min-w-0 flex-1 truncate">{item.filename}</span>
                <span
                  :if={item.audience != :public}
                  class="shrink-0 rounded bg-warning/15 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-warning-ink"
                >
                  {gettext("Gated")}
                </span>
              </button>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  # The A/V counterpart of `file_picker/1` (#494), and deliberately the same
  # shape — single-select, no multi-pick, no "insert new" shortcut.
  #
  # One component covers three targets, because a video block picks from
  # three different libraries: the video/audio itself (`@av_media`), a poster
  # image (`@images`) and a WebVTT caption track (searched, since a `.vtt` is
  # rare enough not to warrant its own mounted list). `@target` is the
  # `{block_id, field}` from `@av_picking`, and it decides both the list shown
  # and the copy — a drawer titled "Choose a video" that is actually offering
  # poster images is worse than no drawer.
  attr :target, :any, required: true
  attr :items, :list, required: true
  attr :images, :list, required: true
  attr :results, :any, required: true
  attr :query, :string, required: true

  defp av_picker(assigns) do
    {_bid, field} = assigns.target

    mounted =
      case field do
        "poster" -> assigns.images
        # No mounted list for caption tracks: `@results` (the search) is the
        # only way to reach one, and an empty state below says so.
        "captions" -> []
        _media -> assigns.items
      end

    assigns =
      assigns
      |> assign(:field, field)
      |> assign(:mounted, mounted)
      |> assign(:visible, assigns.results || mounted)

    ~H"""
    <div class="fixed inset-0 z-50" phx-window-keydown="close_av_picker" phx-key="Escape">
      <div class="absolute inset-0 bg-black/20" phx-click="close_av_picker" aria-hidden="true"></div>
      <div
        id="av-picker-dialog"
        phx-hook="FocusTrap"
        role="dialog"
        aria-modal="true"
        aria-labelledby="av-picker-title"
        tabindex="-1"
        class="drawer-in absolute inset-y-0 right-0 flex w-full max-w-md flex-col border-l border-base-content/10 bg-base-100 shadow-xl"
      >
        <div class="flex items-center justify-between gap-4 border-b border-base-content/10 p-4">
          <h2 id="av-picker-title" class="text-lg font-medium">{av_picker_title(@field)}</h2>
          <button
            type="button"
            phx-click="close_av_picker"
            aria-label={gettext("Close")}
            class="rounded p-1 text-base-content/70 hover:bg-base-200 hover:text-base-content"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <div class="flex-1 overflow-y-auto p-4">
          <form id="av-browser-filter" phx-change="search_av_media" class="mb-3">
            <input
              type="text"
              name="q"
              value={@query}
              placeholder={gettext("Search by filename")}
              aria-label={gettext("Search by filename")}
              phx-debounce="150"
              autocomplete="off"
              class="w-full rounded border border-base-content/20 bg-transparent px-3 py-1.5 text-sm"
            />
          </form>

          <p :if={@visible == [] and @query != ""} class="text-sm text-base-content/60">
            {gettext("Nothing matches “%{query}”.", query: @query)}
          </p>
          <p :if={@visible == [] and @query == ""} class="text-sm text-base-content/60">
            {av_picker_empty(@field)} <.link navigate={~p"/media"} class="underline">{gettext(
                "media library"
              )}</.link>.
          </p>

          <ul :if={@visible != []} class="space-y-1">
            <li :for={item <- @visible}>
              <button
                type="button"
                phx-click="pick_av"
                phx-value-id={item.id}
                title={item.filename}
                class="flex w-full items-center gap-2 rounded border border-base-content/10 px-3 py-2 text-left text-sm hover:border-primary hover:bg-base-200"
              >
                <.icon
                  name={av_item_icon(item)}
                  class="size-5 shrink-0 text-base-content/60"
                />
                <span class="min-w-0 flex-1 truncate">{item.filename}</span>
                <span :if={av_item_duration(item)} class="shrink-0 text-xs text-base-content/60">
                  {av_item_duration(item)}
                </span>
                <span
                  :if={Map.get(item, :audience, :public) != :public}
                  class="shrink-0 rounded bg-warning/15 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-warning-ink"
                >
                  {gettext("Gated")}
                </span>
              </button>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  defp av_picker_title("poster"), do: gettext("Choose a poster image")
  defp av_picker_title("captions"), do: gettext("Choose a caption track")
  defp av_picker_title(_field), do: gettext("Choose a video or audio file")

  defp av_picker_empty("poster"), do: gettext("No images yet — upload one in the")

  defp av_picker_empty("captions"),
    do: gettext("Search for a WebVTT (.vtt) track you've uploaded to the")

  defp av_picker_empty(_field),
    do: gettext("No video or audio yet — upload an MP4, WebM, MP3 or M4A in the")

  # The picker lists items from three different `select:`s, so nothing here may
  # assume a field is loaded — `Map.get/3` throughout.
  defp av_item_icon(item) do
    case KilnCMS.MediaKind.of(Map.get(item, :content_type)) do
      :video -> "hero-film"
      :audio -> "hero-musical-note"
      :captions -> "hero-language"
      _kind -> "hero-photo"
    end
  end

  defp av_item_duration(item),
    do: KilnCMS.MediaKind.humanize_duration(Map.get(item, :duration_seconds))

  # 1-based position of a media id in the current selection, or nil.
  defp picked_position(picked, id) do
    case Enum.find_index(picked, &(&1.id == id)) do
      nil -> nil
      index -> index + 1
    end
  end

  # Drawer heading, per open mode.
  defp picker_title(:new), do: gettext("Insert an image")
  defp picker_title({:gallery, _id}), do: gettext("Add images to the gallery")
  defp picker_title(:featured), do: gettext("Featured image")
  defp picker_title(:seo_image), do: gettext("Choose a social image")
  defp picker_title(_), do: gettext("Choose an image")

  defp color_for(id),
    do: Enum.at(@cursor_colors, rem(:erlang.phash2(id), length(@cursor_colors)))

  # Hex twins of @cursor_colors (same order), for the CRDT caret labels —
  # TipTap's CollaborationCursor needs CSS color values, not Tailwind classes.
  @cursor_colors_hex ~w(#f43f5e #f59e0b #10b981 #0ea5e9 #8b5cf6 #ec4899)

  defp color_hex_for(id),
    do: Enum.at(@cursor_colors_hex, rem(:erlang.phash2(id), length(@cursor_colors_hex)))

  # Up-to-two-letter initials from a display name ("Jane Doe" → "JD",
  # "editor" → "E"), for the roster chips and remote caret labels.
  defp initials(nil), do: "?"

  defp initials(name) do
    case name |> String.split(~r/\s+/, trim: true) |> Enum.take(2) do
      [] -> "?"
      words -> Enum.map_join(words, &(&1 |> String.first() |> String.upcase()))
    end
  end

  # Focus-tracking attributes for an input; `field` keys the cursor badge.
  # `phx-debounce` coalesces the per-keystroke `validate` events (and the
  # `broadcast_preview/1` they trigger) so fast typing with a pop-out preview
  # open doesn't flood PubSub / LiveView diffing.
  defp field_attrs(field) do
    %{
      "phx-focus" => "field_focus",
      "phx-blur" => "field_blur",
      "phx-value-field" => field,
      "phx-debounce" => "300"
    }
  end

  # The set of fields soft-locked *for us* right now. A field is contended when
  # one or more editors are focused on it; the editor with the lowest id owns it
  # (a deterministic tie-break, so two simultaneous focusers never lock each
  # other out). We hold the lock only on fields we don't own. The lock is
  # advisory — the input goes readonly but still submits — and releases the
  # moment the owner blurs or leaves.
  defp locked_fields(cursors, self_field, self_id) do
    cursors
    |> Enum.group_by(fn {_id, c} -> c.field end, fn {id, _c} -> id end)
    |> Enum.flat_map(fn {field, other_ids} ->
      # We own `field` only if we're focused there and outrank everyone else.
      owned? = field == self_field and Enum.all?(other_ids, &(self_id < &1))
      if owned?, do: [], else: [field]
    end)
    |> MapSet.new()
  end

  # Same set, computed straight from the socket — for `handle_event` clauses
  # that write a field on the author's behalf and must re-check the lock
  # server-side (the rendered `readonly` attribute is not a boundary).
  defp locked_fields(socket),
    do:
      locked_fields(
        socket.assigns.cursors,
        socket.assigns.self_field,
        socket.assigns.actor.id
      )

  defp field_locked?(locked, field), do: MapSet.member?(locked, field)

  defp lock_ring(locked, field) do
    if field_locked?(locked, field), do: "rounded-md ring-2 ring-warning/50", else: ""
  end

  # Effective blocks (data + unsaved edits) from the form, for the live preview.
  # Thin `%{type, content}` maps — used by the decoupled (pop-out) preview window.
  # Thin `%{type, content}` block maps for the decoupled (pop-out) preview, which
  # renders them through the shared `BlockComponents`. Routed through the SAME
  # sanitized typed→legacy pipeline as the inline preview (`preview_block_maps`)
  # and `PreviewLive.content_blocks/1`, so rich-text edits surface as rendered
  # `legacy_html` rather than the empty Portable Text `body` field that a
  # primary-field lookup would pick (#134).
  defp preview_blocks(form) do
    form
    |> preview_block_maps()
    |> KilnCMS.CMS.TypedBlocks.to_typed()
    |> KilnCMS.CMS.TypedBlocks.to_legacy()
    |> KilnCMSWeb.BlockComponents.thin_blocks()
  end

  # Inline preview rendered through the **same typed serializers that firing
  # uses** (Kiln v2) — what you preview is exactly what publishes/delivers. Full
  # block maps (incl. `data`/`children`) go through the legacy→typed bridge and
  # the per-block `render(:web)`. Rich-text HTML is sanitized first (mirroring the
  # save-time `SanitizeBlocks` change), so the rendered output is safe.
  # sobelow_skip ["XSS.Raw"]
  # A `{block_id, safe_html}` per block, so the Preview tab can wrap each block
  # individually and offer a per-block "edit on the page" jump (Theme C). The id is
  # the block's stable uuid (B1) — the same one the in-context editor focuses via
  # `?focus=`.
  #
  # Takes the already-typed block list: `refresh_preview/1` derives it once and
  # shares it with the SEO body walk rather than each re-running `to_typed/1`.
  defp preview_html(typed) do
    Enum.map(typed, fn block ->
      {Map.get(block, :id), Phoenix.HTML.raw(KilnCMS.Blocks.render(block, :web))}
    end)
  end

  defp preview_block_maps(form) do
    case AshPhoenix.Form.value(form, :blocks) do
      forms when is_list(forms) -> Enum.map(forms, &block_full_map/1)
      _ -> []
    end
  end

  # A typed block map (string keys, `_type`) read from a union member sub-form,
  # for the inline typed preview. Rich-text HTML is sanitized (unsaved edits
  # aren't sanitized until save).
  # Carries the stable id through (via block_field_map) so the preview can offer a
  # per-block "edit on the page" jump (Theme C), then sanitizes unsaved rich text.
  defp block_full_map(%AshPhoenix.Form{} = subform) do
    subform
    |> block_field_map("_type")
    |> sanitize_preview_block()
  end

  defp sanitize_preview_block(%{"_type" => "rich_text"} = map),
    do: Map.update(map, "legacy_html", nil, &KilnCMS.HTMLSanitizer.sanitize_rich_text/1)

  defp sanitize_preview_block(map), do: map

  # ── Registry-driven palette + DSL-metadata-driven block fields (Kiln v2) ──

  # The block palette: registered block types in a friendly order, with any new
  # ones appended — so adding a `Kiln.Block` module surfaces here automatically.
  # Each entry carries display metadata for the slash-command inserter menu.
  defp block_types do
    available = KilnCMS.Blocks.registry() |> Map.keys() |> Enum.map(&to_string/1)
    ordered = Enum.filter(@type_order, &(&1 in available))

    (ordered ++ Enum.sort(available -- ordered))
    |> Enum.map(fn type ->
      %{
        type: type,
        label: dsl_label(type),
        icon: block_icon(type),
        description: block_description(type)
      }
    end)
  end

  # Heroicon for a block type in the inserter menu (generic fallback for any
  # registry-discovered type without a bespoke icon).
  defp block_icon("rich_text"), do: "hero-document-text"
  defp block_icon("heading"), do: "hero-hashtag"
  defp block_icon("quote"), do: "hero-chat-bubble-bottom-center-text"
  defp block_icon("image"), do: "hero-photo"
  defp block_icon("file"), do: "hero-document-arrow-down"
  defp block_icon("video"), do: "hero-film"
  defp block_icon("audio"), do: "hero-musical-note"
  defp block_icon("embed"), do: "hero-code-bracket"
  defp block_icon("divider"), do: "hero-minus"
  defp block_icon("columns"), do: "hero-view-columns"
  defp block_icon("portable_text"), do: "hero-bars-3"
  defp block_icon("gallery"), do: "hero-photo"
  defp block_icon("accordion"), do: "hero-bars-3-bottom-left"
  defp block_icon("faq"), do: "hero-question-mark-circle"
  defp block_icon("how_to"), do: "hero-list-bullet"
  defp block_icon("claim"), do: "hero-check-badge"
  defp block_icon("custom"), do: "hero-puzzle-piece"
  defp block_icon(_), do: "hero-squares-2x2"

  # One-line description shown under the label in the inserter menu.
  defp block_description("rich_text"), do: gettext("Formatted text with bold, italic, and lists")
  defp block_description("heading"), do: gettext("Section title")
  defp block_description("quote"), do: gettext("Highlighted quotation")
  defp block_description("image"), do: gettext("Picture with alt text and caption")
  defp block_description("file"), do: gettext("Downloadable document, e.g. a PDF")

  # Says what it is NOT, for the same reason `accordion` does: `embed` also
  # produces a video player, and the difference an editor cares about is where
  # the file lives, not what the block looks like.
  defp block_description("video"),
    do: gettext("Video from your media library — use Embed for YouTube or Vimeo")

  defp block_description("audio"), do: gettext("Audio from your media library, e.g. a podcast")
  defp block_description("embed"), do: gettext("Embedded HTML or external content")
  defp block_description("divider"), do: gettext("Visual separator between sections")
  defp block_description("columns"), do: gettext("Side-by-side columns holding nested blocks")
  defp block_description("portable_text"), do: gettext("Portable Text rich content")

  defp block_description("gallery"),
    do: gettext("Several images with captions, fired as ImageGallery structured data")

  # Says what it is NOT, because that is the only difference an editor can see:
  # this and the FAQ block draw the same collapsing panels, and picking the wrong
  # one publishes a claim that the page is a list of questions and answers.
  defp block_description("accordion"),
    do: gettext("Collapsible panels with no structured data — use FAQ for questions and answers")

  defp block_description("faq"), do: gettext("Q&A list, fired as FAQPage structured data")

  defp block_description("how_to"),
    do: gettext("Step-by-step guide, fired as HowTo structured data")

  defp block_description("claim"), do: gettext("Sourced claim with citation metadata")
  defp block_description("custom"), do: gettext("Custom block payload")
  defp block_description(_), do: gettext("Insert a block")

  # The typed block name (string) for a sub-form's union member.
  defp block_type_string(bf), do: bf |> block_member() |> Kiln.Block.Info.name() |> to_string()

  # HTML the TipTap editor hydrates from. Canonical Portable Text (`body` —
  # what imports, visual editing, and the MCP tools write) takes precedence,
  # rendered to HTML; `legacy_html` is the fallback for un-migrated content.
  # Without the body branch, PT-backed blocks opened as an EMPTY editor and a
  # save then wiped the content: the form only round-trips `legacy_html`, so
  # `body` was silently replaced by an empty string. Edited blocks save back
  # through `legacy_html` (body cleared by the same form round-trip), which
  # every render path already prefers second — no data is lost, the storage
  # just downgrades from PT to sanitized HTML until a full TipTap<->PT
  # round-trip ships.
  # Initial value for the editor's hidden input: the stored Portable Text as
  # JSON (the RichText hook overwrites it with live TipTap JSON on mount). A
  # legacy_html-only block posts [] until the hook mounts — and the hook always
  # mounts before any save can happen, seeding TipTap from the rendered HTML.
  defp rich_text_editor_html(bf) do
    case bf[:body].value do
      [_ | _] = body -> KilnCMS.Blocks.PortableText.to_html(body)
      _ -> bf[:legacy_html].value || ""
    end
  end

  # Stable DOM key for a rich-text editor host: the block's id, so a reorder
  # relocates (rather than remounts) the mounted TipTap editor. A brand-new block
  # has no id until it is saved, so fall back to its index — those still remount
  # on reorder, which is harmless (a just-added editor has no cursor/undo state
  # worth preserving) and can't collide with a real id.
  defp rich_host_key(bf), do: bf[:id].value || "idx-#{bf.index}"

  # The first string/rich_text field — the block's primary text field.
  defp primary_field_name(nil), do: nil

  defp primary_field_name(module) do
    module
    |> Kiln.Block.Info.fields()
    |> Enum.find_value(fn f -> f.type in [:string, :rich_text] && f.name end)
  end

  # The scalar DSL fields a role may edit (field-level policy, Phase J), excluding
  # types with bespoke UIs (rich_text/map/reference/array).
  # Fields resolved by the server, not typed by a person. They are ordinary
  # block scalars — so without this the generic editor offers each of them as a
  # free-text box, which is how `thumbnail_url` (an `<img src>` on the public
  # page) and `resolved_at` (a machine timestamp) became editable in the first
  # draft of #489. The write path filters them anyway; this stops the editor
  # inviting the attempt.
  @server_resolved_fields [
    :title,
    :author_name,
    :provider_name,
    :thumbnail_url,
    :resolved_url,
    :resolved_at
  ]

  defp editable_scalar_fields(module, role) do
    server_resolved = if module == KilnCMS.Blocks.Embed, do: @server_resolved_fields, else: []

    module
    |> Kiln.Block.Info.fields()
    |> Enum.reject(fn field ->
      field.type in [:rich_text, :map, :reference] or match?({:array, _}, field.type) or
        field.name in server_resolved
    end)
    |> Enum.filter(&Kiln.Block.Policy.can_edit_field?(module, &1.name, role))
  end

  defp dsl_input_type(:integer), do: "number"
  defp dsl_input_type(:boolean), do: "checkbox"
  defp dsl_input_type(_type), do: "text"

  defp dsl_label(name), do: name |> to_string() |> Phoenix.Naming.humanize()

  # Per-block editor body for non-rich-text/non-image blocks: labeled inputs bound
  # directly to the union member's typed attributes (Kiln v2 native-union editor).
  # The primary text field is a textarea carrying the collab field-lock; the rest
  # render by their declared type. Role-filtered by field-level policy.
  attr :bf, :any, required: true
  attr :role, :atom, required: true
  attr :locked_fields, :any, required: true
  attr :cursors, :any, required: true

  defp dsl_block_fields(assigns) do
    module = block_member(assigns.bf)

    assigns =
      assigns
      |> assign(:primary, primary_field_name(module))
      |> assign(:fields, editable_scalar_fields(module, assigns.role))

    ~H"""
    <div class="space-y-2">
      <p :if={@fields == []} class="text-sm text-base-content/70">
        {gettext("Section break — no editable fields.")}
      </p>

      <div :for={field <- @fields}>
        <div
          :if={field.name == @primary}
          class={["relative", lock_ring(@locked_fields, @bf[field.name].name)]}
        >
          <.input
            field={@bf[field.name]}
            type="textarea"
            label={dsl_label(field.name)}
            readonly={field_locked?(@locked_fields, @bf[field.name].name)}
            {field_attrs(@bf[field.name].name)}
          />
          <.field_cursors field={@bf[field.name].name} cursors={@cursors} />
        </div>

        <.input
          :if={field.name != @primary}
          field={@bf[field.name]}
          type={dsl_input_type(field.type)}
          label={dsl_label(field.name)}
        />
      </div>
    </div>
    """
  end

  # ── Repeating two-field row editor (faq / how_to / accordion) ───────────────

  # Repeatable two-field rows bound straight into the union member's
  # `{:array, :map}` param (`…[items][0][question]`); `normalize_block_items`
  # turns the indexed maps back into lists on validate/save. The hidden
  # sentinel keeps the param present when every row is removed, so deleting
  # the last row actually clears the stored list.
  #
  # Written for the GEO blocks (#357) and generalized when the accordion arrived
  # (#482) — three blocks, one shape: a label and a body per row. The `case`
  # below has no fallback on purpose: a block wired into `@row_editor_types`
  # without a spec here should fail loudly at render rather than draw an empty
  # box the editor cannot use.
  attr :bf, :any, required: true

  defp item_rows_editor(assigns) do
    {field, key_a, key_b, label_a, label_b, add_label} =
      case block_type_string(assigns.bf) do
        "faq" ->
          {:items, "question", "answer", gettext("Question"), gettext("Answer"),
           gettext("Add question")}

        "how_to" ->
          {:steps, "name", "text", gettext("Step label (optional)"), gettext("Instruction"),
           gettext("Add step")}

        "accordion" ->
          {:panels, "title", "content", gettext("Panel title"), gettext("Panel content"),
           gettext("Add panel")}
      end

    assigns =
      assigns
      |> assign(:field, field)
      |> assign(:name, assigns.bf[field].name)
      |> assign(:items, item_row_maps(assigns.bf[field].value))
      |> assign(:key_a, key_a)
      |> assign(:key_b, key_b)
      |> assign(:label_a, label_a)
      |> assign(:label_b, label_b)
      |> assign(:add_label, add_label)

    ~H"""
    <div class="mt-2 space-y-2">
      <input type="hidden" name={"#{@name}[_sentinel]"} value="" />

      <div
        :for={{item, i} <- Enum.with_index(@items)}
        class="flex items-start gap-2 rounded border border-base-content/10 p-2"
      >
        <div class="grow space-y-1">
          <input
            type="text"
            name={"#{@name}[#{i}][#{@key_a}]"}
            value={item[@key_a]}
            placeholder={@label_a}
            aria-label={@label_a}
            phx-debounce="300"
            class="w-full rounded border border-base-content/20 bg-transparent px-2 py-1 text-sm"
          />
          <textarea
            name={"#{@name}[#{i}][#{@key_b}]"}
            placeholder={@label_b}
            aria-label={@label_b}
            rows="2"
            phx-debounce="300"
            class="w-full rounded border border-base-content/20 bg-transparent px-2 py-1 text-sm"
          >{item[@key_b]}</textarea>
        </div>
        <button
          type="button"
          phx-click="item_row_remove"
          phx-value-index={@bf.index}
          phx-value-field={@field}
          phx-value-item={i}
          aria-label={gettext("Remove row")}
          class="mt-1 text-base-content/60 hover:text-error"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>

      <button
        type="button"
        phx-click="item_row_add"
        phx-value-index={@bf.index}
        phx-value-field={@field}
        class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
      >
        <.icon name="hero-plus" class="mr-1 size-4" />{@add_label}
      </button>
    </div>
    """
  end

  # The current item rows of an `{:array, :map}` field value, tolerating nil
  # (fresh block) and non-map junk.
  defp item_row_maps(value), do: value |> List.wrap() |> Enum.filter(&is_map/1)

  # A function rather than `@row_editor_types` inline in the template: inside a
  # `~H` sigil `@name` means `assigns.name`, so referencing the module attribute
  # there reads a socket assign that does not exist and raises at render.
  defp row_editor_type?(type), do: type in @row_editor_types

  # ── gallery editor (#482) ───────────────────────────────────────────────────

  # One row per image: thumbnail, alt, caption, reorder, remove. Rows bind into
  # the `images` `{:array, :map}` param exactly as the row editor above binds
  # `items`/`steps`/`panels`, so `normalize_item_rows/1` flattens them the same
  # way and there is no parallel socket state to keep in sync.
  #
  # Reordering is offered twice on purpose. Dragging is the fast path; the
  # up/down buttons are the one that works from a keyboard, on a touch screen,
  # and with a screen reader — the same pairing `move_block/2` gives the
  # top-level list, and the reason it is not a "nice to have" is that a gallery
  # is *only* an ordering: an editor who cannot reorder it cannot use it.
  # The video block's editor (#494). Three library picks (the media, a poster,
  # a caption track), each writing a hidden `media_id`-shaped field, plus the
  # display metadata and the two playback flags.
  #
  # Every picked id is carried in a hidden input rather than re-derived on
  # save: the block's params round-trip through `AshPhoenix.Form`, and a field
  # with no input in the DOM is a field the next `validate` drops.
  attr :bf, :any, required: true

  defp video_editor(assigns) do
    ~H"""
    <div class="space-y-2">
      <input type="hidden" name={@bf[:media_id].name} value={@bf[:media_id].value} />
      <input type="hidden" name={@bf[:poster_media_id].name} value={@bf[:poster_media_id].value} />
      <input
        type="hidden"
        name={@bf[:captions_media_id].name}
        value={@bf[:captions_media_id].value}
      />
      <input
        type="hidden"
        name={@bf[:duration_seconds].name}
        value={@bf[:duration_seconds].value}
      />
      <%!-- `poster_url` (an externally-hosted poster, the counterpart of the
            `url` field below) has no visible input: the picker is the only way
            to set a poster from this screen, and a second URL box next to it
            would be one more thing to explain than it is worth. It still needs
            a hidden input, because a field with no input in the DOM is a field
            the next `validate` DROPS — without this, opening any page whose
            video block was written through the headless API would silently
            erase its poster. The two captions text fields below are visible
            only when a track is picked, and carry hidden twins for exactly the
            same reason when they aren't. --%>
      <input type="hidden" name={@bf[:poster_url].name} value={@bf[:poster_url].value} />
      <input
        :if={@bf[:captions_media_id].value in [nil, ""]}
        type="hidden"
        name={@bf[:captions_label].name}
        value={@bf[:captions_label].value}
      />
      <input
        :if={@bf[:captions_media_id].value in [nil, ""]}
        type="hidden"
        name={@bf[:captions_lang].name}
        value={@bf[:captions_lang].value}
      />

      <%!-- The real player, not a still: the point of picking a video in the
            editor is confirming you picked the right one, and a filename does
            not tell you that. Streams through the authorized route, so a gated
            item previews here exactly as it will on the page. --%>
      <video
        :if={@bf[:media_id].value not in [nil, ""]}
        id={"video-preview-#{@bf[:id].value}"}
        src={~p"/media/#{@bf[:media_id].value}/stream"}
        controls
        playsinline
        preload="metadata"
        class="max-h-48 w-full rounded bg-black"
      />

      <div class="flex flex-wrap items-center gap-2">
        <button
          type="button"
          phx-click="open_av_picker"
          phx-value-bid={@bf[:id].value}
          phx-value-field="media"
          class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
        >
          <.icon name="hero-film" class="mr-1 size-4" />{gettext("Choose video")}
        </button>
        <button
          type="button"
          phx-click="open_av_picker"
          phx-value-bid={@bf[:id].value}
          phx-value-field="poster"
          class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
        >
          <.icon name="hero-photo" class="mr-1 size-4" />{if @bf[:poster_media_id].value in [
                                                               nil,
                                                               ""
                                                             ],
                                                             do: gettext("Add poster"),
                                                             else: gettext("Change poster")}
        </button>
        <button
          type="button"
          phx-click="open_av_picker"
          phx-value-bid={@bf[:id].value}
          phx-value-field="captions"
          class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
        >
          <.icon name="hero-language" class="mr-1 size-4" />{if @bf[:captions_media_id].value in [
                                                                  nil,
                                                                  ""
                                                                ],
                                                                do: gettext("Add captions"),
                                                                else: gettext("Change captions")}
        </button>
      </div>

      <%!-- Not a validation error — a video with no captions still publishes.
            It is the one accessibility fact about this block an editor cannot
            see by looking at it, so it is stated where the decision is made
            rather than in a report nobody opens. --%>
      <p
        :if={@bf[:media_id].value not in [nil, ""] and @bf[:captions_media_id].value in [nil, ""]}
        class="flex items-start gap-1 text-xs text-warning"
      >
        <.icon name="hero-exclamation-triangle" class="mt-px size-3.5 shrink-0" />
        <span>
          {gettext("No captions — this video isn't available to deaf and hard-of-hearing readers.")}
        </span>
      </p>

      <.input
        field={@bf[:url]}
        label={gettext("Video URL")}
        placeholder={gettext("…or paste a URL to a video hosted elsewhere")}
      />
      <.input field={@bf[:title]} label={gettext("Title")} />
      <.input field={@bf[:caption]} label={gettext("Caption")} />
      <div :if={@bf[:captions_media_id].value not in [nil, ""]} class="grid grid-cols-2 gap-2">
        <.input field={@bf[:captions_label]} label={gettext("Captions label")} />
        <.input
          field={@bf[:captions_lang]}
          label={gettext("Captions language")}
          placeholder="en"
        />
      </div>
      <div class="flex flex-wrap gap-4">
        <%!-- The label says "muted" because the rendered element always is:
              browsers refuse to autoplay a video with sound, so offering the
              two as separate choices would offer one that does nothing. --%>
        <.input
          field={@bf[:autoplay]}
          type="checkbox"
          label={gettext("Autoplay (muted)")}
        />
        <.input field={@bf[:loop]} type="checkbox" label={gettext("Loop")} />
      </div>
    </div>
    """
  end

  attr :bf, :any, required: true

  defp audio_editor(assigns) do
    ~H"""
    <div class="space-y-2">
      <input type="hidden" name={@bf[:media_id].name} value={@bf[:media_id].value} />
      <input
        type="hidden"
        name={@bf[:duration_seconds].name}
        value={@bf[:duration_seconds].value}
      />

      <audio
        :if={@bf[:media_id].value not in [nil, ""]}
        id={"audio-preview-#{@bf[:id].value}"}
        src={~p"/media/#{@bf[:media_id].value}/stream"}
        controls
        preload="metadata"
        class="w-full"
      />

      <div class="flex items-center gap-2">
        <button
          type="button"
          phx-click="open_av_picker"
          phx-value-bid={@bf[:id].value}
          phx-value-field="media"
          class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
        >
          <.icon name="hero-musical-note" class="mr-1 size-4" />{gettext("Choose audio")}
        </button>
      </div>

      <.input
        field={@bf[:url]}
        label={gettext("Audio URL")}
        placeholder={gettext("…or paste a URL to audio hosted elsewhere")}
      />
      <.input field={@bf[:title]} label={gettext("Title")} />
      <.input field={@bf[:caption]} label={gettext("Caption")} />
      <.input field={@bf[:loop]} type="checkbox" label={gettext("Loop")} />
    </div>
    """
  end

  attr :bf, :any, required: true

  defp gallery_editor(assigns) do
    assigns =
      assigns
      |> assign(:name, assigns.bf[:images].name)
      |> assign(:images, item_row_maps(assigns.bf[:images].value))
      |> assign(:bid, assigns.bf[:id].value)

    ~H"""
    <div class="mt-2 space-y-2">
      <%!-- Keeps the param present when the last image is removed, so clearing a
            gallery actually clears the stored list rather than leaving the old
            one untouched. Same trick as the row editor. --%>
      <input type="hidden" name={"#{@name}[_sentinel]"} value="" />

      <%!-- The gallery draws its own fields, so it is excluded from
            `dsl_block_fields/1` — which means anything not rendered here is
            unreachable from the editor entirely. `title` is one of them. --%>
      <.input field={@bf[:title]} label={gettext("Heading (optional)")} />

      <.input
        field={@bf[:layout]}
        type="select"
        label={gettext("Layout")}
        options={gallery_layout_options()}
      />

      <div
        :if={@images != []}
        id={"gallery-#{@bid}"}
        phx-hook="GallerySortable"
        data-block-id={@bid}
        class="space-y-2"
      >
        <div
          :for={{image, i} <- Enum.with_index(@images)}
          data-image-row={i}
          class="flex items-start gap-2 rounded border border-base-content/10 p-2"
        >
          <button
            type="button"
            data-image-handle
            aria-hidden="true"
            tabindex="-1"
            class="mt-1 cursor-grab text-base-content/40"
          >
            <.icon name="hero-bars-2" class="size-4" />
          </button>

          <img
            :if={safe_preview_src(image["url"])}
            src={safe_preview_src(image["url"])}
            alt=""
            class="size-16 shrink-0 rounded border border-base-content/10 object-cover"
          />

          <div class="grow space-y-1">
            <input type="hidden" name={"#{@name}[#{i}][url]"} value={image["url"]} />
            <input type="hidden" name={"#{@name}[#{i}][media_id]"} value={image["media_id"]} />
            <input
              type="text"
              name={"#{@name}[#{i}][alt]"}
              value={image["alt"]}
              placeholder={gettext("Alt text — leave blank only if decorative")}
              aria-label={gettext("Alt text")}
              phx-debounce="300"
              class="w-full rounded border border-base-content/20 bg-transparent px-2 py-1 text-sm"
            />
            <input
              type="text"
              name={"#{@name}[#{i}][caption]"}
              value={image["caption"]}
              placeholder={gettext("Caption (optional)")}
              aria-label={gettext("Caption")}
              phx-debounce="300"
              class="w-full rounded border border-base-content/20 bg-transparent px-2 py-1 text-sm"
            />
          </div>

          <div class="flex flex-col">
            <button
              type="button"
              phx-click="gallery_move"
              phx-value-bid={@bid}
              phx-value-item={i}
              phx-value-dir="up"
              disabled={i == 0}
              aria-label={gettext("Move image up")}
              class="text-base-content/60 hover:text-base-content disabled:opacity-30"
            >
              <.icon name="hero-chevron-up" class="size-4" />
            </button>
            <button
              type="button"
              phx-click="gallery_move"
              phx-value-bid={@bid}
              phx-value-item={i}
              phx-value-dir="down"
              disabled={i == length(@images) - 1}
              aria-label={gettext("Move image down")}
              class="text-base-content/60 hover:text-base-content disabled:opacity-30"
            >
              <.icon name="hero-chevron-down" class="size-4" />
            </button>
            <button
              type="button"
              phx-click="gallery_remove"
              phx-value-bid={@bid}
              phx-value-item={i}
              aria-label={gettext("Remove image")}
              class="mt-1 text-base-content/60 hover:text-error"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
        </div>
      </div>

      <p :if={@images == []} class="text-sm text-base-content/60">
        {gettext("No images yet.")}
      </p>

      <button
        type="button"
        phx-click="open_gallery_picker"
        phx-value-bid={@bid}
        class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
      >
        <.icon name="hero-photo" class="mr-1 size-4" />{gettext("Add images")}
      </button>
    </div>
    """
  end

  # A blank first option, because a fresh gallery has `layout: nil` and a select
  # with no empty entry silently selects whichever option sorts first — the
  # editor would read "Carousel" while the preview rendered the default grid,
  # and the first save would post a layout nobody chose. (The columns editor
  # below prepends "Equal width" for the same reason.) It is also the only way
  # back to the default once a layout has been picked.
  defp gallery_layout_options do
    [{gettext("Grid (default)"), ""}] ++
      for layout <- KilnCMS.Blocks.Gallery.layouts(),
          layout != "grid",
          do: {gallery_layout_label(layout), layout}
  end

  defp gallery_layout_label("grid"), do: gettext("Grid")
  defp gallery_layout_label("masonry"), do: gettext("Masonry")
  defp gallery_layout_label("carousel"), do: gettext("Carousel")
  defp gallery_layout_label(other), do: other

  # ── columns (nested-layout) editor (#335) ───────────────────────────────────

  # The socket-managed children of the columns block behind sub-form `bf`, keyed
  # by the block's stable id. Falls back to the default two empty columns for a
  # block whose id isn't seeded yet (a just-inserted one before its first sync).
  defp col_state(block_children, bf) do
    Map.get(block_children, col_block_id(bf)) || [%{"blocks" => []}, %{"blocks" => []}]
  end

  defp col_block_id(bf), do: bf[:id].value || AshPhoenix.Form.value(bf, :id)

  # Layout <select> options: "Equal" plus each width-ratio preset (labelled "1 : 2").
  defp layout_options do
    presets =
      KilnCMS.Blocks.Columns.presets()
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(&{String.replace(&1, "-", " : "), &1})

    [{gettext("Equal width"), ""} | presets]
  end

  # The full nested editor for one columns block: a layout picker, then a
  # drag-reorderable list per column (nested SortableJS via the `NestedBlockSortable`
  # hook — children move within and across this block's columns), each with an
  # "add block" palette. Children are edited by socket-side events, not bound form
  # inputs; the hidden id input lets the server match this block on save/validate.
  attr :bf, :any, required: true
  attr :columns, :list, required: true
  attr :child_types, :list, required: true

  defp columns_editor(assigns) do
    assigns = assign(assigns, :block_id, col_block_id(assigns.bf))

    ~H"""
    <div class="space-y-3">
      <%!-- Carries the block id into save/validate params so its socket-managed
            children can be matched and re-injected (see inject_children/2). --%>
      <input type="hidden" name={@bf[:id].name} value={@block_id} />

      <div class="flex flex-wrap items-end gap-3">
        <.input
          field={@bf[:layout]}
          type="select"
          label={gettext("Layout")}
          options={layout_options()}
        />
        <button
          type="button"
          phx-click="col_add_column"
          phx-value-id={@block_id}
          class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
        >
          <.icon name="hero-plus" class="mr-1 size-4" />{gettext("Add column")}
        </button>
      </div>

      <div
        id={"cols-#{@block_id}"}
        phx-hook="NestedBlockSortable"
        data-block-id={@block_id}
        class="grid gap-3"
        style={"grid-template-columns:repeat(#{max(length(@columns), 1)}, minmax(0, 1fr))"}
      >
        <div
          :for={{col, ci} <- Enum.with_index(@columns)}
          class="rounded border border-dashed border-base-content/25 p-2"
        >
          <div class="mb-2 flex items-center justify-between">
            <span class="text-xs font-medium text-base-content/60">
              {gettext("Column %{n}", n: ci + 1)}
            </span>
            <button
              :if={length(@columns) > 1}
              type="button"
              phx-click="col_remove_column"
              phx-value-id={@block_id}
              phx-value-col={ci}
              data-confirm={gettext("Remove this column and its blocks?")}
              aria-label={gettext("Remove column")}
              class="text-base-content/50 hover:text-error"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>

          <div data-col-list data-col-index={ci} class="min-h-8 space-y-2">
            <div
              :for={child <- col["blocks"] || []}
              id={"child-#{child["id"]}"}
              data-child-id={child["id"]}
              class="rounded border border-base-content/15 bg-base-100 p-2"
            >
              <div class="mb-1 flex items-center justify-between gap-2">
                <span
                  data-child-handle
                  class="flex cursor-grab items-center gap-1 text-xs text-base-content/60"
                >
                  <.icon name="hero-bars-3" class="size-4" />
                  {dsl_label(child["_type"])}
                </span>
                <button
                  type="button"
                  phx-click="col_remove_child"
                  phx-value-id={@block_id}
                  phx-value-child={child["id"]}
                  aria-label={gettext("Remove block")}
                  class="text-base-content/50 hover:text-error"
                >
                  <.icon name="hero-trash" class="size-4" />
                </button>
              </div>
              <.nested_child_fields block_id={@block_id} child={child} />
            </div>
          </div>

          <div class="mt-2 flex flex-wrap gap-1">
            <button
              :for={type <- @child_types}
              type="button"
              phx-click="col_add_child"
              phx-value-id={@block_id}
              phx-value-col={ci}
              phx-value-type={type}
              class="rounded bg-base-200 px-2 py-1 text-xs hover:bg-base-300"
            >
              + {dsl_label(type)}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Simple per-type field editors for a nested child block. Inputs are nameless
  # (they never enter the form's params) and commit to socket state via
  # `col_update_child` on blur/change — see the columns handlers.
  attr :block_id, :any, required: true
  attr :child, :map, required: true

  defp nested_child_fields(%{child: %{"_type" => "divider"}} = assigns) do
    ~H"""
    <hr class="border-base-300" />
    """
  end

  defp nested_child_fields(assigns) do
    ~H"""
    <div class="space-y-1">
      <input
        :for={{field, ph} <- nested_fields_for(@child["_type"])}
        type="text"
        value={@child[field] || ""}
        placeholder={ph}
        phx-blur="col_update_child"
        phx-value-id={@block_id}
        phx-value-child={@child["id"]}
        phx-value-field={field}
        class="w-full rounded border border-base-content/20 bg-transparent px-2 py-1 text-sm"
      />
      <select
        :if={@child["_type"] == "heading"}
        phx-change="col_update_child"
        phx-value-id={@block_id}
        phx-value-child={@child["id"]}
        phx-value-field="level"
        class="rounded border border-base-content/20 bg-transparent px-2 py-1 text-sm"
      >
        <option :for={n <- 1..6} value={n} selected={to_int(@child["level"]) == n}>H{n}</option>
      </select>
    </div>
    """
  end

  # {field, placeholder} pairs for a nested child type's text inputs.
  defp nested_fields_for("heading"), do: [{"text", gettext("Heading text")}]
  defp nested_fields_for("rich_text"), do: [{"legacy_html", gettext("HTML / text")}]

  defp nested_fields_for("quote"),
    do: [{"text", gettext("Quote")}, {"citation", gettext("Citation")}]

  defp nested_fields_for("image"),
    do: [{"url", gettext("Image URL")}, {"alt", gettext("Alt text")}]

  defp nested_fields_for("embed"), do: [{"url", gettext("Embed URL")}]
  defp nested_fields_for(_), do: []

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(
        :locked_fields,
        locked_fields(assigns.cursors, assigns.self_field, assigns.actor.id)
      )
      |> assign(:related_field, related_field(assigns.kind))
      |> assign(:related_current, related_current(assigns.kind, assigns.record))

    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:content}
    >
      <div
        :if={@conflict}
        id="edit-conflict"
        role="alert"
        aria-live="assertive"
        class="mb-4 flex flex-wrap items-center gap-3 rounded border border-warning/40 bg-warning/10 px-4 py-3 text-sm"
      >
        <.icon name="hero-exclamation-triangle" class="size-5 text-warning" />
        <span class="flex-1">
          {gettext(
            "Someone else saved changes to this content. Saving is paused so you don't overwrite their work."
          )}
        </span>
        <button
          type="button"
          phx-click="reload_conflict"
          data-confirm={gettext("Reload and discard your unsaved changes?")}
          class="btn btn-sm border-transparent bg-warning text-warning-content hover:opacity-90"
        >
          {gettext("Reload latest")}
        </button>
      </div>
      <.form
        for={@form}
        phx-change="validate"
        phx-submit="save"
        id={"#{@kind}-editor"}
        phx-hook="UnsavedGuard"
        data-dirty={to_string(@save_state != :saved)}
        data-unsaved-message={gettext("You have unsaved changes. Leave without saving?")}
        class="space-y-6"
      >
        <span
          :if={@focus_field}
          id="focus-field"
          phx-hook="FocusField"
          data-kiln-focus={@focus_field}
          hidden
        ></span>
        <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between sm:gap-4">
          <div class="min-w-0">
            <.link navigate={~p"/editor"} class="text-sm text-base-content/60 hover:underline">
              &larr; {gettext("All content")}
            </.link>
            <h1 class="mt-1 truncate text-2xl font-semibold">
              {(@form[:title].value not in [nil, ""] && @form[:title].value) ||
                gettext("Edit %{kind}", kind: @kind)}
            </h1>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <button type="button" phx-click="open_media_browser" class="btn btn-sm btn-default">
              <.icon name="hero-photo" class="mr-1 size-4" />{gettext("Media library")}
            </button>
            <.link
              href={~p"/editor/preview/#{@kind}/#{@record.id}"}
              target="_blank"
              rel="noopener noreferrer"
              class="btn btn-sm btn-default"
            >
              {gettext("Preview")} &nearr;
              <span class="sr-only">{gettext("(opens in a new tab)")}</span>
            </.link>
            <%!-- In-context (front-end) editing on Kiln's own rendered page (#354). --%>
            <.link
              navigate={~p"/editor/site/#{@kind}/#{@record.slug}"}
              class="btn btn-sm btn-default"
            >
              <.icon name="hero-pencil-square" class="mr-1 size-4" />{gettext("Edit on page")}
            </.link>
          </div>
        </div>

        <.editor_action_bar
          kind={@kind}
          record={@record}
          save_state={@save_state}
          tier={@tier}
          conflict={@conflict}
          editors={@editors}
          actor={@actor}
          word_count={@seo_body_stats.word_count}
          a11y_report={@a11y_report}
        />

        <div class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_22rem]">
          <div class="min-w-0 space-y-6">
            <div class="grid gap-4 sm:grid-cols-2">
              <div class={["relative", lock_ring(@locked_fields, "title")]}>
                <.input
                  field={@form[:title]}
                  label={gettext("Title")}
                  required
                  readonly={field_locked?(@locked_fields, "title")}
                  {field_attrs("title")}
                />
                <.field_cursors field="title" cursors={@cursors} />
              </div>
              <div class={["relative", lock_ring(@locked_fields, "slug")]}>
                <.input
                  field={@form[:slug]}
                  label={gettext("Slug")}
                  required
                  readonly={field_locked?(@locked_fields, "slug")}
                  {field_attrs("slug")}
                />
                <p class="mt-1 text-xs text-base-content/60">
                  {gettext("URL:")}
                  <a
                    :if={@record.state == :published}
                    href={live_public_path(@form, @content_type)}
                    target="_blank"
                    rel="noopener"
                    class="link font-mono"
                  >
                    {live_public_path(@form, @content_type)}
                  </a>
                  <span :if={@record.state != :published} class="font-mono">
                    {live_public_path(@form, @content_type)}
                  </span>
                </p>
                <%!-- Slug-scoped findings stay inline next to the field they
                      concern (#456); the full set lives in the SEO panel. --%>
                <.seo_findings
                  report={slug_report(@seo_report)}
                  slug_customized?={@slug_customized?}
                  class="mt-1"
                />
                <.field_cursors field="slug" cursors={@cursors} />
              </div>
              <div class={["relative sm:col-span-2", lock_ring(@locked_fields, "path_alias")]}>
                <.input
                  field={@form[:path_alias]}
                  label={gettext("Path alias (optional)")}
                  placeholder="/acupuncture/needle/size/14mm"
                  readonly={field_locked?(@locked_fields, "path_alias")}
                  {field_attrs("path_alias")}
                />
                <p class="mt-1 text-xs text-base-content/60">
                  {gettext(
                    "A multi-segment canonical URL. When set, the flat slug URL 301s here; changing it leaves a redirect behind on published content."
                  )}
                </p>
                <.field_cursors field="path_alias" cursors={@cursors} />
              </div>
            </div>

            <div :if={@has_excerpt} class={["relative", lock_ring(@locked_fields, "excerpt")]}>
              <.input
                field={@form[:excerpt]}
                type="textarea"
                label={gettext("Excerpt")}
                hint={
                  gettext(
                    "A short summary shown in listings and used as a fallback for social shares."
                  )
                }
                readonly={field_locked?(@locked_fields, "excerpt")}
                {field_attrs("excerpt")}
              />
              <.field_cursors field="excerpt" cursors={@cursors} />
            </div>

            <div class="space-y-3">
              <h2 class="text-lg font-medium">{gettext("Blocks")}</h2>

              <%!-- Announces keyboard reorder moves to screen readers (#171). --%>
              <p class="sr-only" role="status" aria-live="polite">{assigns[:moved_announcement]}</p>

              <%!-- Insert a block before the first one (B2). --%>
              <.block_inserter
                :if={blocks_count(@form) > 0}
                id="insert-start"
                block_types={@block_types}
                anchor="start"
                compact
              />

              <div id="blocks-sortable" phx-hook="Sortable" class="space-y-3">
                <.inputs_for :let={bf} field={@form[:blocks]}>
                  <div
                    id={"block-#{bf.index}"}
                    data-sort-id={bf.index}
                    class="group rounded border border-base-content/15 p-3"
                  >
                    <%!-- Carries the block's stable id into save/validate params so
                          it can be addressed by identity (columns render their own). --%>
                    <input
                      :if={block_type_string(bf) != "columns"}
                      type="hidden"
                      name={bf[:id].name}
                      value={bf[:id].value}
                    />
                    <%!-- Block chrome: the type label stays put; the controls
                          (drag / move / duplicate / delete) fade in on hover, and
                          on keyboard focus too so they stay reachable (#171). --%>
                    <div class="mb-2 flex items-center justify-between gap-3">
                      <span class="rounded bg-base-200 px-2 py-1 text-sm font-medium">
                        {dsl_label(block_type_string(bf))}
                      </span>
                      <div class="flex items-center gap-0.5 text-base-content/60 opacity-0 transition focus-within:opacity-100 group-hover:opacity-100">
                        <span
                          data-drag-handle
                          aria-label={gettext("Drag to reorder")}
                          class="cursor-grab rounded p-1 hover:bg-base-200 hover:text-base-content"
                        >
                          <.icon name="hero-bars-3" class="size-4" />
                        </span>
                        <button
                          type="button"
                          phx-click="move_block"
                          phx-value-bid={bf[:id].value}
                          phx-value-dir="up"
                          disabled={bf.index == 0}
                          aria-label={gettext("Move block up")}
                          class="rounded p-1 hover:bg-base-200 hover:text-base-content disabled:cursor-not-allowed disabled:opacity-30 disabled:hover:bg-transparent"
                        >
                          <.icon name="hero-chevron-up" class="size-4" />
                        </button>
                        <button
                          type="button"
                          phx-click="move_block"
                          phx-value-bid={bf[:id].value}
                          phx-value-dir="down"
                          disabled={bf.index == blocks_count(@form) - 1}
                          aria-label={gettext("Move block down")}
                          class="rounded p-1 hover:bg-base-200 hover:text-base-content disabled:cursor-not-allowed disabled:opacity-30 disabled:hover:bg-transparent"
                        >
                          <.icon name="hero-chevron-down" class="size-4" />
                        </button>
                        <button
                          type="button"
                          phx-click="duplicate_block"
                          phx-value-bid={bf[:id].value}
                          aria-label={gettext("Duplicate block")}
                          class="rounded p-1 hover:bg-base-200 hover:text-base-content"
                        >
                          <.icon name="hero-document-duplicate" class="size-4" />
                        </button>
                        <button
                          type="button"
                          phx-click="remove_block"
                          phx-value-bid={bf[:id].value}
                          data-confirm={gettext("Delete this block? This can't be undone.")}
                          aria-label={gettext("Remove block")}
                          class="rounded p-1 hover:bg-base-200 hover:text-error"
                        >
                          <.icon name="hero-trash" class="size-4" />
                        </button>
                      </div>
                    </div>
                    <%!-- The collab lock UI (ring + "who's editing" badge) lives on
                          this non-ignored wrapper so it can update, while the inner
                          editor stays phx-update="ignore" (#140). --%>
                    <%!-- The editor host is keyed by the block's STABLE id (falling
                          back to the index only for a brand-new, not-yet-saved block
                          that has none), so reordering a saved block relocates the
                          same DOM node — its mounted TipTap editor, cursor and undo
                          stack survive instead of remounting. Content saves through
                          the id-keyed `rich_text_body` push, so a stable host can't
                          corrupt it; the `data-block-index` below is a `data-*`
                          attribute (LiveView keeps those in sync even inside a
                          `phx-update="ignore"` host), so the push still reports the
                          block's live index. The legacy_html fallback <input> is
                          deliberately OUTSIDE the ignore host: its param name is
                          index-based, and only a re-rendered (non-ignored) name stays
                          correct after a reorder — an ignored name would freeze at
                          the mount-time index and swap neighbours' content on a
                          form submit. --%>
                    <div
                      :if={block_type_string(bf) == "rich_text"}
                      class={["relative", lock_ring(@locked_fields, bf[:body].name)]}
                    >
                      <.field_cursors field={bf[:body].name} cursors={@cursors} />
                      <div
                        id={"rt-#{rich_host_key(bf)}-v#{@editor_version}"}
                        phx-hook="RichText"
                        phx-update="ignore"
                        data-block-id={bf[:id].value}
                        data-content={rich_text_editor_html(bf)}
                        data-editor-label={gettext("Rich text editor")}
                        data-lock-field={bf[:body].name}
                        data-block-index={bf.index}
                        data-collab-token={@collab_token}
                        data-collab-topic={@collab_token && @collab_topic}
                        data-collab-fragment={@collab_token && collab_fragment(bf)}
                        data-collab-user={@collab_token && initials(Presence.display_name(@actor))}
                        data-collab-color={@collab_token && color_hex_for(@actor.id)}
                        role="group"
                        aria-label={gettext("Rich text block")}
                      >
                        <div
                          data-toolbar
                          role="toolbar"
                          aria-label={gettext("Text formatting")}
                          class="mb-1 flex flex-wrap gap-1"
                        >
                        </div>
                        <div data-editor></div>
                        <%!-- One coherent slash command (#150, B3): inside a text
                              block it formats the text and can drop a new block in
                              below; on the empty canvas it opens the block palette. --%>
                        <p class="mt-1 text-xs text-base-content/70">
                          {gettext("Type / to format this text or insert a block below.")}
                        </p>
                      </div>
                      <%!-- No-JS/JS-pending fallback: the server-rendered form
                            round-trips legacy_html exactly as stored. Lives outside
                            the ignore host so its index-based name re-renders on a
                            reorder; the server (not JS) owns its value, so there is
                            nothing for a patch to clobber. When a `rich_text_body`
                            push lands, the cast writes `body` and clears legacy_html. --%>
                      <input
                        type="hidden"
                        name={bf[:legacy_html].name}
                        value={bf[:legacy_html].value}
                        data-input
                      />
                      <%!-- Only for a block that already has its stable id: the
                            suggestion is delivered by a `push_event` the hook
                            matches on `data-block-id`, so a block without one
                            has nothing to deliver to. --%>
                      <.assist_panel
                        :if={@assist_enabled? and bf[:id].value}
                        block_id={bf[:id].value}
                        open?={@assist_block == bf[:id].value}
                        action={@assist_action}
                        running?={@assist_running?}
                        result={@assist_result}
                        egress?={@assist_egress?}
                        provider={@assist_provider}
                        conflict={@conflict}
                      />
                    </div>
                    <div :if={block_type_string(bf) == "image"} class="space-y-2">
                      <img
                        :if={safe_preview_src(bf[:url].value)}
                        src={safe_preview_src(bf[:url].value)}
                        alt=""
                        class="max-h-40 rounded border border-base-content/10"
                      />
                      <input type="hidden" name={bf[:media_id].name} value={media_id_of(bf)} />
                      <div class="flex items-center gap-2">
                        <button
                          type="button"
                          phx-click="open_picker"
                          phx-value-bid={bf[:id].value}
                          class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
                        >
                          <.icon name="hero-photo" class="mr-1 size-4" />{gettext(
                            "Choose from library"
                          )}
                        </button>
                      </div>
                      <.input
                        field={bf[:url]}
                        label={gettext("Image URL")}
                        placeholder={gettext("…or paste a URL")}
                      />
                      <.input field={bf[:alt]} label={gettext("Alt text")} />
                      <.input field={bf[:caption]} label={gettext("Caption")} />
                    </div>
                    <div :if={block_type_string(bf) == "file"} class="space-y-2">
                      <input type="hidden" name={bf[:media_id].name} value={media_id_of(bf)} />
                      <input type="hidden" name={bf[:filename].name} value={bf[:filename].value} />
                      <input
                        type="hidden"
                        name={bf[:content_type].name}
                        value={bf[:content_type].value}
                      />
                      <input
                        type="hidden"
                        name={bf[:byte_size].name}
                        value={bf[:byte_size].value}
                      />
                      <p :if={bf[:filename].value} class="flex items-center gap-2 text-sm">
                        <.icon name="hero-document" class="size-4 shrink-0" />
                        <span class="truncate">{bf[:filename].value}</span>
                      </p>
                      <div class="flex items-center gap-2">
                        <button
                          type="button"
                          phx-click="open_file_picker"
                          phx-value-bid={bf[:id].value}
                          class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
                        >
                          <.icon name="hero-document-arrow-down" class="mr-1 size-4" />{gettext(
                            "Choose from library"
                          )}
                        </button>
                      </div>
                      <.input
                        field={bf[:title]}
                        label={gettext("Title")}
                        placeholder={bf[:filename].value}
                      />
                      <.input field={bf[:description]} label={gettext("Description")} />
                    </div>
                    <.video_editor :if={block_type_string(bf) == "video"} bf={bf} />
                    <.audio_editor :if={block_type_string(bf) == "audio"} bf={bf} />
                    <.gallery_editor :if={block_type_string(bf) == "gallery"} bf={bf} />
                    <.columns_editor
                      :if={block_type_string(bf) == "columns"}
                      bf={bf}
                      columns={col_state(@block_children, bf)}
                      child_types={@nested_child_types}
                    />
                    <div :if={
                      block_type_string(bf) not in [
                        "rich_text",
                        "image",
                        "file",
                        "video",
                        "audio",
                        "columns",
                        "gallery"
                      ]
                    }>
                      <.dsl_block_fields
                        bf={bf}
                        role={@tier}
                        locked_fields={@locked_fields}
                        cursors={@cursors}
                      />
                      <.item_rows_editor :if={row_editor_type?(block_type_string(bf))} bf={bf} />
                    </div>
                    <%!-- Comments (#404) are rendered here, outside every
                          per-type branch above, so they apply to any block
                          type — unlike AI assist, which is rich_text-only. --%>
                    <.comment_panel
                      :if={bf[:id].value}
                      block_id={bf[:id].value}
                      comments={@comments}
                      open?={@comment_block == bf[:id].value}
                      draft={if @comment_block == bf[:id].value, do: @comment_draft}
                    />
                    <%!-- Inline "+" to insert a block right after this one (B2). --%>
                    <.block_inserter
                      id={"insert-after-#{bf[:id].value}"}
                      block_types={@block_types}
                      anchor={bf[:id].value}
                      compact
                    />
                  </div>
                </.inputs_for>
              </div>

              <%!-- Inviting empty state when a page has no blocks yet (Theme A). --%>
              <div
                :if={blocks_count(@form) == 0}
                class="rounded-lg border border-dashed border-base-content/20 px-6 py-10 text-center"
              >
                <.icon name="hero-squares-plus" class="mx-auto size-8 text-base-content/30" />
                <p class="mt-2 text-sm font-medium">{gettext("No blocks yet")}</p>
                <p class="mt-1 text-sm text-base-content/60">
                  {gettext("Add your first block below to start building this page.")}
                </p>
              </div>

              <.block_inserter block_types={@block_types} global_key={true} />
            </div>
          </div>

          <%!-- Right inspector rail (Theme A): Settings / Preview / History.
                EVERY panel stays mounted so its form fields survive submit — the
                tab toggles CSS visibility only, never `:if`. On mobile the rail
                stacks below the content column; on desktop it's a sticky sidebar
                that scrolls internally when the settings run long. --%>
          <div class="space-y-3 lg:sticky lg:top-20 lg:max-h-[calc(100vh-6rem)] lg:self-start lg:overflow-y-auto lg:pr-0.5">
            <.inspector_tabs
              tab={@inspector_tab}
              settings_alert={any_custom_field_errors?(@form, @field_definitions)}
            />

            <%!-- ── Preview ─────────────────────────────────────────────── --%>
            <div class={[@inspector_tab != :preview && "hidden"]}>
              <p class="mb-2 flex items-center gap-1.5 text-xs text-base-content/50">
                <.icon name="hero-cursor-arrow-rays" class="size-3.5" />
                {gettext("Hover a block and click Edit to change it on the page.")}
              </p>
              <.preview_article
                form={@form}
                html={@preview_html}
                kind={@kind}
                slug={@record.slug}
              />
            </div>

            <%!-- ── Settings ────────────────────────────────────────────── --%>
            <div class={["space-y-4", @inspector_tab != :settings && "hidden"]}>
              <.inspector_section title={gettext("Assignment")}>
                <.task_list
                  tasks={@tasks}
                  open?={@task_assign_open?}
                  draft={@task_draft}
                  assignable_users={@assignable_users}
                />
              </.inspector_section>

              <.inspector_section title={gettext("Release")}>
                <.release_panel
                  item={@release_item}
                  release={@release_of_item}
                  releases={@releases}
                  draft={@release_draft}
                />
              </.inspector_section>

              <.inspector_section title={gettext("Organization & relationships")}>
                <.input
                  field={@form[:category_id]}
                  type="select"
                  label={gettext("Category")}
                  prompt="— None —"
                  options={Enum.map(@categories, &{&1.name, &1.id})}
                />

                <.input
                  :if={length(@audiences) > 1}
                  field={@form[:audience]}
                  type="select"
                  label={gettext("Audience")}
                  options={@audiences}
                />

                <.tag_picker
                  form={@form}
                  tags={@tags}
                  tag_groups={@tag_groups}
                  kind={@kind}
                  record={@record}
                />

                <.featured_image_field form={@form} media={@media} />

                <.input
                  field={@form[@related_field]}
                  type="select"
                  multiple
                  label={gettext("Related %{kind}s", kind: @kind)}
                  value={selected_ids(@form, @related_field, current_ids(@related_current))}
                  options={Enum.map(@siblings, &{&1.title, &1.id})}
                />
              </.inspector_section>

              <.inspector_section :if={@field_definitions != []} title={gettext("Custom fields")}>
                <.custom_field_input
                  :for={definition <- @field_definitions}
                  definition={definition}
                  name={"#{@form.name}[custom_fields][#{definition.name}]"}
                  value={custom_field_value(@form, definition.name)}
                  errors={custom_field_errors(@form, definition.name)}
                  options={custom_field_options(definition, @media, @reference_options)}
                />
              </.inspector_section>

              <%!-- Accessibility (#495) sits in its own section rather than
                    under SEO, because it is a different question with a
                    different audience — and because a finding buried three
                    sections into "SEO & scheduling" is one an author fixing
                    accessibility will never look for. Same checks underneath;
                    see `Kiln.Advisory`. --%>
              <.inspector_section id="inspector-accessibility" title={gettext("Accessibility")}>
                <:aside>
                  <.a11y_grade_badge report={@a11y_report} />
                </:aside>
                <%!-- Advisory only — nothing here ever blocks a save. The
                      hard gate on alt text is `Validations.MediaAltText`
                      (#403), which is a separate, opt-in policy. --%>
                <.a11y_findings
                  :if={@a11y_report.findings != []}
                  report={@a11y_report}
                  class="rounded border border-base-content/10 bg-base-200/40 p-2"
                />
                <p :if={@a11y_report.findings == []} class="text-xs text-base-content/60">
                  {ngettext(
                    "No accessibility issues found in %{count} applicable check.",
                    "No accessibility issues found in %{count} applicable checks.",
                    @a11y_report.total,
                    count: @a11y_report.total
                  )}
                </p>
              </.inspector_section>

              <%!-- Compliance (#377). Rendered only when there is something to
                    say: with claim checking off both checks report `:n_a`, so
                    `total` is 0 and the section never appears — an install
                    that never asked for a claims panel doesn't grow one. --%>
              <.inspector_section
                :if={@compliance_report.total > 0}
                id="inspector-compliance"
                title={gettext("Compliance")}
              >
                <:aside>
                  <.compliance_grade_badge report={@compliance_report} />
                </:aside>
                <%!-- Advisory only. The hard gate is
                      `Validations.ComplianceClaims`, which is separate and
                      opt-in on top of this — see `KilnCMS.Compliance`. --%>
                <.compliance_findings
                  :if={@compliance_report.findings != []}
                  report={@compliance_report}
                  class="rounded border border-base-content/10 bg-base-200/40 p-2"
                />
                <p :if={@compliance_report.findings == []} class="text-xs text-base-content/60">
                  {ngettext(
                    "No claim issues found in %{count} applicable check.",
                    "No claim issues found in %{count} applicable checks.",
                    @compliance_report.total,
                    count: @compliance_report.total
                  )}
                </p>
              </.inspector_section>

              <.inspector_section title={gettext("SEO & scheduling")}>
                <:aside>
                  <.seo_grade_badge report={@seo_report} />
                </:aside>
                <%!-- Advisory only — nothing here ever blocks a save (#476). --%>
                <.seo_findings
                  :if={@seo_report.findings != []}
                  report={@seo_report}
                  slug_customized?={@slug_customized?}
                  class="rounded border border-base-content/10 bg-base-200/40 p-2"
                />
                <div :if={@seo_enabled?}>
                  <%!-- `type="button"` is mandatory: this sits inside the main
                        <.form>, so the default type would submit it. --%>
                  <button
                    type="button"
                    phx-click="seo_suggest"
                    disabled={@seo_drafting? or @conflict}
                    class="btn btn-sm btn-default"
                  >
                    {gettext("Suggest with AI")}
                    <.icon
                      :if={@seo_drafting?}
                      name="hero-arrow-path"
                      class="ml-1 size-3 motion-safe:animate-spin"
                    />
                  </button>
                  <%!-- Standing, non-dismissible: the operator chose a
                        third-party provider, the editor clicking didn't. --%>
                  <p :if={@seo_egress?} class="mt-1 text-xs text-warning">
                    {gettext(
                      "Suggestions are generated by %{provider}. This page's title, excerpt and text are sent to that provider.",
                      provider: @seo_provider
                    )}
                  </p>
                  <.seo_suggestions
                    draft={@seo_drafts}
                    fields={suggested_fields(@seo_drafts)}
                    dismissed={@seo_dismissed}
                    locked_fields={@locked_fields}
                  />
                </div>
                <div class={["relative", lock_ring(@locked_fields, "seo_title")]}>
                  <.input
                    field={@form[:seo_title]}
                    label={gettext("SEO title")}
                    hint={
                      gettext(
                        "Overrides the title in search results and browser tabs. Falls back to the title."
                      )
                    }
                    readonly={field_locked?(@locked_fields, "seo_title")}
                    {field_attrs("seo_title")}
                  />
                  <.field_cursors field="seo_title" cursors={@cursors} />
                </div>
                <div class={["relative", lock_ring(@locked_fields, "seo_description")]}>
                  <.input
                    field={@form[:seo_description]}
                    type="textarea"
                    label={gettext("SEO description")}
                    hint={
                      gettext(
                        "The snippet shown under the title in search results (aim for ~155 characters)."
                      )
                    }
                    readonly={field_locked?(@locked_fields, "seo_description")}
                    {field_attrs("seo_description")}
                  />
                  <.field_cursors field="seo_description" cursors={@cursors} />
                </div>
                <div class={["relative", lock_ring(@locked_fields, "seo_keywords")]}>
                  <.input
                    field={@form[:seo_keywords]}
                    label={gettext("SEO keywords")}
                    readonly={field_locked?(@locked_fields, "seo_keywords")}
                    {field_attrs("seo_keywords")}
                  />
                  <p class="mt-1 text-xs text-base-content/60">
                    {gettext("Comma-separated; the first keyphrase drives the auto-derived slug.")}
                  </p>
                  <.field_cursors field="seo_keywords" cursors={@cursors} />
                </div>
                <div class={["relative", lock_ring(@locked_fields, "seo_image")]}>
                  <.input
                    field={@form[:seo_image]}
                    label={gettext("Social image")}
                    hint={gettext("Image shown when this page is shared on social media.")}
                    placeholder="/uploads/cover.jpg"
                    readonly={field_locked?(@locked_fields, "seo_image")}
                    {field_attrs("seo_image")}
                  />
                  <%!-- The URL box stays for off-site absolute URLs; these
                        shortcuts cover the common cases (#476). --%>
                  <div class="mt-1 flex flex-wrap items-center gap-2">
                    <button
                      type="button"
                      phx-click="open_seo_image_picker"
                      disabled={field_locked?(@locked_fields, "seo_image")}
                      class="btn btn-sm btn-default"
                    >
                      {gettext("Choose from library")}
                    </button>
                    <button
                      :if={@form[:featured_image_id].value not in [nil, ""]}
                      type="button"
                      phx-click="use_featured_image"
                      disabled={field_locked?(@locked_fields, "seo_image")}
                      class="btn btn-sm btn-default"
                    >
                      {gettext("Use featured image")}
                    </button>
                    <button
                      :if={@form[:seo_image].value not in [nil, ""]}
                      type="button"
                      phx-click="clear_seo_image"
                      disabled={field_locked?(@locked_fields, "seo_image")}
                      class="text-sm text-base-content/70 hover:text-error"
                    >
                      {gettext("Remove")}
                    </button>
                  </div>
                  <.field_cursors field="seo_image" cursors={@cursors} />
                </div>
                <.social_card form={@form} media={@media} current_org={@current_org} />
                <div class={["relative", lock_ring(@locked_fields, "canonical_url")]}>
                  <.input
                    field={@form[:canonical_url]}
                    label={gettext("Canonical URL")}
                    hint={
                      gettext(
                        "The preferred URL, if this content is reachable at more than one address."
                      )
                    }
                    readonly={field_locked?(@locked_fields, "canonical_url")}
                    {field_attrs("canonical_url")}
                  />
                  <.field_cursors field="canonical_url" cursors={@cursors} />
                </div>
                <.input field={@form[:locale]} label={gettext("Locale")} />
                <%!-- The visible input edits local wall-clock time; the hidden
                      input carries the UTC instant (UtcDatetimeInput hook).
                      Keyed on editor_version so conflict reloads / restores
                      remount it from the fresh form (as rich text does). --%>
                <div
                  id={"scheduled-at-#{@editor_version}"}
                  phx-hook="UtcDatetimeInput"
                  phx-update="ignore"
                >
                  <label
                    for={"scheduled-at-local-#{@editor_version}"}
                    class="mb-1 block text-sm font-medium"
                  >
                    {gettext("Scheduled publish at")}
                  </label>
                  <input
                    type="datetime-local"
                    id={"scheduled-at-local-#{@editor_version}"}
                    data-local-input
                    class="field-input"
                  />
                  <input
                    type="hidden"
                    name={@form[:scheduled_at].name}
                    value={@form[:scheduled_at].value && to_string(@form[:scheduled_at].value)}
                    data-utc-input
                  />
                  <p class="mt-1 text-xs text-base-content/60">
                    {gettext("Shown in your local timezone; stored as UTC.")}
                  </p>
                </div>
                <%!-- The embargo end — same local/UTC input pair as above. --%>
                <div
                  id={"unpublish-at-#{@editor_version}"}
                  phx-hook="UtcDatetimeInput"
                  phx-update="ignore"
                >
                  <label
                    for={"unpublish-at-local-#{@editor_version}"}
                    class="mb-1 block text-sm font-medium"
                  >
                    {gettext("Scheduled unpublish at")}
                  </label>
                  <input
                    type="datetime-local"
                    id={"unpublish-at-local-#{@editor_version}"}
                    data-local-input
                    class="field-input"
                  />
                  <input
                    type="hidden"
                    name={@form[:unpublish_at].name}
                    value={@form[:unpublish_at].value && to_string(@form[:unpublish_at].value)}
                    data-utc-input
                  />
                  <p class="mt-1 text-xs text-base-content/60">
                    {gettext("Published content is taken back to draft at this time.")}
                  </p>
                </div>
              </.inspector_section>

              <%!-- Internal links (#377). Loaded on an explicit click, never on
                    mount: it costs a vector query plus a read per neighbour, and
                    inspector sections are always expanded, so there is no "first
                    open" to hang lazy loading off. --%>
              <.inspector_section title={gettext("Internal links")}>
                <p class="text-xs text-base-content/60">
                  {gettext("Related pages worth linking to from this one.")}
                </p>

                <p :if={@seo_links == []} class="text-xs text-base-content/60">
                  {link_empty_reason(@record)}
                </p>

                <ul :if={@seo_links not in [nil, []]} class="space-y-1.5">
                  <li
                    :for={link <- @seo_links}
                    class="rounded border border-base-content/10 bg-base-200/40 p-2"
                  >
                    <p class="text-xs font-medium">{link.title || link.slug}</p>
                    <div class="mt-0.5 flex items-center gap-2">
                      <code class="min-w-0 flex-1 truncate text-xs text-base-content/60">
                        {link.path}
                      </code>
                      <%!-- Copy, not insert: mutating the block tree server-side
                            would fight the TipTap/Y.Doc editor. --%>
                      <button
                        type="button"
                        id={"seo-link-copy-#{link.id}"}
                        phx-hook="Clipboard"
                        data-clipboard-text={link.path}
                        aria-label={gettext("Copy link to %{title}", title: link.title || link.slug)}
                        class="shrink-0 text-xs underline"
                      >
                        {gettext("Copy")}
                      </button>
                    </div>
                  </li>
                </ul>

                <button
                  type="button"
                  phx-click="seo_links_refresh"
                  disabled={@seo_links_loading?}
                  class="btn btn-sm btn-default"
                >
                  {if @seo_links == nil,
                    do: gettext("Find related pages"),
                    else: gettext("Refresh")}
                  <.icon
                    :if={@seo_links_loading?}
                    name="hero-arrow-path"
                    class="ml-1 size-3 motion-safe:animate-spin"
                  />
                </button>
              </.inspector_section>
            </div>

            <%!-- ── History ─────────────────────────────────────────────── --%>
            <div class={["space-y-4", @inspector_tab != :history && "hidden"]}>
              <.inspector_section :if={length(@translations) > 1} title={gettext("Translations")}>
                <ul class="space-y-2">
                  <li
                    :for={cov <- @translations}
                    class="flex items-center justify-between gap-3 text-sm"
                  >
                    <span class="flex items-center gap-2">
                      <span class="font-mono text-xs font-semibold uppercase">{cov.locale}</span>
                      <span
                        :if={cov.record && cov.record.id == @record.id}
                        class="text-xs text-base-content/50"
                      >
                        {gettext("(this one)")}
                      </span>
                      <span
                        :if={cov.stale?}
                        class="rounded bg-warning/15 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide text-warning"
                        title={gettext("The source locale was updated after this translation.")}
                      >
                        {gettext("Outdated")}
                      </span>
                    </span>
                    <span
                      :if={cov.record && cov.record.id == @record.id}
                      class="text-xs text-base-content/70"
                    >
                      {state_label(cov.status)}
                    </span>
                    <.link
                      :if={cov.record && cov.record.id != @record.id}
                      navigate={~p"/editor/content/#{@kind}/#{cov.record.id}"}
                      class="text-xs text-primary hover:underline"
                    >
                      {state_label(cov.status)} — {gettext("edit")}
                    </.link>
                    <button
                      :if={is_nil(cov.record)}
                      type="button"
                      phx-click="create_translation"
                      phx-value-locale={cov.locale}
                      class="btn btn-sm btn-default"
                    >
                      {gettext("Create translation")}
                    </button>
                  </li>
                </ul>
              </.inspector_section>

              <.inspector_section title={
                gettext("Version history (%{count})", count: length(@versions))
              }>
                <p :if={@versions == []} class="text-sm text-base-content/60">
                  {gettext("No saved versions yet.")}
                </p>
                <div :if={@versions != []}>
                  <p class="mb-2 text-xs text-base-content/60">
                    {gettext("Select two to see what changed between them.")}
                  </p>
                  <ul class="space-y-2">
                    <li class="flex items-center gap-2 text-sm">
                      <.compare_toggle
                        pick={@current_pick}
                        picked={@current_pick in @compare_pick}
                        label={gettext("Current draft")}
                      />
                      <span class="text-base-content/70">{gettext("Current draft")}</span>
                    </li>
                    <li
                      :for={version <- @versions}
                      class="flex items-center justify-between gap-3 text-sm"
                    >
                      <span class="flex min-w-0 items-center gap-2">
                        <.compare_toggle
                          pick={version.id}
                          picked={version.id in @compare_pick}
                          label={version_label(version)}
                        />
                        <span class="text-base-content/70">
                          {version_label(version)}
                          <span
                            :if={version.id == @record.published_version_id}
                            class="ml-1 rounded bg-success/15 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide text-success"
                          >
                            {gettext("Live published")}
                          </span>
                        </span>
                      </span>
                      <button
                        type="button"
                        phx-click="restore"
                        phx-value-version_id={version.id}
                        data-confirm={gettext("Restore content to this version?")}
                        class="btn btn-sm btn-default"
                      >
                        {gettext("Restore")}
                      </button>
                    </li>
                  </ul>
                  <button
                    type="button"
                    phx-click="open_compare"
                    disabled={length(@compare_pick) != 2}
                    class="btn btn-sm btn-default mt-3 disabled:opacity-50"
                  >
                    {gettext("Compare selected")}
                  </button>
                </div>
              </.inspector_section>
            </div>
          </div>
        </div>
      </.form>

      <.image_picker
        :if={@picking != nil}
        index={@picking}
        media={@media}
        results={@picker_media}
        query={@media_query}
        picked={@picked}
      />

      <.file_picker
        :if={@file_picking != nil}
        files={@file_media}
        results={@picker_files}
        query={@file_query}
      />

      <.av_picker
        :if={@av_picking != nil}
        target={@av_picking}
        items={@av_media}
        images={@media}
        results={@picker_av}
        query={@av_query}
      />

      <.version_compare
        :if={@compare}
        diff={@compare.diff}
        left={@compare.left}
        right={@compare.right}
      />
    </Layouts.console>
    """
  end

  # Pick-for-comparison toggle on a version-history row.
  #
  # A `<button>` with checkbox semantics rather than an `<input type="checkbox">`:
  # this sits inside the main `<.form>`, where even an unnamed input's change
  # event bubbles up and fires the form's `phx-change` (see the tag filter's note
  # above), which would run validation and mark the draft dirty on every pick.
  attr :pick, :string, required: true
  attr :picked, :boolean, required: true
  attr :label, :string, required: true

  defp compare_toggle(assigns) do
    ~H"""
    <button
      type="button"
      role="checkbox"
      aria-checked={to_string(@picked)}
      aria-label={gettext("Compare %{version}", version: @label)}
      phx-click="toggle_compare"
      phx-value-version_id={@pick}
      class={[
        "flex size-4 shrink-0 items-center justify-center rounded border",
        (@picked && "border-primary bg-primary text-primary-content") ||
          "border-base-content/30 hover:border-base-content/60"
      ]}
    >
      <.icon :if={@picked} name="hero-check" class="size-3" />
    </button>
    """
  end

  # Sticky editor action bar (Theme A). Sits just under the console shell header
  # (`sticky top-14`, below the shell's `top-0` z-20 bar) so Save, workflow, and
  # the live save state are always reachable no matter how long the content runs.
  attr :kind, :atom, required: true
  attr :record, :any, required: true
  attr :save_state, :atom, required: true
  attr :tier, :atom, required: true
  attr :conflict, :boolean, required: true
  attr :editors, :list, required: true
  attr :actor, :any, required: true
  attr :word_count, :integer, required: true
  attr :a11y_report, :map, required: true

  defp editor_action_bar(assigns) do
    # Resolved once per render rather than per interpolation: `words_per_minute/0`
    # WARNS on a misconfigured value, so reading it three times turned one bad
    # config line into three log lines per keystroke.
    wpm = KilnCMS.CMS.Calculations.ReadingTime.words_per_minute()

    assigns =
      assigns
      |> assign(:wpm, wpm)
      |> assign(:reading_minutes, reading_minutes(assigns.word_count, wpm))

    ~H"""
    <div class="sticky top-14 z-10 rounded-lg border border-base-content/10 bg-base-100/90 px-3 py-2.5 shadow-sm backdrop-blur">
      <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
        <div class="flex flex-wrap items-center gap-2">
          <span class={[
            "inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium",
            state_badge_class(@record.state)
          ]}>
            <span class="size-1.5 rounded-full bg-current opacity-70"></span>
            {state_label(@record.state)}
          </span>
          <%!-- After saving a schedule, nothing else says it exists (U-M4). --%>
          <span
            :if={@record.scheduled_at && @record.state in [:draft, :in_review]}
            class="inline-flex items-center gap-1 text-xs text-base-content/60"
          >
            <.icon name="hero-clock" class="size-3.5" />
            {gettext("Publishes")}
            <time
              id="scheduled-publish-badge"
              phx-hook="LocalTime"
              datetime={DateTime.to_iso8601(@record.scheduled_at)}
            >{Calendar.strftime(@record.scheduled_at, "%b %-d, %H:%M")} UTC</time>
          </span>
          <span
            :if={@record.unpublish_at && @record.state == :published}
            class="inline-flex items-center gap-1 text-xs text-base-content/60"
          >
            <.icon name="hero-clock" class="size-3.5" />
            {gettext("Unpublishes")}
            <time
              id="scheduled-unpublish-badge"
              phx-hook="LocalTime"
              datetime={DateTime.to_iso8601(@record.unpublish_at)}
            >{Calendar.strftime(@record.unpublish_at, "%b %-d, %H:%M")} UTC</time>
          </span>
          <.presence_roster editors={@editors} current_id={@actor.id} />

          <%!-- Word count and reading time (#492). Free to render: the count
                comes from `@seo_body_stats`, which the advisory panel already
                folds from the block tree and memoizes on a `phash2` digest, so
                this adds no per-keystroke walk of its own. --%>
          <span
            :if={@word_count > 0}
            class="inline-flex items-center gap-1 text-xs text-base-content/60"
            title={gettext("Reading time is an estimate at %{wpm} words per minute.", wpm: @wpm)}
          >
            <.icon name="hero-clock" class="size-3.5" />
            {ngettext("%{count} word", "%{count} words", @word_count, count: @word_count)} &middot; {ngettext(
              "%{count} min read",
              "%{count} min read",
              @reading_minutes,
              count: @reading_minutes
            )}
          </span>

          <%!-- Accessibility summary (#495). Up here rather than only in the
                inspector rail because a panel three sections down is one an
                author has to already care about to find — and the people this
                helps are the ones who don't yet know there's a problem.
                Free to render: the report is computed for the panel anyway.

                A button, not a badge: it opens the Settings tab, where the
                Accessibility section lives — the "expandable to the panel"
                half of the ask. It reuses the tab strip's own event rather
                than introducing a scroll hook, so there is one code path that
                changes which panel is showing.

                Hidden on a brand-new page: greeting an author with a verdict
                on an empty draft is noise. NOT gated on `total`, which is a
                trap — a check that passes counts as *applicable*, so an empty
                document reports one passing check and the chip would render
                "Accessible" on a page with nothing in it. Content, or a
                finding to show, is the honest signal. --%>
          <button
            :if={@a11y_report.findings != [] or @word_count > 0}
            id="a11y-chip"
            type="button"
            phx-click="switch_inspector_tab"
            phx-value-tab="settings"
            class={[
              "inline-flex items-center gap-1.5 rounded-full px-2 py-1 text-xs font-medium",
              a11y_chip_class(@a11y_report.grade)
            ]}
            title={a11y_chip_title(@a11y_report)}
          >
            <.icon name={a11y_chip_icon(@a11y_report.grade)} class="size-3.5" />
            {a11y_chip_label(@a11y_report)}
          </button>
        </div>

        <div class="ml-auto flex flex-wrap items-center gap-2">
          <.autosave_status
            :if={@record.state == :draft or @save_state != :saved}
            state={@save_state}
          />
          <.workflow_buttons state={@record.state} tier={@tier} />
          <.button
            type="submit"
            variant="primary"
            disabled={@conflict}
            phx-disable-with={gettext("Saving…")}
            title={@conflict && gettext("Reload to resolve the edit conflict before saving.")}
          >
            {gettext("Save")}
          </.button>
        </div>
      </div>
    </div>
    """
  end

  # Same arithmetic as `KilnCMS.CMS.Calculations.ReadingTime`, applied to the
  # in-progress draft rather than the saved record — so the editor's number and
  # the one consumers read off the API agree once the draft is saved.
  # Traffic-light vocabulary, shared with the grade pill in the panel
  # (`KilnCMSWeb.AdvisoryComponents`) so the chip and the section it scrolls to
  # can never disagree about what colour this document is.
  defp a11y_chip_class(:good), do: "bg-success/15 text-success hover:bg-success/25"
  defp a11y_chip_class(:ok), do: "bg-warning/20 text-warning-content hover:bg-warning/30"
  defp a11y_chip_class(:poor), do: "bg-error/12 text-error hover:bg-error/20"

  defp a11y_chip_icon(:good), do: "hero-check-circle"
  defp a11y_chip_icon(_grade), do: "hero-exclamation-circle"

  # The count, not the grade word: "2 issues" is the actionable number, and
  # the colour already carries the severity.
  defp a11y_chip_label(%{findings: []}), do: gettext("Accessible")

  defp a11y_chip_label(%{findings: findings}) do
    ngettext("%{count} a11y issue", "%{count} a11y issues", length(findings),
      count: length(findings)
    )
  end

  defp a11y_chip_title(%{findings: []}),
    do: gettext("No accessibility issues found. Opens the Accessibility panel.")

  defp a11y_chip_title(_report),
    do: gettext("Opens the Accessibility panel.")

  defp reading_minutes(0, _wpm), do: 0
  defp reading_minutes(words, wpm), do: ceil(words / wpm)

  # Tab strip for the right inspector rail (Theme A). Switching is pure view
  # state; the panels themselves stay mounted (toggled by CSS in render/1).
  # `settings_alert` raises a dot on the Settings tab so validation errors in a
  # hidden panel still get noticed.
  attr :tab, :atom, required: true
  attr :settings_alert, :boolean, default: false

  defp inspector_tabs(assigns) do
    ~H"""
    <div
      role="tablist"
      aria-label={gettext("Inspector")}
      class="flex items-center gap-1 rounded-lg bg-base-200/60 p-1 text-sm"
    >
      <button
        :for={
          {id, label, icon, alert} <- [
            {:preview, gettext("Preview"), "hero-eye", false},
            {:settings, gettext("Settings"), "hero-adjustments-horizontal", @settings_alert},
            {:history, gettext("History"), "hero-clock", false}
          ]
        }
        type="button"
        role="tab"
        aria-selected={to_string(@tab == id)}
        phx-click="switch_inspector_tab"
        phx-value-tab={id}
        class={[
          "flex flex-1 items-center justify-center gap-1.5 rounded-md px-3 py-1.5 font-medium transition",
          (@tab == id && "bg-base-100 text-base-content shadow-sm") ||
            "text-base-content/60 hover:text-base-content"
        ]}
      >
        <.icon name={icon} class="size-4" />
        <span>{label}</span>
        <span
          :if={alert}
          class="size-1.5 rounded-full bg-error"
          title={gettext("This panel has validation errors")}
        ></span>
      </button>
    </div>
    """
  end

  # A titled card inside an inspector panel (Theme A). Replaces the old buried
  # `<details>` accordions with an always-expanded, clearly-labelled section —
  # the panel's tab already gates visibility, so no per-section collapsing.
  attr :title, :string, required: true
  attr :id, :string, default: nil
  # Optional trailing content on the heading row — a status pill or counter that
  # belongs with the title rather than in the body.
  slot :aside
  slot :inner_block, required: true

  defp inspector_section(assigns) do
    ~H"""
    <section id={@id} class="rounded-lg border border-base-content/10 p-4">
      <div class="mb-3 flex items-center justify-between gap-2">
        <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
          {@title}
        </h3>
        <span :if={@aside != []}>{render_slot(@aside)}</span>
      </div>
      <div class="space-y-3">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  # Pill color for a content state in the action bar. Uses the `*-ink` tokens
  # for the same reason CoreComponents.badge/1 does: the bare accent on its own
  # pale tint only reaches ~2-4:1 in light mode.
  defp state_badge_class(:published), do: "bg-success/15 text-success-ink"
  defp state_badge_class(:in_review), do: "bg-warning/15 text-warning-ink"
  # /70 rather than /60 to match badge/1's neutral tone — /60 lands at 3.8:1.
  defp state_badge_class(:archived), do: "bg-base-content/10 text-base-content/70"
  defp state_badge_class(_), do: "bg-info/15 text-info-ink"

  attr :editors, :list, required: true
  attr :current_id, :string, required: true

  # Live "who's editing" roster — overlapping colored avatar chips (one per
  # collaborator, in the same color as their cursor/lock badges) plus a count.
  # Hidden when you're the only one here. Self is sorted first and tagged
  # "(you)".
  defp presence_roster(assigns) do
    others = Enum.reject(assigns.editors, &(&1.id == assigns.current_id))
    roster = Enum.sort_by(assigns.editors, &{&1.id != assigns.current_id, &1.name})

    assigns =
      assign(assigns, others: others, roster: roster, count: length(assigns.editors))

    ~H"""
    <div :if={@others != []} class="mt-2 flex items-center gap-2">
      <div class="flex">
        <span
          :for={e <- @roster}
          title={e.name <> if(e.id == @current_id, do: gettext(" (you)"), else: "")}
          class={[
            "-ml-1.5 flex size-6 items-center justify-center rounded-full text-[10px] font-semibold text-white ring-2 ring-base-100 first:ml-0",
            color_for(e.id)
          ]}
        >
          {initials(e.name)}
        </span>
      </div>
      <span class="text-xs text-base-content/60">{gettext("%{count} editing", count: @count)}</span>
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
        title={gettext("%{name} is editing this field", name: c.name)}
        class={[
          "flex items-center gap-0.5 rounded px-1.5 py-0.5 text-[10px] font-medium text-white shadow",
          c.color
        ]}
      >
        <.icon name="hero-lock-closed-mini" class="size-3" />{c.name}
      </span>
    </div>
    """
  end

  # The live preview article (title + rendered blocks). The previewed title is an
  # h2 so the editor keeps a single logical h1 (#174). Each block is a `{id, html}`
  # pair: it renders inside a `.kiln-block` (so it picks up the delivered typography)
  # wrapped in a hover target that reveals an "Edit" jump into the in-context editor
  # focused on that block (Theme C — the preview is a launch point for visual
  # editing). `@html` blocks with a nil id (legacy) render without the jump.
  attr :form, :any, required: true
  attr :html, :any, required: true
  attr :kind, :atom, required: true
  attr :slug, :string, required: true

  defp preview_article(assigns) do
    ~H"""
    <article class="prose max-w-none space-y-3 rounded border border-base-content/15 p-5">
      <h2 class="text-2xl font-bold">{@form[:title].value}</h2>
      <div
        :for={{id, html} <- @html}
        class="group relative -mx-2 rounded px-2 transition hover:bg-base-200/40"
      >
        <div class="kiln-block">{html}</div>
        <.link
          :if={id}
          navigate={~p"/editor/site/#{@kind}/#{@slug}?#{[focus: id]}"}
          class="absolute right-1 top-1 z-10 hidden items-center gap-1 rounded bg-base-100/95 px-1.5 py-0.5 text-xs font-medium text-base-content no-underline shadow ring-1 ring-base-content/10 group-hover:inline-flex"
          title={gettext("Edit this block on the page")}
        >
          <.icon name="hero-pencil-square" class="size-3" />{gettext("Edit")}
        </.link>
      </div>
    </article>
    """
  end

  attr :state, :atom, required: true

  # Draft autosave indicator shown next to the workflow/Save buttons. Covers the
  # in-flight (:saving) and validation-failure (:error) states too (#136).
  defp autosave_status(assigns) do
    ~H"""
    <span
      class={["text-xs", (@state == :error && "text-error") || "text-base-content/70"]}
      aria-live="polite"
    >
      <%= case @state do %>
        <% :saving -> %>
          {gettext("Saving…")}
        <% :saved -> %>
          {gettext("Saved")}
        <% :synced -> %>
          <%!-- Collab: a co-editor persists; text edits are already in the
                shared doc. Fields outside the text still need Save. --%>
          {gettext("Synced live — co-editor saves")}
        <% :error -> %>
          {gettext("Couldn't autosave — check for errors")}
        <% _ -> %>
          {gettext("Unsaved changes")}
      <% end %>
    </span>
    """
  end

  attr :state, :atom, required: true
  attr :tier, :atom, required: true

  defp workflow_buttons(assigns) do
    ~H"""
    <button
      :if={@state == :draft and @tier == :editor}
      type="button"
      phx-click="workflow"
      phx-value-action="submit"
      phx-disable-with={gettext("Submitting…")}
      class="btn btn-sm btn-default"
    >
      {gettext("Submit for review")}
    </button>
    <button
      :if={@state in [:draft, :in_review] and @tier == :admin}
      type="button"
      phx-click="workflow"
      phx-value-action="publish"
      phx-disable-with={gettext("Publishing…")}
      class="btn btn-sm btn-default"
    >
      {if @state == :in_review, do: gettext("Approve & publish"), else: gettext("Publish")}
    </button>
    <button
      :if={@state == :in_review and @tier == :admin}
      type="button"
      phx-click="workflow"
      phx-value-action="return"
      phx-disable-with={gettext("Working…")}
      class="btn btn-sm btn-default"
    >
      {gettext("Request changes")}
    </button>
    <span
      :if={@state == :in_review and @tier == :editor}
      class="text-xs text-base-content/70"
    >
      {gettext("Awaiting admin approval")}
    </span>
    <button
      :if={@state == :published}
      type="button"
      phx-click="workflow"
      phx-value-action="unpublish"
      phx-disable-with={gettext("Working…")}
      class="btn btn-sm btn-default"
    >
      {gettext("Unpublish")}
    </button>
    <button
      :if={@state == :archived}
      type="button"
      phx-click="workflow"
      phx-value-action="unarchive"
      phx-disable-with={gettext("Working…")}
      class="btn btn-sm btn-default"
    >
      {gettext("Unarchive")}
    </button>
    """
  end
end
