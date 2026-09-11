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

  on_mount KilnCMSWeb.ContentEditor.Session
  on_mount KilnCMSWeb.ContentEditor.BlockOps

  require Ash.Query
  require Logger

  import Ash.Expr, only: [expr: 1]

  import KilnCMSWeb.BlockDiscussionComponents,
    only: [block_discussion: 1, discussion_state: 3]

  import KilnCMSWeb.SeoComponents, only: [seo_findings: 1]
  import KilnCMSWeb.VersionDiffComponents, only: [version_compare: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Mentions
  alias KilnCMS.CMS.VersionDiff
  alias KilnCMS.CMS.VersionSnapshot
  alias KilnCMS.CMS.WorkingCopy
  alias KilnCMS.Collab
  alias KilnCMS.Notifications
  alias KilnCMS.Search.Related
  alias KilnCMS.Slug
  alias KilnCMS.Unsplash
  alias KilnCMSWeb.EditorTelemetry
  alias KilnCMSWeb.Presence
  alias KilnCMSWeb.VersionDiffComponents

  import KilnCMSWeb.ContentEditor.BlockParams
  import KilnCMSWeb.ContentEditor.Shared
  import KilnCMSWeb.ContentEditor.Preview

  import KilnCMSWeb.ContentEditor.AdvisoryPanelComponents, only: [assist_panel: 1]

  import KilnCMSWeb.ContentEditor.BlockCanvasComponents
  import KilnCMSWeb.ContentEditor.ChromeComponents, only: [editor_action_bar: 1]
  import KilnCMSWeb.ContentEditor.BlockOps, only: [revalidate: 2, update_gallery_images: 3]
  import KilnCMSWeb.ContentEditor.InspectorComponents

  import KilnCMSWeb.ContentEditor.MediaPickerComponents,
    only: [image_picker: 1, file_picker: 1, av_picker: 1]

  import KilnCMSWeb.ContentEditor.Session

  # Preferred display order for the block palette; any block type registered
  # beyond these is appended automatically (the palette is registry-driven, so
  # adding a `Kiln.Block` module needs no editor change).
  @type_order ~w(rich_text heading quote image gallery file embed divider columns accordion faq how_to claim custom)

  # Stands in for the working draft on the version-compare picker (#467). A
  # version id is a UUID, so this can never collide with one.
  @current_pick "current"

  # Bound the media picker window loaded on mount (newest first) so a large
  # library can't grow each open editor's heap without limit.
  @max_media 500

  # Bound the tag picker the same way (#1149). The filter is a server round-trip
  # (the client-side TagFilter only stops form propagation and pushes the
  # query), so a vocabulary larger than this is still reachable by name — and
  # every tag already on the record is unioned in regardless of the window.
  # Runtime (not compile_env) so a test can lower the window without a recompile.
  defp max_tags,
    do: :kiln_cms |> Application.get_env(:editor, []) |> Keyword.get(:max_tags, 500)

  # Coalescing delay for `{:preview_comments_changed, _}` (#1252 review): one
  # trigger event can fan out several `deliver_as: "comment"` automation
  # rules onto the same document in one Oban batch (see
  # `RouteToBlockThread`'s moduledoc), each broadcasting separately — without
  # this, an editor with the document open got one full comment-list reload
  # per broadcast instead of one for what's effectively a single visible
  # update. Short relative to `@autosave_debounce_ms`: this coalesces a burst
  # arriving over milliseconds, not idle-typing.
  @comments_reload_debounce_ms 300

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
        content_type = ContentTypes.get!(kind, org)

        if connected?(socket) do
          topic = Presence.track_editor(self(), kind, id, actor)
          Phoenix.PubSub.subscribe(KilnCMS.PubSub, topic)
          # Preview-window joins/leaves, so broadcast_preview/1 can no-op
          # while no pop-out is watching.
          Phoenix.PubSub.subscribe(KilnCMS.PubSub, Presence.preview_topic(kind, id))
          # Block discussions: threads and block tasks changing anywhere —
          # another editor's window, the API, `AutoCompleteTasks` on publish,
          # or an editorial-intelligence rule delivering a document-level
          # comment in the background (#946) — arrive as
          # `{:block_thread_changed, _}` / `{:block_task_changed, _}` on the
          # collab topic, which also carries this document's typing
          # indicators. `BroadcastComment` fires that topic unconditionally
          # (block-scoped or the `nil` block_id a document-level comment
          # carries), and the handler below reloads the whole comment list
          # regardless of which block_id it names — so the Document notes
          # panel (which reads `@comments` too) picks up an automation
          # comment through this one subscription, no second one needed.
          Collab.subscribe(kind, record.id)
        end

        {:ok,
         socket
         |> assign(:kind, kind)
         |> assign(:content_type, content_type)
         |> assign(:slug_targets, slug_targets(content_type))
         # The type's own field-type tokens (#804), off the definitions this
         # mount already loaded — so the live preview derives through exactly
         # the vocabulary `Changes.DeriveSlug` uses, at no extra query.
         |> assign(
           :slug_token_definitions,
           KilnCMS.CMS.Slugs.type_token_definitions(field_definitions)
         )
         |> assign(:has_excerpt, content_type.excerpt?)
         |> assign(:actor, actor)
         |> assign(:tier, KilnCMSWeb.LiveUserAuth.effective_tier(socket))
         |> assign(:block_types, block_types())
         |> assign(:nested_child_types, nested_child_types())
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
         # A live document's settings edited since the last Save
         # (docs/working-copy.md) — its text autosaves, its settings do not.
         |> assign(:settings_dirty?, false)
         # Debounced comments reload (#1252 review) — see @comments_reload_debounce_ms.
         |> assign(:comments_reload_timer, nil)
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
         # `?comment=<block_id>` opens that block's thread on arrival — the
         # landing side of the shared preview's comment pins (#802).
         |> assign(:comment_block, params["comment"])
         |> assign(:comment_draft, nil)
         # Mention autocomplete: the candidates for the `@…` currently being
         # typed in the open composer. Filtered in memory from `mention_roster`
         # (loaded once — an org's roster doesn't change mid-session), so a
         # keystroke costs no query. `Notifications.mention_roster/1` is the
         # list `NotifyComment` resolves against after the write, so what the
         # dropdown offers is exactly who a mention reaches.
         |> assign(:mention_roster, Notifications.mention_roster(org))
         |> assign(:mention_suggestions, [])
         # Who is typing into which block's composer, as `block_id => %{name =>
         # timer_ref}`. Transient and never persisted; each entry cancels
         # itself after `@typing_ttl` so a peer who closes the tab mid-word
         # doesn't type forever.
         |> assign(:typing, %{})
         # The task form inside a block's discussion (nil = closed). Separate
         # from `task_draft`, which belongs to the settings panel's
         # document-level assignment — two forms, two drafts, so opening one
         # never half-fills the other.
         |> assign(:block_task_draft, nil)
         # `?threads=unresolved` opens straight onto the blocks needing
         # attention — the landing side of a "here's what's left" link, the
         # same way `?comment=` lands on one block's thread.
         |> assign(:thread_filter, thread_filter_param(params["threads"]))
         # Internal-link suggestions (#377). `nil` = never opened; loading is
         # deferred to first open because it costs a pgvector query plus a
         # record read per neighbour, which no page-load should pay.
         |> assign(:seo_links, nil)
         |> assign(:seo_links_loading?, false)
         # Content intelligence (#339): near-duplicates + tag suggestions, both
         # from the block embeddings this document already has. Same deferral
         # and the same reason as the link suggestions above, doubled — this
         # runs the vector query *and* embeds every unapplied tag name.
         # `nil` = never run; `[]` = ran and found nothing.
         |> assign(:intel_duplicates, nil)
         |> assign(:intel_tags, nil)
         |> assign(:intel_loading?, false)
         # Media picker (image blocks) + relationship pickers (taxonomy, siblings).
         # `picking` is nil (closed), a block index (fill that image block), or
         # `:new` (insert a new image block — opened from the editor chrome).
         |> assign(:picking, nil)
         |> assign(:picked, [])
         |> assign(:media_query, "")
         # nil = not searching (browse the mounted window); a list = DB search
         # results, so the picker also finds items beyond that window.
         |> assign(:picker_media, nil)
         # Unsplash search tab inside the image picker (mirrors `MediaLive`'s
         # own Unsplash tab — see `KilnCMS.Unsplash`). `picker_tab` switches
         # the drawer between the library grid and this search panel;
         # `reset_picker/1` puts it back to `:library` whenever the drawer
         # closes, so reopening it never lands on a stale search.
         |> assign(:unsplash_enabled?, Unsplash.enabled?())
         |> assign(:picker_tab, :library)
         |> assign(:unsplash_query, "")
         |> assign(:unsplash_photos, [])
         |> assign(:unsplash_page, 1)
         |> assign(:unsplash_more?, false)
         |> assign(:unsplash_searching?, false)
         |> assign(:unsplash_importing, MapSet.new())
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
         # Three columns, not every column (#528). Cap at `@max_tags` (#1149) —
         # since #638 an unrendered tag is no longer detached by omission, so a
         # bounded window is safe. The filter box queries the full vocabulary;
         # `all_pickable_tags/2` still unions every attached tag so detach stays
         # reachable. See `load_org_tags/3` and `handle_event("filter_tags", …)`.
         |> assign(:tag_query, "")
         |> assign(:tags, load_org_tags(actor, org, ""))
         |> assign(:max_tags, max_tags())
         # `TagGroup`'s primary read is already ordered by position then name.
         #
         # #528 also proposed skipping this read when no tag carries a group —
         # the zero-group case, which is most installs. It is NOT safe, and the
         # suite says so: with no groups loaded, `bucket_for/3` files a tag
         # whose group does not resolve under "Ungrouped", so a tag a
         # collaborator attaches after mount from an out-of-scope group lands
         # there instead of in "Also attached", losing the note explaining where
         # the tag came from. Since #638 a mis-filed tag is no longer *detached*
         # by the next save — the merge verbs only remove what was rendered and
         # unticked — so this is now a labelling question rather than a
         # data-loss one. Still worth one small indexed read: "Ungrouped" tells
         # an editor nothing about why a tag they cannot find in any group is on
         # their post.
         |> assign(:tag_groups, CMS.list_tag_groups!(actor: actor, tenant: org))
         # Which tag-picker sections render expanded, and which have rendered at
         # all (#523). Both start empty and are filled by `assign_record/2`
         # below — see `refresh_tag_index/1`.
         |> assign(:tag_sections_open, MapSet.new())
         |> assign(:tag_sections_seen, MapSet.new())
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
         |> assign(:assignable_users, assignable_users(org))
         |> assign(:task_assign_open?, assign_deep_link?)
         |> assign(:task_draft, %{})
         # What the site does with an open task on publish (#818) — the assign
         # form's blank option names it, so the author sees what "site default"
         # means rather than having to go and look.
         |> assign(:auto_complete_default, KilnCMS.CMS.TaskSettings.site_default(org))
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
    case ContentTypes.get(type, socket.assigns.current_org) do
      nil -> nil
      ct -> ct.type
    end
  end

  defp content_kind(_params, socket), do: socket.assigns.live_action

  # A block's thread changed — here, in another editor's window, through the
  # API, or an editorial-intelligence rule delivering a document-level
  # comment in the background (#946). The message names the block but
  # carries no rows: each session re-reads with its OWN actor and tenant, so
  # a peer who may no longer read this content simply keeps what it has.
  # Reloading the whole document's list rather than the one block is
  # deliberate — it's one query either way, and the alternative is merging a
  # partial result into an assign that another message may already have moved.
  #
  # Debounced (#1252 review): a single trigger event can fan out several
  # editorial-intelligence reactions into the same Oban batch, each landing a
  # `deliver_as: "comment"` finding — several broadcasts back-to-back for one
  # visible update — so this cancels any pending reload and schedules a fresh
  # one instead of reloading on every single message.
  @impl true
  def handle_info({:block_thread_changed, _block_id}, socket) do
    if ref = socket.assigns.comments_reload_timer, do: Process.cancel_timer(ref)

    timer = Process.send_after(self(), :reload_comments, @comments_reload_debounce_ms)
    {:noreply, assign(socket, :comments_reload_timer, timer)}
  end

  # The debounced reload `{:block_thread_changed, _}` above schedules.
  def handle_info(:reload_comments, socket) do
    {:noreply, socket |> assign(:comments_reload_timer, nil) |> reload_comments()}
  end

  def handle_info({:block_task_changed, _block_id}, socket),
    do: {:noreply, reload_tasks(socket)}

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

  # Content intelligence (#339). Stamped with the editor version like the other
  # async results: a run started before a conflict reload describes content the
  # author no longer has, and its tag suggestions would be applied to a form
  # that was replaced underneath them.
  def handle_async(:content_intel, {:ok, {version, %{} = intel}}, socket) do
    if version == socket.assigns.editor_version do
      {duplicates, duplicates_reason} = intel_outcome(intel.duplicates)
      {tags, tags_reason} = intel_outcome(intel.tags)

      socket =
        socket
        |> assign(:intel_loading?, false)
        |> assign(:intel_duplicates, duplicates)
        |> assign(:intel_tags, tags)

      # Same reasoning as the `{:exit, reason}` clause below: `[]` alone reads
      # as the panel's ordinary "nothing similar found" empty state, which is a
      # *result* — and a `KilnCMS.LLM.Budget`-blocked call (#1076) is the
      # absence of one. Without the flash the two are indistinguishable, and an
      # author would reasonably publish the duplicate the click never checked.
      # Either reason is shown — whichever call was blocked, the message names
      # why, the same as `seo_error_message/1` does for the SEO panel.
      case duplicates_reason || tags_reason do
        nil -> {:noreply, socket}
        reason -> {:noreply, put_flash(socket, :error, intel_error_message(reason))}
      end
    else
      {:noreply, assign(socket, :intel_loading?, false)}
    end
  end

  def handle_async(:content_intel, {:exit, reason}, socket) do
    Logger.warning("Content intelligence task exited: #{inspect(reason)}")

    # `[]`, not nil, so the button stops offering a first run it already made.
    # But `[]` alone renders the panel's ordinary empty state — "Nothing similar
    # found." — which is a *result*, and this is the absence of one. The flash
    # is what carries that difference; without it a crashed analysis is
    # indistinguishable from a clean bill of health, and an author would
    # reasonably publish the duplicate we failed to look for.
    #
    # Only a *task-level* failure lands here (a lost DB connection, say). An
    # embedder that raises does not: `KilnCMS.Cache.fetch/3` wraps it in
    # `Cachex.fetch`, which catches fallback exceptions, so a broken model
    # degrades to an empty suggestion list through the `{:ok, _}` clause above
    # and still reads as "nothing found". Widening that is #851's neighbourhood,
    # not this clause's.
    {:noreply,
     socket
     |> assign(:intel_loading?, false)
     |> assign(:intel_duplicates, [])
     |> assign(:intel_tags, [])
     |> put_flash(:error, gettext("Couldn't analyze this content. Please try again."))}
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

  def handle_async(:unsplash_search, result, socket) do
    socket = assign(socket, :unsplash_searching?, false)

    case result do
      # A result for a query the author has since replaced — drop it.
      {:ok, {query, _page, _result}} when query != socket.assigns.unsplash_query ->
        {:noreply, socket}

      {:ok, {_query, page, {:ok, %{photos: photos, more?: more?}}}} ->
        photos = if page == 1, do: photos, else: socket.assigns.unsplash_photos ++ photos

        {:noreply,
         socket
         |> assign(:unsplash_photos, photos)
         |> assign(:unsplash_page, page)
         |> assign(:unsplash_more?, more?)}

      _error ->
        {:noreply,
         put_flash(socket, :error, gettext("Unsplash search failed — please try again."))}
    end
  end

  def handle_async({:unsplash_import, id}, result, socket) do
    socket =
      assign(socket, :unsplash_importing, MapSet.delete(socket.assigns.unsplash_importing, id))

    case result do
      {:ok, {:ok, item}} ->
        socket
        |> assign(:media, [media_row(item) | socket.assigns.media])
        |> route_picked_item(item)
        |> then(&{:noreply, &1})

      _error ->
        {:noreply,
         put_flash(socket, :error, gettext("Couldn't import that photo from Unsplash."))}
    end
  end

  # `@record` is the row — state, lock version, the published text. The form,
  # the block children and the rich-text bodies are built from the WORKING
  # VIEW of it (docs/working-copy.md): a live document with pending changes
  # edits its working copy, and everything the form is seeded from must agree
  # on that or the first autosave would write the published text back over
  # the draft.
  defp assign_record(socket, record) do
    socket = assign(socket, :record, record)
    view = WorkingCopy.view(record)

    socket
    |> assign(:page_title, view.title)
    |> assign(:slug_customized?, slug_customized?(socket))
    |> assign(:may_write?, may_write?(record, socket.assigns.actor, socket.assigns.current_org))
    # Recomputed alongside `may_write?` and for the same reason: a reload that
    # lands a change (a publish, a re-scoped grant) must re-evaluate both.
    |> assign(
      :may_suggest_seo?,
      may_write_fields?(
        record,
        socket.assigns.actor,
        socket.assigns.current_org,
        seo_suggestion_fields()
      )
    )
    |> assign(
      :may_assist_blocks?,
      may_write_fields?(record, socket.assigns.actor, socket.assigns.current_org, ["blocks"])
    )
    |> assign(:form, build_form(view, socket.assigns.actor))
    |> refresh_tag_index()
    |> seed_block_children(view)
    |> refresh_preview()
    |> load_versions()
    |> load_translations()
    |> load_fragment_options()
    |> load_redirects()
  end

  # Whether the actor may WRITE this record — the authorization both AI-assist
  # affordances need and a read-only viewer lacks (#550). The route's editor-tier
  # gate and the mount read-check are coarser: they admit a reviewer or a
  # read-only-on-one-type role who can OPEN someone else's draft, and both
  # `seo_suggest` and `assist_run` bill an org LLM run, so read access must not
  # be enough to spend that budget. Keyed on `:autosave` — the action the editor
  # actually persists through, and the same gate the collab channel admits
  # editors with (`KilnCMSWeb.CollabChannel`). Recomputed here (not once at
  # mount) so a reload that lands a state change — e.g. a publish — re-evaluates.
  defp may_write?(record, actor, org), do: Ash.can?({record, :autosave}, actor, tenant: org)

  @doc false
  # Whether the actor may change ALL of `fields` on this record's type (#868).
  #
  # `may_write?/3` cannot answer this. It is `Ash.can?`, and `Ash.can?` builds
  # the changeset with **empty input** — while `Changes.EnforceFieldGrants`
  # only raises a violation for an attribute that was `supplied?`. So no field
  # is ever supplied during the check, no error is ever added, and every
  # field-granted editor passes a gate the save will then refuse field by
  # field. A *change* is structurally invisible to `Ash.can?`; asking the same
  # question the change asks is the only way to get the same answer.
  #
  # Mirrors the change exactly, including the tier condition: grants bind an
  # effective **editor**, and effective admins are exempt (the policy bypass).
  # Getting that wrong in the other direction would hide the control from an
  # admin who happens to carry a `field_grants` entry.
  defp may_write_fields?(record, actor, org, fields) do
    Enum.any?(fields, &field_granted?(record, actor, org, &1))
  end

  # One field. `may_write_fields?/4` is `any?` over these rather than `all?`
  # because each suggestion is accepted on its own (`seo_accept` writes exactly
  # one attribute) — an editor granted `seo_title` alone can take that card and
  # save cleanly, so hiding the whole panel from them would be a second bug in
  # the opposite direction. The per-card accept re-checks with this.
  defp field_granted?(record, actor, org, field) do
    if Scoping.effective_tier(actor, org) == :editor do
      case Scoping.field_grant(actor, org, ContentTypes.type_name_for(record)) do
        nil -> true
        allowed -> field in allowed
      end
    else
      true
    end
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
          slug_context(socket),
          slug_token_definitions(socket)
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

  # The type's extra token definitions (#804), resolved at mount and kept in
  # assigns: `Slugs.descriptor_token_definitions/4` can read FieldDefinition
  # rows, and this is consulted on every keystroke that touches a slug source.
  defp slug_token_definitions(socket), do: socket.assigns[:slug_token_definitions] || []

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
  # `Slugs.derive_base/3` with the resource-level `DeriveSlug` change —
  # including the type's own field-type tokens (#804), without which the
  # preview and the save disagreed and every draft read as author-pinned.
  defp derive_unique_slug(socket, params) do
    base =
      KilnCMS.CMS.Slugs.derive_base(
        socket.assigns.content_type.slug_pattern,
        slug_context(socket, params),
        slug_token_definitions(socket)
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
      # String keys, matching `Slugs.changeset_custom_fields/2` and what a
      # `[field:<name>]` resolver looks up. Omitted entirely before #804, so a
      # field-token pattern never previewed the same slug it saved.
      custom_fields: slug_custom_fields(record, params),
      date: slug_date(record, params)
    }
  end

  defp slug_custom_fields(record, params) do
    case params && params["custom_fields"] do
      %{} = posted -> Map.new(posted, fn {key, value} -> {to_string(key), value} end)
      _absent -> stringify_custom_fields(Map.get(record, :custom_fields))
    end
  end

  defp stringify_custom_fields(%{} = fields),
    do: Map.new(fields, fn {key, value} -> {to_string(key), value} end)

  defp stringify_custom_fields(_other), do: %{}

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
  # Candidates for the fragment picker (#479): published documents of every
  # content type, most recent first, bounded.
  #
  # Published-only because a fragment pointing at a draft expands to nothing —
  # offering one would be a picker whose choices silently do not render. Loaded
  # once per editor mount rather than per keystroke: it feeds a `<select>`, and
  # the cap is what keeps that select usable as much as what keeps the query
  # cheap.
  @fragment_option_limit 200

  defp load_fragment_options(socket) do
    org = socket.assigns.current_org

    options =
      for ct <- ContentTypes.all() ++ ContentTypes.dynamic_all(org),
          record <-
            ContentTypes.list!(ct,
              actor: socket.assigns.actor,
              tenant: org,
              query: [
                filter: [state: :published],
                select: [:id, :title, :updated_at],
                sort: [updated_at: :desc],
                limit: @fragment_option_limit
              ]
            ) do
        {"#{record.title} (#{ct.label})", "#{ct.type}:#{record.id}"}
      end

    assign(socket, :fragment_options, options)
  end

  # The option list, with the block's own current reference guaranteed present.
  #
  # `@fragment_options` is published-only and capped, so a target that was
  # unpublished (or has simply aged out of the cap) would match no option — the
  # browser would fall back to the prompt, and the next `phx-change` would post
  # a blank, clearing a reference on a block nobody touched. The stored value is
  # prepended instead, labelled so the editor can see what happened.
  defp fragment_options_for(options, bf) do
    bf[:ref].value |> fragment_ref_value() |> ensure_option(options)
  end

  defp ensure_option("", options), do: options

  defp ensure_option(current, options) do
    if Enum.any?(options, fn {_label, value} -> value == current end),
      do: options,
      else: [{gettext("Current target (unpublished or not listed)"), current} | options]
  end

  # The stored `%{"type" =>, "id" =>}` as the picker's `"type:id"` option value.
  defp fragment_ref_value(%{"type" => type, "id" => id}) when is_binary(id), do: "#{type}:#{id}"
  defp fragment_ref_value(%{type: type, id: id}) when is_binary(id), do: "#{type}:#{id}"
  defp fragment_ref_value(_ref), do: ""

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

  # The redirects standing under this record's address: every retired path
  # that 301s to it (`Changes.RecordSlugRedirect`), newest first. Reloaded from
  # `assign_record/2` rather than once at mount because the set moves with the
  # record — a published slug or alias save leaves one behind, and so does a
  # restore (the change re-fires from a `before_action` write, #691) — and the
  # list has to be right the moment the save that created a row lands.
  #
  # Read as the actor: `Redirect`'s read policy is world-readable (delivery
  # serves the same map to anyone), so nothing is hidden and no bypass is
  # needed. Keyed on the type descriptor's name the way the recording change
  # keys it, so a dynamic entry finds its rows too.
  defp load_redirects(socket) do
    redirects =
      CMS.list_redirects!(
        actor: socket.assigns.actor,
        tenant: socket.assigns.current_org,
        query: [
          filter: [
            target_type: to_string(socket.assigns.content_type.type),
            target_id: socket.assigns.record.id
          ],
          sort: [inserted_at: :desc]
        ]
      )

    assign(socket, :redirects, redirects)
  end

  # The day a redirect was recorded — its `inserted_at`, not `updated_at`: the
  # `[:path, :locale]` upsert refreshes the latter whenever another record
  # vacates the same path, and "since" is what the editor is asking.
  defp redirect_since(%{inserted_at: %DateTime{} = at}), do: Calendar.strftime(at, "%Y-%m-%d")
  defp redirect_since(_redirect), do: "—"

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

  # --- generic dispatch to the per-kind code interfaces (via the registry) ---

  defp fetch!(kind, id, actor, org) do
    # Scope the load to the current site's org (epic #336) so an editor on one
    # site's subdomain can only open that site's content.
    ContentTypes.get_record!(kind, id,
      actor: actor,
      tenant: org,
      # `health`/`due_at` are expression calculations, so they cost a couple of
      # columns in the same SELECT rather than a second query
      # (docs/content-lifecycles.md).
      load: [:category, :featured_image, :tags, :health, :due_at, related_name(kind)]
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
    case ContentTypes.get!(kind, org) do
      %{source: :dynamic, definition: definition} ->
        CMS.field_definitions_for_definition!(definition.id, actor: actor, tenant: org)

      ct ->
        CMS.field_definitions_for!(ct.type, actor: actor, tenant: org)
    end
  end

  # Pick-lists for `:reference` custom fields: per definition, the target
  # type's records as `{title, id}` options — narrow select and the same window
  # cap as the media picker, so a large library can't blow up the mount.
  defp reference_options(definitions, actor, org) do
    definitions
    |> Enum.filter(&(&1.field_type == :reference))
    |> Map.new(fn definition ->
      options =
        case ContentTypes.get(definition.target_type, org) do
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

  defp do_workflow(kind, verb, record, actor),
    do: ContentTypes.transition(kind, verb, record, actor: actor, tenant: record.org_id)

  # Which half of a live document a form change touched (docs/working-copy.md):
  # the title or the body autosave into the working copy; every other field is
  # a setting that waits for Save and then goes live. An unknown target counts
  # as text — the side that autosaves — because a text edit misfiled as a
  # setting would be the one that could go unsaved.
  defp dirty_scope(["form", field | _rest]) when field in ["title", "blocks"], do: :text
  defp dirty_scope(["form", _field | _rest]), do: :settings
  defp dirty_scope(_target), do: :text

  defp save_draft(socket, params) do
    result =
      EditorTelemetry.span(:save, %{kind: socket.assigns.kind}, fn ->
        AshPhoenix.Form.submit(socket.assigns.form, params: params)
      end)

    case result do
      {:ok, record} ->
        {:noreply, saved(socket, record)}

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

  # Save on a LIVE document (docs/working-copy.md): the text goes to the working
  # copy, the settings go live. Two writes, in that order — a pending text edit
  # is flushed through the same path the debounce takes, then everything but
  # the title and body is submitted through `:update`.
  #
  # NOT through `@form`. That form's data is the working view — the title and
  # body the editor is typing — and `:update`'s pipeline reads the text it does
  # not receive in params off `changeset.data`: `SetSearchText` would index the
  # draft's words on the live row, and the fired artifacts would carry them.
  # A throwaway form on the row itself, without the block sub-forms (nothing
  # here writes blocks), keeps `:update` reading the published text.
  defp save_live(socket, params) do
    case flush_working_copy(socket, params) do
      {:ok, socket} ->
        form =
          AshPhoenix.Form.for_update(socket.assigns.record, :update,
            actor: socket.assigns.actor,
            tenant: socket.assigns.record.org_id
          )

        settings = Map.drop(params, ["title", "blocks"])

        result =
          EditorTelemetry.span(:save, %{kind: socket.assigns.kind}, fn ->
            AshPhoenix.Form.submit(form, params: settings)
          end)

        case result do
          {:ok, record} -> {:noreply, saved(socket, record)}
          {:error, form} -> {:noreply, settings_refused(socket, form, params)}
        end

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  # The errors belong on the form that is showing. Re-validating it with the
  # full params reproduces every settings error the throwaway just hit — those
  # fields are the same either way.
  defp settings_refused(socket, form, params) do
    if stale_conflict?(form) do
      flag_conflict(socket)
    else
      socket
      |> assign(:form, AshPhoenix.Form.validate(socket.assigns.form, params, errors: true))
      |> put_flash(:error, gettext("Please fix the errors below."))
    end
  end

  # Re-fetch so the relationship pickers reflect the saved links (the submit
  # result doesn't carry loaded relationships).
  defp saved(socket, record) do
    reloaded =
      fetch!(socket.assigns.kind, record.id, socket.assigns.actor, socket.assigns.current_org)

    socket
    |> assign_record(reloaded)
    |> broadcast_saved()
    |> assign(:save_state, :saved)
    |> assign(:settings_dirty?, false)
    |> put_flash(:info, gettext("Saved."))
  end

  # Write whatever text is waiting for the debounce into the working copy now,
  # so a Save or a "Publish changes" acts on what is on screen. Only when
  # something IS waiting: a flush with nothing pending would still cut a
  # version row per Save. `{:error, socket}` carries the conflict banner
  # `do_autosave/1` raised, or — for a copy that failed validation, where the
  # indicator alone would leave a click on Save looking like nothing happened
  # — a flash saying why the rest did not run.
  defp flush_working_copy(socket, params) do
    if socket.assigns.save_state in [:saving, :error] do
      socket = socket |> cancel_autosave_timer() |> autosave_working_copy(params)

      cond do
        socket.assigns.conflict ->
          {:error, socket}

        socket.assigns.save_state != :saved ->
          {:error,
           put_flash(
             socket,
             :error,
             gettext("Couldn't save the working copy — check the title and body for errors.")
           )}

        true ->
          {:ok, socket}
      end
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("validate", %{"form" => params} = event, socket) when is_map(params) do
    # The columns children live in socket state (they aren't bound form inputs);
    # re-inject them so a keystroke's partial params can't wipe the nested tree.
    # GEO item rows (faq/how_to, #357) ARE bound inputs, but arrive as indexed
    # maps — normalize them to the lists their {:array, :map} fields cast.
    params =
      params
      |> reconcile_blocks(socket.assigns.form)
      |> inject_children(socket.assigns.block_children)
      |> inject_rich_bodies(socket.assigns.rich_bodies)
      |> normalize_item_rows()
      |> merge_tag_params(socket)

    {params, socket} = sync_slug(params, event["_target"], socket)
    socket = assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, params))
    broadcast_preview(socket)
    {:noreply, mark_dirty(socket, dirty_scope(event["_target"]))}
  end

  # The TipTap hook pushes its document (debounced) instead of mirroring into a
  # form input: AshPhoenix only applies params for fields the rendered form
  # knows (_touched), so a hook-injected input is silently dropped. Convert to
  # Portable Text here and re-validate with the body injected — the same
  # server-held-state pattern as columns children (apply_children/2).
  def handle_event("rich_text_body", %{"doc" => doc} = event, socket) when is_map(doc) do
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
     |> mark_dirty(:settings)}
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
    #
    # `may_write?` is the authorization boundary (#550): read access is enough to
    # REACH this handler (a reviewer can open the record), but billing an org LLM
    # run needs write access. The hidden button is not the control — a
    # replayed/forged event reaches here regardless — so refuse server-side.
    # `may_suggest_seo?` as well as `may_write?` (#868): a field-granted editor
    # passes `may_write?`, because that is `Ash.can?` and the grant lives in a
    # *change*, which `Ash.can?` cannot see. Billing an LLM run for fields the
    # save will refuse one by one is the outcome that gate was missing.
    if socket.assigns.seo_drafting? or not socket.assigns.seo_enabled? or
         not socket.assigns.may_write? or not socket.assigns.may_suggest_seo? do
      {:noreply, socket}
    else
      document = seo_document(socket)
      # The rate-limit bucket keys interpolate this, so it must be the id —
      # `current_org` is the Organization struct (Ash takes it as a tenant, but
      # a struct in a bucket key would blow up on String.Chars).
      org_id = Accounts.org_id(socket.assigns.current_org)
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
  #
  # `may_write?` for the same reason the two intelligence handlers below carry
  # it (#550/#916): a pgvector query plus a record read per neighbour, on an
  # explicit click, re-triggerable indefinitely and with no budget bucket. It is
  # cheaper than the intelligence refresh — no embedding is generated — but it
  # is the same shape, and gating one of the two would have been arbitrary.
  def handle_event("seo_links_refresh", _params, socket) do
    if socket.assigns.seo_links_loading? or not socket.assigns.may_write?,
      do: {:noreply, socket},
      else: {:noreply, load_link_suggestions(socket)}
  end

  # ── Content intelligence (#339) ───────────────────────────────────────────

  # Near-duplicates + tag suggestions, on an explicit click. Same "never on
  # mount" rule as the link suggestions: this is a pgvector query, a record read
  # per neighbour, and one embedding per unapplied tag name.
  #
  # `may_write?` gates it for the reason `seo_suggest` above states (#550): read
  # access is enough to REACH this handler, but this one is unbounded work on a
  # cold cache — a `list_tags!` plus an embedding per unapplied tag — and it is
  # re-triggerable on every click, with no budget bucket in front of it. The
  # hidden control is not the boundary; a replayed event arrives regardless.
  def handle_event("content_intel_refresh", _params, socket) do
    if socket.assigns.intel_loading? or not socket.assigns.may_write?,
      do: {:noreply, socket},
      else: {:noreply, load_content_intel(socket)}
  end

  # Attach a suggested tag. Writes through the form rather than the record, so
  # it lands in the same save as everything else the author is editing and is
  # undoable by unticking the checkbox the picker already renders for it.
  def handle_event("intel_add_tag", %{"id" => id}, socket) when is_binary(id) do
    if socket.assigns.may_write?,
      do: {:noreply, add_suggested_tag(socket, id)},
      else: {:noreply, socket}
  end

  def handle_event("intel_add_tag", _params, socket), do: {:noreply, socket}

  # The `Clipboard` JS hook pushes this after a successful copy. Without a
  # clause here the push would crash the LiveView — the hook predates this
  # view, so it had no handler until now.
  def handle_event("copied", _params, socket),
    do: {:noreply, put_flash(socket, :info, gettext("Copied to clipboard."))}

  def handle_event("seo_dismiss", %{"field" => field}, socket) when is_binary(field),
    do:
      {:noreply, assign(socket, :seo_dismissed, MapSet.put(socket.assigns.seo_dismissed, field))}

  def handle_event("seo_dismiss_all", _params, socket),
    do: {:noreply, socket |> assign(:seo_drafts, nil) |> assign(:seo_dismissed, MapSet.new())}

  def handle_event("seo_accept", %{"field" => field}, socket) when is_binary(field) do
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

  def handle_event("assist_action", %{"action" => action}, socket) when is_binary(action) do
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
      org_id = Accounts.org_id(socket.assigns.current_org)
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
    body = params["comment_body"]

    {:noreply,
     socket
     |> assign(:comment_draft, body)
     |> suggest_mentions(body)}
  end

  # The composer's hook says the author is typing. Broadcast-only: nothing is
  # stored, and our own echo is dropped on receipt rather than here, so the
  # message shape stays the same for every recipient.
  def handle_event("comment_typing", %{"bid" => block_id}, socket)
      when is_binary(block_id) and block_id != "" do
    Phoenix.PubSub.broadcast(
      KilnCMS.PubSub,
      Collab.topic(socket.assigns.kind, socket.assigns.record.id),
      {:typing, socket.assigns.actor.id, Presence.display_name(socket.assigns.actor), block_id}
    )

    {:noreply, socket}
  end

  def handle_event("comment_typing", _params, socket), do: {:noreply, socket}

  # Insert the chosen handle in place of the partial `@…` the author was
  # typing. Done server-side against `comment_draft` — the assign the Send
  # button reads — so the textarea and the value that will actually be posted
  # cannot disagree.
  def handle_event("mention_pick", %{"handle" => handle}, socket) when is_binary(handle) do
    draft = complete_mention(socket.assigns.comment_draft, handle)

    {:noreply,
     socket
     |> assign(:comment_draft, draft)
     |> assign(:mention_suggestions, [])
     |> push_event("mention:inserted", %{value: draft})}
  end

  def handle_event("mention_pick", _params, socket), do: {:noreply, socket}

  # Narrow the block tree to blocks needing attention, and back.
  #
  # An assign, not a URL patch: this LiveView has no `handle_params/3` — every
  # param it cares about is read once at mount — and adding one so a display
  # filter could round-trip through the address bar would put every future
  # patch through a callback this module has never needed. `?threads=` is the
  # way *in* to a filtered view; the chip is the way to change it once there.
  def handle_event("toggle_thread_filter", _params, socket) do
    filter = if socket.assigns.thread_filter == :unresolved, do: nil, else: :unresolved
    {:noreply, assign(socket, :thread_filter, filter)}
  end

  # ── Turning a block's discussion into a task ────────────────────────────────

  # Seeded from the thread rather than blank: the assignee from the first
  # `@mention` the root comment resolves, the note from its body, a due date a
  # week out. The common case is then one click and a confirm, and every field
  # is still editable — a seed the author has to correct is cheaper than a form
  # they have to fill.
  def handle_event("block_task_open", %{"bid" => block_id}, socket)
      when is_binary(block_id) and block_id != "",
      do: {:noreply, assign(socket, :block_task_draft, seed_block_task(socket, block_id))}

  def handle_event("block_task_open", _params, socket), do: {:noreply, socket}

  def handle_event("block_task_close", _params, socket),
    do: {:noreply, assign(socket, :block_task_draft, nil)}

  def handle_event("block_task_draft", %{"task_assignee_id" => v}, socket) when is_binary(v),
    do: {:noreply, put_block_task_draft(socket, "assignee_id", v)}

  def handle_event("block_task_draft", %{"task_due_on" => v}, socket) when is_binary(v),
    do: {:noreply, put_block_task_draft(socket, "due_on", v)}

  def handle_event("block_task_draft", %{"task_note" => v}, socket) when is_binary(v),
    do: {:noreply, put_block_task_draft(socket, "note", v)}

  def handle_event("block_task_draft", %{"task_auto_complete" => v}, socket) when is_binary(v),
    do: {:noreply, put_block_task_draft(socket, "auto_complete", v)}

  def handle_event("block_task_draft", _params, socket), do: {:noreply, socket}

  def handle_event("block_task_submit", %{"bid" => block_id}, socket)
      when is_binary(block_id) and block_id != "" do
    draft = socket.assigns.block_task_draft || %{}

    attrs = %{
      content_type: to_string(socket.assigns.kind),
      content_id: socket.assigns.record.id,
      block_id: block_id,
      assignee_id: blank_to_nil(draft["assignee_id"]),
      due_on: blank_to_nil(draft["due_on"]),
      note: blank_to_nil(draft["note"]),
      auto_complete_on_publish: tri_state(draft["auto_complete"])
    }

    case CMS.assign_task(attrs, actor: socket.assigns.actor, tenant: socket.assigns.current_org) do
      {:ok, _task} ->
        {:noreply,
         socket
         |> reload_tasks()
         |> assign(:block_task_draft, nil)
         |> put_flash(:info, gettext("Task created on this block."))}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't assign that task."))}
    end
  end

  def handle_event("block_task_submit", _params, socket), do: {:noreply, socket}

  # Re-anchor a task that was filed against the whole document. Only tasks with
  # no block of their own are offered (see `linkable_tasks/2`), and the id is
  # checked against that same list rather than trusted: a pushed payload names
  # whatever it likes.
  def handle_event("block_task_link", %{"link_task_id" => id}, socket)
      when is_binary(id) and id != "" do
    block_id = socket.assigns.comment_block

    with true <- is_binary(block_id),
         task when not is_nil(task) <-
           Enum.find(socket.assigns.tasks, &(&1.id == id and is_nil(&1.block_id))) do
      case CMS.update_task(task, %{block_id: block_id},
             actor: socket.assigns.actor,
             tenant: socket.assigns.current_org
           ) do
        {:ok, _task} ->
          {:noreply,
           socket
           |> reload_tasks()
           |> put_flash(:info, gettext("Task moved to this block."))}

        {:error, _error} ->
          {:noreply, put_flash(socket, :error, gettext("Couldn't move that task."))}
      end
    else
      _no_such_open_task -> {:noreply, socket}
    end
  end

  def handle_event("block_task_link", _params, socket), do: {:noreply, socket}

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
          {:noreply,
           socket
           |> reload_comments()
           |> assign(:comment_draft, nil)
           |> assign(:mention_suggestions, [])}

        {:error, _error} ->
          {:noreply, put_flash(socket, :error, gettext("Couldn't add comment."))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("comment_add", _params, socket), do: {:noreply, socket}

  def handle_event("comment_resolve", %{"id" => id}, socket) when is_binary(id),
    do: resolve_comment_thread(socket, id, :resolve_comment)

  def handle_event("comment_unresolve", %{"id" => id}, socket) when is_binary(id),
    do: resolve_comment_thread(socket, id, :unresolve_comment)

  # ── Editorial tasks (#501) ───────────────────────────────────────────────
  def handle_event("task_assign_open", _params, socket),
    do: {:noreply, socket |> assign(:task_assign_open?, true) |> assign(:task_draft, %{})}

  def handle_event("task_assign_close", _params, socket),
    do: {:noreply, socket |> assign(:task_assign_open?, false) |> assign(:task_draft, %{})}

  def handle_event("task_draft_change", %{"task_assignee_id" => v}, socket) when is_binary(v),
    do: {:noreply, put_task_draft(socket, "assignee_id", v)}

  def handle_event("task_draft_change", %{"task_due_on" => v}, socket) when is_binary(v),
    do: {:noreply, put_task_draft(socket, "due_on", v)}

  def handle_event("task_draft_change", %{"task_note" => v}, socket) when is_binary(v),
    do: {:noreply, put_task_draft(socket, "note", v)}

  def handle_event("task_draft_change", %{"task_auto_complete" => v}, socket) when is_binary(v),
    do: {:noreply, put_task_draft(socket, "auto_complete", v)}

  def handle_event("task_draft_change", _params, socket), do: {:noreply, socket}

  def handle_event("task_assign_submit", _params, socket) do
    draft = socket.assigns.task_draft

    attrs = %{
      content_type: to_string(socket.assigns.kind),
      content_id: socket.assigns.record.id,
      assignee_id: draft["assignee_id"],
      due_on: blank_to_nil(draft["due_on"]),
      note: blank_to_nil(draft["note"]),
      # `nil` means "inherit the site default" (#818) — a real third value, not
      # an omission, so the blank option has to survive as nil rather than
      # being dropped from the map.
      auto_complete_on_publish: tri_state(draft["auto_complete"])
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
  def handle_event("release_draft_change", %{"release_target" => v}, socket) when is_binary(v),
    do: {:noreply, put_release_draft(socket, "release_id", v)}

  def handle_event("release_draft_change", %{"release_action" => v}, socket) when is_binary(v),
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

  def handle_event("task_complete", %{"id" => id}, socket) when is_binary(id) do
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
  def handle_event("toggle_pick", %{"id" => id, "url" => url}, socket)
      when is_binary(id) and is_binary(url) do
    picked = socket.assigns.picked

    picked =
      if Enum.any?(picked, &(&1.id == id)),
        do: Enum.reject(picked, &(&1.id == id)),
        else: picked ++ [%{id: id, url: url}]

    {:noreply, assign(socket, :picked, picked)}
  end

  def handle_event("add_picked_images", %{"bid" => bid}, socket) when is_binary(bid) do
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
  def handle_event("search_media", %{"q" => q}, socket) when is_binary(q) do
    results =
      if q == "",
        do: nil,
        else: search_media(q, socket.assigns.actor, socket.assigns.current_org)

    {:noreply, socket |> assign(:media_query, q) |> assign(:picker_media, results)}
  end

  # --- Unsplash (image picker tab) --------------------------------------------
  #
  # Mirrors `KilnCMSWeb.MediaLive`'s own Unsplash tab (search + import), except
  # importing here has to land the new item on whatever the picker was opened
  # for — see `route_picked_item/2` below — rather than just refreshing a
  # library grid.

  def handle_event("picker_tab", %{"tab" => tab}, socket) when tab in ~w(library unsplash) do
    {:noreply, assign(socket, :picker_tab, String.to_existing_atom(tab))}
  end

  def handle_event("unsplash_search", %{"q" => q}, socket) when is_binary(q) do
    if socket.assigns.unsplash_enabled? do
      case String.trim(q) do
        "" ->
          {:noreply,
           socket
           |> assign(:unsplash_query, "")
           |> assign(:unsplash_photos, [])
           |> assign(:unsplash_more?, false)
           |> assign(:unsplash_searching?, false)}

        query ->
          {:noreply,
           socket
           |> assign(:unsplash_query, query)
           |> assign(:unsplash_page, 1)
           |> assign(:unsplash_searching?, true)
           |> start_async(:unsplash_search, fn -> {query, 1, Unsplash.search(query, 1)} end)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("unsplash_load_more", _params, socket) do
    if socket.assigns.unsplash_enabled? do
      %{unsplash_query: query, unsplash_page: page} = socket.assigns
      next = page + 1

      {:noreply,
       socket
       |> assign(:unsplash_searching?, true)
       |> start_async(:unsplash_search, fn -> {query, next, Unsplash.search(query, next)} end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("unsplash_import", %{"id" => id}, socket) when is_binary(id) do
    if socket.assigns.unsplash_enabled? do
      photo = Enum.find(socket.assigns.unsplash_photos, &(&1.id == id))

      if is_nil(photo) or MapSet.member?(socket.assigns.unsplash_importing, id) do
        {:noreply, socket}
      else
        actor = socket.assigns.actor
        org = socket.assigns.current_org

        {:noreply,
         socket
         |> assign(:unsplash_importing, MapSet.put(socket.assigns.unsplash_importing, id))
         |> start_async({:unsplash_import, id}, fn ->
           Unsplash.import_photo(photo, actor: actor, tenant: org)
         end)}
      end
    else
      {:noreply, socket}
    end
  end

  # Server-side tag vocabulary filter (#1149). The box lives inside the content
  # form, so the TagFilter hook stops propagation and pushes this event rather
  # than letting `phx-change` mark the document dirty on every keystroke.
  def handle_event("filter_tags", %{"q" => q}, socket) when is_binary(q) do
    prev = socket.assigns.tag_query
    q = String.trim(q)

    socket =
      socket
      |> assign(:tag_query, q)
      |> assign(
        :tags,
        load_org_tags(socket.assigns.actor, socket.assigns.current_org, q)
      )
      |> refresh_tag_index()

    # Clearing a filter undoes the force-open the template applied while
    # narrowing — except for sections that now hold a live tick. Folding those
    # away would hide the box the editor just checked (#523, e2e).
    socket =
      if prev != "" and q == "" do
        selected = selected_tag_ids(socket.assigns.form, socket.assigns.record)

        keep =
          for section <- with_counts(socket.assigns.tag_index.sections, selected),
              section.selected_count > 0,
              into: MapSet.new(),
              do: section.key

        update(socket, :tag_sections_open, &MapSet.union(&1, keep))
      else
        socket
      end

    {:noreply, socket}
  end

  # Set the social card image from the library (#476). No `id` in the match —
  # `apply_pick(:seo_image, ...)` never reads it, so binding it here would be
  # an unguarded client value with nothing to guard it against (#764).
  def handle_event("pick_image", %{"index" => "seo_image", "url" => url}, socket)
      when is_binary(url),
      do: {:noreply, socket |> apply_pick(:seo_image, nil, url) |> reset_picker()}

  # Set the featured image from the library (#154).
  def handle_event("pick_image", %{"index" => "featured", "id" => media_id}, socket)
      when is_binary(media_id),
      do: {:noreply, socket |> apply_pick(:featured, media_id, nil) |> reset_picker()}

  # Insert a library image as a brand-new image block (browser opened from the
  # editor chrome): the URL becomes the block content and its id is stashed in
  # `data` so delivery can build srcset.
  def handle_event("pick_image", %{"index" => "new", "id" => media_id, "url" => url}, socket)
      when is_binary(media_id) and is_binary(url),
      do: {:noreply, socket |> apply_pick(:new, media_id, url) |> reset_picker()}

  # Fill the existing image block identified by `bid`. Its current position is
  # resolved from the live form now, not captured when the picker opened, so a
  # concurrent reorder/removal can't misdirect the image (audit T5.1).
  def handle_event("pick_image", %{"index" => "block", "bid" => bid} = p, socket)
      when is_binary(bid) do
    %{"id" => media_id, "url" => url} = p
    {:noreply, socket |> apply_pick({:block, bid}, media_id, url) |> reset_picker()}
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
  def handle_event("search_file_media", %{"q" => q}, socket) when is_binary(q) do
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
  def handle_event("pick_file", %{"id" => media_id}, socket) when is_binary(media_id) do
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
  def handle_event("search_av_media", %{"q" => q}, socket) when is_binary(q) do
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
  def handle_event("pick_av", %{"id" => media_id}, socket) when is_binary(media_id) do
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

  # Retire one of the redirects listed under the address field. Only a row the
  # panel rendered — one standing under THIS record — is reachable from here:
  # the id is matched against `@redirects`, never fetched, so a crafted event
  # cannot name a redirect at some other record. The destroy then runs as the
  # actor, and `Redirect`'s policy re-proves that they may write the target
  # (`Checks.WritesRedirectTarget`) — the same gate `@may_write?` shows the
  # button behind, asked again by the layer that owns it.
  def handle_event("delete_redirect", %{"id" => id}, socket) when is_binary(id) do
    actor = socket.assigns.actor
    org = socket.assigns.current_org

    with %{} = redirect <- Enum.find(socket.assigns.redirects, &(&1.id == id)),
         :ok <- CMS.destroy_redirect(redirect, actor: actor, tenant: org) do
      {:noreply, socket |> load_redirects() |> put_flash(:info, gettext("Redirect deleted."))}
    else
      # Already gone (deleted from `/editor/redirects`, or by the record moving
      # back onto that path) or refused — either way the list is stale, so
      # reload it alongside the message.
      _ ->
        {:noreply,
         socket
         |> load_redirects()
         |> put_flash(:error, gettext("Couldn't delete that redirect."))}
    end
  end

  def handle_event("save", %{"form" => params}, socket) when is_map(params) do
    socket = cancel_autosave_timer(socket)

    params =
      params
      |> reconcile_blocks(socket.assigns.form)
      |> inject_children(socket.assigns.block_children)
      |> inject_rich_bodies(socket.assigns.rich_bodies)
      |> normalize_item_rows()
      |> merge_tag_params(socket)

    if socket.assigns.record.state == :published,
      do: save_live(socket, params),
      else: save_draft(socket, params)
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
     |> assign(:settings_dirty?, false)
     |> put_flash(:info, gettext("Reloaded the latest version."))}
  end

  # Somebody published this document while a collab room was open (#1061). The
  # publish carried the room's converged prose into its own write, so nothing
  # typed up to that point is lost — but from here nothing persists: this
  # client stops autosaving on a non-draft (`mark_dirty/1`), and the server
  # checkpoint is refused by `:autosave`'s draft-only filter. So reload onto the
  # published record and say what happened, rather than leaving the editor
  # typing into a doc that is going nowhere.
  #
  # Idempotent: every rich-text block on the page hears the browser event, so
  # this arrives once per block.
  def handle_event("collab_published", _params, socket) do
    if socket.assigns.record.state == :published do
      {:noreply, socket}
    else
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
       |> assign(:save_state, :saved)
       |> put_flash(
         :info,
         gettext("This was published. Your collaborative edits were saved with it.")
       )}
    end
  end

  def handle_event("workflow", %{"action" => action}, socket) when is_binary(action) do
    {:noreply, run_workflow(socket, action)}
  end

  # A human attests the content is still correct (docs/content-lifecycles.md).
  # Its own event rather than a `workflow` action, because it is not one: `state`
  # does not move, and `run_workflow`'s flash ("Updated to published") would be
  # a lie about what just happened.
  def handle_event("mark_reviewed", _params, socket) do
    %{kind: kind, record: record, actor: actor} = socket.assigns

    if socket.assigns.may_write? do
      case ContentTypes.transition(kind, "mark_reviewed", record,
             actor: actor,
             tenant: record.org_id
           ) do
        {:ok, _updated} ->
          # Re-fetched rather than assigning the action's own result: `health`
          # and `due_at` are calculations, so the returned record carries them
          # as `%Ash.NotLoaded{}` — which is truthy, so the pill would render
          # from a value that is not there.
          {:noreply,
           socket
           |> assign_record(fetch!(kind, record.id, actor, record.org_id))
           |> put_flash(:info, gettext("Marked reviewed — the freshness clock is reset."))}

        _ ->
          {:noreply, put_flash(socket, :error, gettext("That action isn't allowed right now."))}
      end
    else
      {:noreply, socket}
    end
  end

  # One-click translation: duplicate this record's content into a new draft in
  # the target locale and jump to its editor.
  #
  # Gated on `may_write?` for the reason the Duplicate handler below is (#922):
  # this is the same shape — forking the record's payload into a new draft —
  # and it was the other affordance in this file offered to an actor who may
  # only read this record.
  def handle_event("create_translation", %{"locale" => locale}, socket) when is_binary(locale) do
    %{kind: kind, record: record, actor: actor} = socket.assigns

    if socket.assigns.may_write? do
      {translation, withheld} =
        KilnCMS.CMS.Translations.create_translation_with_notes!(kind, record, locale,
          actor: actor,
          tenant: record.org_id
        )

      {:noreply,
       socket
       |> put_flash(:info, translation_flash(locale, withheld))
       |> push_navigate(to: ~p"/editor/content/#{kind}/#{translation.id}")}
    else
      {:noreply, socket}
    end
  rescue
    # Distinguished from a generic failure because it is not one: the refusal is
    # a permission boundary the editor can act on (ask for the grant), and
    # "couldn't create that translation" would read as a broken feature (#1157).
    _error in KilnCMS.CMS.Translations.BlocksWithheldError ->
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("Your role cannot copy this content's blocks, so it cannot be translated.")
       )}

    _error ->
      {:noreply, put_flash(socket, :error, gettext("Couldn't create that translation."))}
  end

  # One-click duplicate (#471): clone this record's saved payload into a new
  # draft of the same locale and jump to it. Unsaved edits don't travel — the
  # copy is made from the row, so the autosave that just ran is the boundary.
  #
  # Refused server-side too (#922), for the reason `seo_suggest` states: the
  # hidden button is not the boundary, a replayed or forged event arrives here
  # regardless. It closes no hole today — `Checks.EditableContentType` gates
  # authoring and updating alike, so `may_write?` and "may create one of these"
  # are the same question and the create refuses this actor anyway. What shipped
  # was a button whose only possible outcome was an error flash.
  #
  # Be precise about what this gate can see, because the obvious claim for it is
  # wrong: `may_write?` is `Ash.can?`, which evaluates the POLICY chain only.
  # `:autosave` already carries a per-record condition — `change filter(state ==
  # :draft)` — and `Ash.can?` is blind to it. That blindness is load-bearing
  # here (a published record stays duplicable, which is right), but it also
  # means a future per-record rule written as a change or a validation would be
  # just as invisible; only one written as a policy check would reach this gate.
  # So the reason to refuse here is not "it catches whatever comes next" — it is
  # that a forged event now gets the same answer the UI gave.
  def handle_event("duplicate", _params, socket) do
    %{kind: kind, record: record, actor: actor} = socket.assigns

    if socket.assigns.may_write? do
      case KilnCMS.CMS.Duplication.duplicate(kind, record, actor: actor, tenant: record.org_id) do
        {:ok, copy, []} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Duplicated as a new draft."))
           |> push_navigate(to: ~p"/editor/content/#{kind}/#{copy.id}")}

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
           |> push_navigate(to: ~p"/editor/content/#{kind}/#{copy.id}")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Couldn't duplicate that content."))}
      end
    else
      {:noreply, socket}
    end
  end

  # ── Version compare (#467) ─────────────────────────────────────────────────

  def handle_event("toggle_compare", %{"version_id" => version_id}, socket)
      when is_binary(version_id) do
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

  def handle_event("restore", %{"version_id" => version_id}, socket) when is_binary(version_id) do
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
         |> broadcast_saved()
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

  # Apply a picked media item to whatever the picker was opened for. Shared by
  # the "pick_image" handlers above and `route_picked_item/2` below (an
  # Unsplash import landing on the same target), so there is exactly one place
  # that knows how a pick reaches the form/blocks.
  defp apply_pick(socket, :seo_image, _media_id, url), do: put_seo_image(socket, url)

  defp apply_pick(socket, :featured, media_id, _url) do
    params = AshPhoenix.Form.params(socket.assigns.form) |> Map.put("featured_image_id", media_id)

    socket
    |> assign(:form, AshPhoenix.Form.validate(socket.assigns.form, params))
    |> mark_dirty(:settings)
  end

  defp apply_pick(socket, :new, media_id, url) do
    form =
      AshPhoenix.Form.add_form(socket.assigns.form, socket.assigns.form.name <> "[blocks]",
        params: %{
          "_union_type" => "image",
          "id" => Ash.UUID.generate(),
          "url" => url,
          "media_id" => media_id
        }
      )

    socket = assign(socket, :form, form)
    broadcast_preview(socket)
    mark_dirty(socket)
  end

  defp apply_pick(socket, {:block, bid}, media_id, url) do
    case block_index_by_id(socket.assigns.form, bid) do
      # The target block is gone (removed by a co-editor) — drop the pick.
      nil ->
        socket

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

        socket = revalidate(socket, params)
        broadcast_preview(socket)
        mark_dirty(socket)
    end
  end

  # Land a freshly-imported Unsplash `MediaItem` exactly where clicking it in
  # the library grid would have: the gallery's multi-select just appends to
  # `@picked` (same as `toggle_pick`) and leaves the drawer open for more
  # picks, while every single-select target goes through `apply_pick/4` and
  # then closes the picker, matching `pick_image`'s own behavior.
  defp route_picked_item(socket, item) do
    case socket.assigns.picking do
      {:gallery, _bid} ->
        assign(socket, :picked, socket.assigns.picked ++ [%{id: item.id, url: item.url}])

      picking ->
        socket |> apply_pick(picking, item.id, item.url) |> reset_picker()
    end
  end

  # The row shape `@media` carries (see the mount-time `select:` in `mount/3`),
  # built from a just-created `MediaItem` so an imported photo shows up in the
  # browse grid too if the picker stays open (gallery multi-select).
  defp media_row(item) do
    %{id: item.id, url: item.url, alt: item.alt, caption: item.caption, filename: item.filename}
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
    # Same rule for the intelligence panel: its tag suggestions are computed
    # against the content being discarded, and "Add" writes into the form that
    # is about to be replaced.
    |> assign(:intel_duplicates, nil)
    |> assign(:intel_tags, nil)
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

  # ── Mentions in the composer (#801) ─────────────────────────────────────────

  # Suggestions for the `@…` the cursor is *in*, or none.
  #
  # Keyed on the trailing partial handle rather than every `@` in the body:
  # re-opening a dropdown over a mention the author finished three sentences
  # ago would fight the person typing. `Mentions.suggest/3` owns which handle
  # is offered, so what the dropdown inserts is always something
  # `Mentions.resolve/2` will resolve.
  defp suggest_mentions(socket, body) do
    case partial_handle(body) do
      nil ->
        assign(socket, :mention_suggestions, [])

      query ->
        suggestions =
          query
          |> Mentions.suggest(socket.assigns.mention_roster)
          |> Enum.map(&%{name: user_label(&1.user), handle: &1.handle, ambiguous?: &1.ambiguous?})

        assign(socket, :mention_suggestions, suggestions)
    end
  end

  # The handle being typed at the very end of the body, if any. Requires the
  # `@` to start a word (so an email address doesn't open a dropdown) and
  # allows it to be the last character, because that is when the author most
  # wants to be shown the roster.
  defp partial_handle(body) when is_binary(body) do
    case Regex.run(~r/(?<![\w@])@([\p{L}\p{N}._-]*)$/u, body, capture: :all_but_first) do
      [query] -> query
      nil -> nil
    end
  end

  defp partial_handle(_body), do: nil

  # Replace the trailing partial handle with the chosen one, and leave a space
  # so the author keeps typing prose rather than extending the mention.
  defp complete_mention(body, handle) when is_binary(body),
    do: String.replace(body, ~r/(?<![\w@])@[\p{L}\p{N}._-]*$/u, "@#{handle} ")

  defp complete_mention(_body, handle), do: "@#{handle} "

  # ── The unresolved-discussion filter ────────────────────────────────────────

  # `nil` rather than `:all` for "no filter": it is also the `data-thread-filter`
  # attribute's value, and a nil attribute is simply absent, which is what the
  # CSS rule keys on.
  defp thread_filter_param("unresolved"), do: :unresolved
  defp thread_filter_param(_none), do: nil

  # Blocks with an open discussion, counted off the comments already in memory
  # — one row per unresolved thread root, which is what the chip announces.
  defp unresolved_block_count(comments) do
    comments
    |> Enum.count(&(is_nil(&1.thread_id) and is_nil(&1.resolved_at)))
  end

  # ── The comment → task bridge ───────────────────────────────────────────────

  defp put_block_task_draft(socket, key, value) do
    assign(socket, :block_task_draft, Map.put(socket.assigns.block_task_draft || %{}, key, value))
  end

  # What the drawer's task form opens with. The note is the root comment's own
  # words — that is what the task is *about* — truncated to the column's limit
  # so a long thread doesn't fail the write on a length constraint the author
  # never saw.
  defp seed_block_task(socket, block_id) do
    root =
      socket.assigns.comments
      |> Enum.filter(&(&1.block_id == block_id))
      |> Enum.find(&is_nil(&1.thread_id))

    %{
      "assignee_id" => seeded_assignee(socket, root),
      "due_on" => Date.to_iso8601(Date.add(Date.utc_today(), 7)),
      "note" => seeded_note(root),
      "auto_complete" => ""
    }
  end

  # The first person the root comment unambiguously mentions. `resolve/2` is
  # the same call `NotifyComment` makes, against the same roster
  # (`Notifications.mention_roster/1`), so whoever was emailed about the
  # comment is whoever the task is offered to — and an ambiguous `@alice`
  # seeds nobody here for the same reason it notifies nobody there.
  #
  # Only editors can hold a task (`AssigneeIsEditor`), so a mention of a viewer
  # is dropped at the seed rather than offered and rejected on submit.
  defp seeded_assignee(_socket, nil), do: ""

  defp seeded_assignee(socket, %{body: body}) do
    assignable = MapSet.new(socket.assigns.assignable_users, fn {_label, id} -> id end)

    body
    |> Mentions.resolve(socket.assigns.mention_roster)
    |> Enum.map(& &1.id)
    |> Enum.find("", &MapSet.member?(assignable, &1))
  end

  defp seeded_note(nil), do: ""

  defp seeded_note(%{body: body}) when is_binary(body),
    do: String.slice(body, 0, KilnCMS.Limits.paragraph())

  defp seeded_note(_root), do: ""

  # The open tasks on this document that no block has claimed. Anchored ones
  # are deliberately absent: moving a task off the block it already names would
  # empty that block's pin, which is not what "link existing" sounds like.
  defp linkable_tasks(tasks) do
    tasks
    |> Enum.filter(&is_nil(&1.block_id))
    |> Enum.map(&{task_link_label(&1), &1.id})
  end

  defp task_link_label(%{note: note} = task) when is_binary(note) and note != "",
    do: "#{task_assignee_label(task)} — #{String.slice(note, 0, 40)}"

  defp task_link_label(task), do: task_assignee_label(task)

  defp task_assignee_label(%{assignee: %{name: name}}) when is_binary(name) and name != "",
    do: name

  defp task_assignee_label(%{assignee: %{email: email}}) when not is_nil(email),
    do: to_string(email)

  defp task_assignee_label(_task), do: gettext("Unassigned")

  # Blocks that no longer exist in the document but still carry a thread or a
  # task, oldest discussion first.
  #
  # Deleting a block cascades nothing — the anchor is soft (`Task`'s moduledoc
  # says why) — so without this the thread would simply stop being rendered:
  # still in the database, still counted by every org-wide read, invisible to
  # the one person who could act on it. Rendering them under the block tree is
  # what makes "kept" mean something.
  #
  # Read off the form rather than the saved record, so a block deleted in this
  # session shows up here before the save lands.
  defp orphan_block_ids(form, comments, tasks) do
    present =
      form
      |> AshPhoenix.Form.value(:blocks)
      |> List.wrap()
      |> Enum.map(&block_form_id/1)
      |> MapSet.new()

    (Enum.map(comments, & &1.block_id) ++ Enum.map(tasks, & &1.block_id))
    |> Enum.reject(&(is_nil(&1) or MapSet.member?(present, &1)))
    |> Enum.uniq()
  end

  # Batch-loads `:author` on the whole list in one query rather than once per
  # comment at render time (the component reads it back off the struct — no
  # per-row load in the template). `authorize?: false` on the load
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

  # Open tasks only, filtered in SQL rather than in memory — the same one query
  # feeds the settings panel's task list and every block's discussion pin, so
  # the per-block counts cost nothing beyond this read no matter how many
  # blocks the document has.
  #
  # `authorize?: false` on the `:assignee` load only, for the same reason as
  # `load_comments/4`'s author load: `User`'s read policy is self-only, and the
  # assignee's name is display data. The task list itself is policy-checked.
  defp load_tasks(kind, record_id, actor, org) do
    to_string(kind)
    |> CMS.list_open_tasks_for!(record_id, actor: actor, tenant: org)
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

  # This org's editors/admins — the roster a task can be assigned to (viewers
  # can't act on content, so they're excluded). By EFFECTIVE tier on the org
  # the task will be written under (#419), not global `User.role`: that is what
  # `AssigneeIsEditor` checks at the write, so the picker offers exactly the
  # people the submit accepts. `users_with_tier/2` is a system read —
  # `User`'s and `OrgMembership`'s read policies are self-only.
  defp assignable_users(org) do
    org
    |> Accounts.Scoping.users_with_tier([:editor, :admin])
    |> Enum.sort_by(&user_label/1)
    |> Enum.map(&{user_label(&1), &1.id})
  end

  defp close_comment_panel(socket) do
    socket
    |> assign(:comment_block, nil)
    |> assign(:comment_draft, nil)
    # Suggestions belong to the draft that is being discarded — leaving them
    # assigned would reopen the dropdown over the next block's empty composer.
    |> assign(:mention_suggestions, [])
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
        |> broadcast_saved()
        |> assign(:save_state, :saved)
        |> put_flash(:info, gettext("Updated to %{state}.", state: state_label(record.state)))
        |> maybe_prompt_reviewer_assignment(action)

      _ ->
        put_flash(socket, :error, gettext("That action isn't allowed right now."))
    end
  end

  # "Publish changes" (docs/working-copy.md): flush the text still waiting for
  # the debounce first, so what goes live is what is on screen, then hand the
  # working copy over. Re-fetched rather than adopting the action's result, as
  # `mark_reviewed` does: `health`/`due_at` are calculations the result does
  # not carry.
  defp run_workflow(socket, "publish_changes") do
    params =
      socket.assigns.form
      |> AshPhoenix.Form.params()
      |> inject_children(socket.assigns.block_children)
      |> inject_rich_bodies(socket.assigns.rich_bodies)

    case flush_working_copy(socket, params) do
      {:ok, socket} ->
        live_transition(socket, "publish_changes", gettext("Published your changes."))

      {:error, socket} ->
        socket
    end
  end

  # "Discard the changes": the published text is back, and every rich-text
  # block remounts onto it — `reset_editors/1`, as a version restore does,
  # since TipTap keeps whatever it was showing across a form replacement.
  defp run_workflow(socket, "discard_changes") do
    socket
    |> cancel_autosave_timer()
    |> live_transition(
      "discard_changes",
      gettext("Discarded the changes — the published text is back.")
    )
    |> reset_editors()
  end

  defp run_workflow(socket, _action), do: socket

  defp live_transition(socket, verb, flash) do
    %{kind: kind, record: record, actor: actor} = socket.assigns

    result =
      EditorTelemetry.span(:workflow, %{kind: kind, action: verb}, fn ->
        do_workflow(kind, verb, record, actor)
      end)

    case result do
      {:ok, updated} ->
        socket
        |> assign_record(fetch!(kind, updated.id, actor, record.org_id))
        |> broadcast_saved()
        |> assign(:save_state, :saved)
        |> put_flash(:info, flash)

      {:error, error} ->
        if stale_conflict?(error),
          do: flag_conflict(socket),
          else: put_flash(socket, :error, gettext("That action isn't allowed right now."))
    end
  end

  # #817 (follow-up to #501): "Submit for review" only ever reaches here for
  # an editor (workflow_buttons/1 shows that button only when @state == :draft
  # and @tier == :editor — an admin's own path skips straight to Publish), so
  # this closes the loop between "this needs review" and "here's who owns
  # reviewing it" without a role check of its own.
  #
  # Reuses the Assignment panel wholesale — same open?/draft assigns,
  # same CMS.assign_task/2 path `task_assign_submit` already calls — rather
  # than a new component, mirroring how a `?assign=1` deep link opens it
  # (`open_settings_if_deep_linked/2`). Optional/dismissable: the panel's own
  # Cancel button is "no thanks", and the "notify the org's admins" email
  # (`Notifications.dispatch(:submitted_for_review, ...)`) already covers the
  # general case of nobody being named. A blank due date is a real choice
  # (`assign_task`'s own `nil`), so this only ever SUGGESTS one — the
  # assignee picker itself stays on its own default ("Assign to…", nothing
  # selected).
  @review_due_in_days 3

  defp maybe_prompt_reviewer_assignment(socket, "submit") do
    socket
    |> assign(:inspector_tab, :settings)
    |> assign(:task_assign_open?, true)
    |> assign(:task_draft, %{
      "due_on" => Date.utc_today() |> Date.add(@review_due_in_days) |> Date.to_iso8601()
    })
  end

  defp maybe_prompt_reviewer_assignment(socket, _action), do: socket

  # --- dirty tracking + draft autosave ----------------------------------------

  @doc false
  def do_autosave(socket) do
    socket = assign(socket, :autosave_timer, nil)

    # A live document's text autosaves into its working copy
    # (docs/working-copy.md); a draft's into the row.
    if socket.assigns.record.state == :published do
      params =
        socket.assigns.form
        |> AshPhoenix.Form.params()
        |> inject_children(socket.assigns.block_children)
        |> inject_rich_bodies(socket.assigns.rich_bodies)

      autosave_working_copy(socket, params)
    else
      autosave_draft(socket)
    end
  end

  # The working-copy twin of `autosave_draft/1`: the same params the form
  # holds, submitted to `:save_working_copy` under the working column names.
  #
  # The throwaway form is built on a struct whose `working_title` /
  # `working_blocks` already carry the text the copy is measured against
  # (`WorkingCopy.basis/1` — the previous copy, else the published text).
  # Two reasons. The block sub-forms then bind to existing blocks by index, so
  # each is an update of a block rather than a create of a new one — exactly
  # how the draft path's sub-forms bind to `blocks`. And an unchanged text
  # registers as no change at all: `StampWorkingCopy` compares the copy to the
  # published text and clears it when they agree.
  defp autosave_working_copy(socket, params) do
    record = socket.assigns.record
    basis = WorkingCopy.basis(record)

    form =
      AshPhoenix.Form.for_update(
        %{record | working_title: basis.title, working_blocks: basis.blocks},
        :save_working_copy,
        actor: socket.assigns.actor,
        tenant: record.org_id,
        forms: [auto?: true]
      )

    copy = %{"working_title" => params["title"], "working_blocks" => params["blocks"] || []}

    result =
      EditorTelemetry.span(:autosave, %{kind: socket.assigns.kind}, fn ->
        AshPhoenix.Form.submit(form, params: copy)
      end)

    case result do
      {:ok, saved} ->
        reloaded =
          fetch!(socket.assigns.kind, saved.id, socket.assigns.actor, socket.assigns.current_org)

        socket |> assign_record(reloaded) |> broadcast_saved() |> assign(:save_state, :saved)

      {:error, form} ->
        handle_autosave_error(socket, form)
    end
  end

  defp autosave_draft(socket) do
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

    # Autosave carried the identical defect and was never named in #638: it
    # submits the live form's params, so a debounced save detached an
    # out-of-scope tag just as an explicit one did — and did it without
    # anyone pressing anything. `:autosave` accepts the same verbs (#636
    # mirrored them there for this change).
    #
    # No rewrite here: these params come from the form, which `validate`
    # already normalized, not from the browser. `merge_tag_params/2` refuses
    # to run twice for this reason, but not calling it at all is clearer
    # about where the one rewrite happens.

    result =
      EditorTelemetry.span(:autosave, %{kind: socket.assigns.kind}, fn ->
        AshPhoenix.Form.submit(autosave_form, params: params)
      end)

    case result do
      {:ok, record} ->
        reloaded =
          fetch!(socket.assigns.kind, record.id, socket.assigns.actor, socket.assigns.current_org)

        socket |> assign_record(reloaded) |> broadcast_saved() |> assign(:save_state, :saved)

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

  # Re-read the persisted record and everything derived from it. See the
  # `{:record_saved, _}` handler for what is deliberately left alone.
  #
  # ## `@record` is the optimistic lock's basis, so it only moves when it is free
  #
  # `:autosave` carries `change optimistic_lock(:lock_version)`, and
  # `do_autosave/1` builds its changeset from `socket.assigns.record`. Advancing
  # that assign while `@form` still holds this session's older data hands the
  # lock a version it will accept and then writes the stale form over the peer's
  # save — silently, with no conflict flash. That is worse than the staleness
  # this function exists to fix, and it bites hardest with the collaboration
  # prototype OFF (the default), where two editors really are two independent
  # writers.
  #
  # So the version list — which is read-only, and drags an open comparison with
  # it — refreshes unconditionally, and `@record` moves only for a session that
  # has nothing of its own in flight. A session that does keeps its old record,
  # so its next save still hits `StaleRecord` and still surfaces the conflict.
  @doc false
  def refresh_saved_record(socket) do
    reloaded =
      fetch!(
        socket.assigns.kind,
        socket.assigns.record.id,
        socket.assigns.actor,
        socket.assigns.current_org
      )

    # `@record` first, `load_versions/1` second — the latter recomputes an open
    # comparison, and the "Current draft" side of that comparison is built from
    # `@record`. Reversed, the modal recomputes against the record it is about to
    # replace and goes on reporting the state it just stopped holding.
    socket
    |> adopt_saved(reloaded)
    |> load_versions()
  rescue
    # The record went away, or this session may no longer read it. Keeping the
    # last known state is the same thing every other read failure here does, and
    # far better than crashing an editor over someone else's save.
    _error -> socket
  catch
    # A pool or GenServer timeout inside Ash arrives as an exit, which `rescue`
    # does not catch — and a bystander's editor must not die because of the
    # timing of someone else's save.
    :exit, _reason -> socket
  end

  # Adopt the persisted record, unless this session has something of its own that
  # adopting it would put at risk: a pending autosave (`:saving`), an edit that
  # failed validation (`:error`), an un-persisted change (`:unsaved`), or edits
  # suppressed because another editor is the elected persister (`:synced`).
  #
  # A session holding any of those keeps its old record deliberately, so its next
  # save still fails the optimistic lock and still surfaces the conflict. Its
  # version panel refreshes either way — that is read-only and cannot lose
  # anything.
  defp adopt_saved(%{assigns: %{save_state: :saved}} = socket, record) do
    socket
    |> assign(:record, record)
    |> assign(:page_title, record.title)
    |> assign(:may_write?, may_write?(record, socket.assigns.actor, socket.assigns.current_org))
    |> assign(
      :may_suggest_seo?,
      may_write_fields?(
        record,
        socket.assigns.actor,
        socket.assigns.current_org,
        seo_suggestion_fields()
      )
    )
    |> assign(
      :may_assist_blocks?,
      may_write_fields?(record, socket.assigns.actor, socket.assigns.current_org, ["blocks"])
    )
    |> assign(:slug_customized?, slug_customized?(socket))
  end

  defp adopt_saved(socket, _record), do: socket

  # Rewrite the picker's ticks into the merge verbs (#638).
  #
  # No create branch, because this LiveView has none: `for_update/3` is its only
  # form constructor (content is created elsewhere and edited here). That
  # matters, because `:create` rejects the verbs outright — it has nothing to
  # merge against — so a create path added later has to come back through here
  # rather than inherit this by accident.
  #
  # `tag_ids` is the COMPLETE set, so submitting it means "these are the only
  # tags" — and a checkbox that was never rendered was never submitted, so
  # narrowing a tag group's content types silently stripped tags off existing
  # content on the next Save. That is what the "Also attached" rescue section,
  # the hidden `""` sentinel and `normalize_tag_ids/1` all existed to work
  # around; #636 gave the resource `add_tag_ids`/`remove_tag_ids`, and this is
  # the caller finally using them.
  #
  # The diff is taken against what the server chose to RENDER, not against the
  # record's current tags:
  #
  #   * `remove` is rendered-minus-ticked. A tag with no checkbox cannot appear
  #     here, which is exactly the property that was missing — it survives
  #     instead of being detached by omission.
  #   * `add` is every ticked id, not ticked-minus-attached. `:append` is
  #     `on_match: :ignore`, so re-adding is free, and diffing against a
  #     possibly-stale `record.tags` would drop a tick for a tag a collaborator
  #     detached since this page loaded.
  #
  # Deriving `rendered` server-side rather than posting it as a hidden field is
  # also what bounds the blast radius: a forged payload can only tick ids, and
  # what may be *removed* stays whatever this server put on the page.
  #
  # An all-unchecked group now submits no `tag_ids` key at all and needs none —
  # `ticked` is empty, so every rendered tag lands in `remove`. That is the
  # sentinel's whole job, done by the diff instead.
  # NB this is not idempotent, and must only ever see BROWSER params. It
  # consumes `tag_ids`, so a second pass over its own output reads as "nothing
  # ticked" and removes everything the first pass just added — which is exactly
  # what happened when autosave (which forwards the *form's* params, already
  # rewritten by `validate`) also called it. Autosave therefore does not, and
  # "a section already on screen stays closed once its tag is saved" is the test
  # that catches it coming back.
  #
  # An earlier version guarded that with a shape check — "if it already has the
  # verbs, pass it through". That was worse than useless: it also let a crafted
  # payload post its own `remove_tag_ids` and skip the rewrite entirely, which
  # is precisely the bound this function exists to impose.
  defp merge_tag_params(params, socket) do
    ticked = ticked_tag_ids(params)
    ticked_set = MapSet.new(ticked)

    # `rendered` is every tag the picker put a checkbox on, precomputed in
    # `refresh_tag_index/1`. `tag_picker/1` renders the sections and nothing
    # else (an empty `sections` renders no controls at all), so it is the
    # rendered set exactly — which has to be true rather than approximately
    # true, because it is the ceiling on what this save may detach.
    removed =
      socket.assigns.tag_index.rendered
      |> Enum.reject(&MapSet.member?(ticked_set, &1))

    params
    |> Map.delete("tag_ids")
    |> Map.put("add_tag_ids", ticked)
    |> Map.put("remove_tag_ids", removed)
  end

  # Blanks are dropped, and that is not the old sentinel coming back: nothing
  # renders a `""` any more, so the only way one arrives is a page that was
  # loaded before this deployment and submitted after it. Reading it as an id
  # would fail the uuid cast and turn a routine save into an error the editor
  # cannot act on; reading it as "nothing ticked" is what that page meant.
  defp ticked_tag_ids(params) do
    params
    |> Map.get("tag_ids", [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
  end

  # The media id currently on an image block sub-form, if any.
  defp media_id_of(bf), do: bf[:media_id].value

  defp reset_picker(socket) do
    socket
    |> assign(:picking, nil)
    |> assign(:picked, [])
    |> assign(:media_query, "")
    |> assign(:picker_media, nil)
    |> assign(:picker_tab, :library)
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
    # Paths the body already links to, so we don't suggest a link that's there.
    linked = socket.assigns.seo_body_stats.internal_link_paths
    # `user_id`, not `actor`: the suggestion set itself is identical for every
    # actor (#869, see below) — this is only the `KilnCMS.LLM.Budget`
    # per-caller bucket for `suggest/2`'s semantic leg, same as `actor.id` for
    # `load_content_intel/1` below (#1076).
    actor_id = socket.assigns.actor && socket.assigns.actor.id

    socket
    |> assign(:seo_links_loading?, true)
    |> start_async(:seo_links, fn ->
      # No actor/tenant: `suggest/2` scopes to `record`'s own org and the
      # published/`:public` delivery boundary, so it is identical for every actor
      # (#869).
      KilnCMS.Seo.Links.suggest(record, exclude_paths: linked, user_id: actor_id)
    end)
  end

  # ── Content intelligence (#339) ────────────────────────────────────────────

  defp load_content_intel(socket) do
    # Plain data only into the task, never the socket or the form: both are
    # stale the moment an autosave rebuilds them. `record` is refreshed on every
    # autosave, so the neighbour queries run against saved content — a passage
    # typed since the last save isn't indexed yet either way.
    record = socket.assigns.record
    version = socket.assigns.editor_version
    # The actor is not optional here. Near-duplicates span every workflow state
    # and audience, and the taxonomy read has to agree with the tag picker's —
    # a suggestion for a tag this editor's picker doesn't list is an Add button
    # with no checkbox to tick.
    actor = socket.assigns.actor
    # `user_id`, not `org_id`: both calls take the org bucket key from the
    # record itself (`KilnCMS.Search.Related`'s `"search_embedding"` budget,
    # #1076) — this is only the per-caller half, same as `actor.id` for the
    # SEO panel's `KilnCMS.Seo.draft/2` call above.
    actor_id = actor && actor.id

    socket
    |> assign(:intel_loading?, true)
    |> start_async(:content_intel, fn ->
      {version,
       %{
         duplicates: Related.near_duplicates(record, actor: actor, user_id: actor_id),
         tags: Related.suggest_tags(record, actor: actor, user_id: actor_id)
       }}
    end)
  end

  # Normalizes a `KilnCMS.Search.Related` result to a displayable list plus the
  # blocking reason, if any — `{:error, reason}` (a `KilnCMS.LLM.Budget` block,
  # #1076) renders as an empty list too, but the second value tells
  # `handle_async(:content_intel, ...)` apart from a genuine "nothing found",
  # and carries enough detail for `intel_error_message/1` to say *why*, the
  # same as `seo_error_message/1` does for the SEO panel's own budget errors.
  defp intel_outcome({:error, reason}), do: {[], reason}
  defp intel_outcome(list) when is_list(list), do: {list, nil}

  # Tick a suggested tag in the form's `tag_ids`, then drop it from the panel.
  #
  # The current selection is read the same way `tag_picker/1` reads it —
  # form value first, persisted tags as the fallback — because a form that has
  # never had its tag group submitted carries no `tag_ids` at all, and putting
  # a one-element list there would submit "these are the only tags", detaching
  # every tag already on the record (#522's failure, from the other direction).
  defp add_suggested_tag(socket, tag_id) do
    suggestions = socket.assigns.intel_tags || []

    cond do
      not Enum.any?(suggestions, &(to_string(&1.tag.id) == tag_id)) ->
        # Not a tag we offered — a replayed or forged event. Ignore it rather
        # than attaching whatever id was pushed.
        socket

      socket.assigns.conflict ->
        put_flash(socket, :error, gettext("Reload the page before changing tags."))

      true ->
        current =
          socket.assigns.form
          |> selected_tag_ids(socket.assigns.record)
          |> MapSet.to_list()

        # Written back as `tag_ids` and immediately rewritten by
        # `merge_tag_params/2` — leaving `tag_ids` in the form's params
        # beside the verbs would make the next save contradictory, and
        # `MergeArguments` refuses that combination outright rather than
        # resolving it by declaration order.
        params =
          socket.assigns.form
          |> AshPhoenix.Form.params()
          |> Map.drop(["add_tag_ids", "remove_tag_ids"])
          |> Map.put("tag_ids", Enum.uniq(current ++ [tag_id]))
          |> merge_tag_params(socket)

        socket
        |> assign(:form, AshPhoenix.Form.validate(socket.assigns.form, params))
        |> assign(:intel_tags, Enum.reject(suggestions, &(to_string(&1.tag.id) == tag_id)))
        |> mark_dirty(:settings)
    end
  end

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

      # Re-checked per card, not just at generation time (#868): the panel is
      # hidden when the grant narrows mid-session, but a queued or replayed
      # `seo_accept` still arrives — and writing the value would schedule an
      # autosave the change then refuses on that exact field.
      not field_granted?(
        socket.assigns.record,
        socket.assigns.actor,
        socket.assigns.current_org,
        field
      ) ->
        {socket, :not_permitted}

      true ->
        params = socket.assigns.form |> AshPhoenix.Form.params() |> Map.put(field, value)
        {params, socket, outcome} = maybe_sync_slug(field, params, socket)

        socket =
          socket
          |> assign(:form, AshPhoenix.Form.validate(socket.assigns.form, params))
          |> assign(:seo_dismissed, MapSet.put(socket.assigns.seo_dismissed, field))
          |> mark_dirty(:settings)

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

  # Content intelligence (#339)'s own version of `seo_error_message/1` above —
  # a separate function because its errors come from `KilnCMS.LLM.Budget` via
  # `KilnCMS.Search.Related` (#1076) rather than `KilnCMS.Seo.draft/2`, so the
  # reason shapes only partially overlap (no `:too_short` or `:disabled` here).
  defp intel_error_message({:rate_limited, retry_after_ms}),
    do:
      gettext("Content intelligence is at its rate limit. Try again in %{seconds}s.",
        seconds: max(div(retry_after_ms, 1000), 1)
      )

  defp intel_error_message(:unattended_disabled),
    do: gettext("Content intelligence isn't available for unattended callers right now.")

  defp intel_error_message(_reason),
    do: gettext("Content intelligence is at its rate limit right now. Please try again shortly.")

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
    # Same write-authorization boundary as `seo_suggest` (#550): block assist
    # also bills an org LLM run, so read access to the record must not be
    # enough to spend it. Refused server-side, not just hidden.
    # …and the grant, for the same reason `seo_suggest` needs it (#868):
    # assist bills its own budget and writes prose into a block, so a
    # `blocks`-less grant means a billed run whose result the save refuses.
    socket.assigns.assist_enabled? and
      socket.assigns.may_write? and
      socket.assigns.may_assist_blocks? and
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
      |> mark_dirty(:settings)
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
  # That section used to be load-bearing: tags were written with
  # `manage_relationship(:tag_ids, :tags, type: :append_and_remove)`, so a
  # checkbox that was not rendered was not submitted and the link was *removed*
  # — and without this section, narrowing a group's content types silently
  # stripped tags off existing content on the next Save.
  #
  # Since #638 the picker submits `add_tag_ids`/`remove_tag_ids` diffed against
  # what it rendered, so an unrendered tag simply survives and the section is no
  # longer holding anything up. It stays for the two things it was always also
  # doing, which are worth keeping on their own: telling an editor that a tag
  # from a group scoped elsewhere is on this item, and giving them a control to
  # take it off. Note the consequence of keeping the checkboxes — these tags ARE
  # rendered, so unticking one does now remove it, which is the point.
  defp tag_sections(tags, groups, kind, attached) do
    kind = to_string(kind)
    known_ids = MapSet.new(groups, & &1.id)
    applicable = Enum.filter(groups, &applies_to?(&1, kind))
    applicable_ids = MapSet.new(applicable, & &1.id)
    by_bucket = Enum.group_by(tags, &bucket_for(&1, known_ids, applicable_ids))

    grouped =
      Enum.map(applicable, fn group ->
        section({:group, group.id}, group.name, Map.get(by_bucket, {:group, group.id}, []))
      end)

    ungrouped = section(:ungrouped, gettext("Ungrouped"), Map.get(by_bucket, :ungrouped, []))

    # Out-of-scope groups contribute only what the record ALREADY carries.
    # Keyed on `attached` (the persisted set) rather than `selected` (the live
    # ticks): keying on the latter meant unchecking a tag here emptied the
    # section, `Enum.reject` deleted it, and there was no control left to undo
    # with. Still true and still the reason — and now doubly so, because the
    # removal diff is taken against what was rendered: a control that vanishes
    # mid-edit would take its tag out of `remove_tag_ids` and quietly cancel the
    # detach the editor just asked for.
    orphaned_tags =
      by_bucket
      |> Map.get(:out_of_scope, [])
      |> Enum.filter(&(to_string(&1.id) in attached))

    orphaned =
      section(
        :out_of_scope,
        gettext("Also attached"),
        orphaned_tags,
        gettext("Already on this item, from a group scoped to other content types.")
      )

    Enum.reject(grouped ++ [ungrouped, orphaned], &(&1.tags == []))
  end

  # Which section a tag belongs in. A `tag_group_id` that resolves to no loaded
  # group — a dangling pointer, or one written across tenants (the FK has no
  # org component) — falls back to "Ungrouped" rather than vanishing. That was
  # originally about data loss (an unsubmitted checkbox was a detach); since
  # #638 it is about reach: a tag with no control cannot be *removed*, so
  # vanishing would strand it on the record with no way to take it off.
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

  # `key` identifies the section across re-renders (the label is translated and
  # a group's name is editable, so neither is stable) — `@open_sections` is a
  # set of these, and `tag_section_id/1` turns one into the DOM id.
  defp section(key, label, tags, note \\ nil) do
    %{key: key, label: label, tags: Enum.map(tags, &tag_view/1), note: note}
  end

  # The projection the template renders. `id` is stringified and `filter` is
  # downcased HERE rather than in the markup, because the section list is built
  # once per record change while the markup is rebuilt on every keystroke —
  # `String.downcase/1` per tag per render was the whole reason this exists.
  defp tag_view(tag), do: %{id: to_string(tag.id), name: tag.name, filter: downcase(tag.name)}

  defp downcase(name) when is_binary(name), do: String.downcase(name)
  defp downcase(_name), do: ""

  # Which sections the picker renders expanded — a section carrying a tag the
  # record already has starts open, so what's on the item is visible without
  # clicking through every group.
  #
  # Deliberately NOT re-derived per render (#523). `open` was `selected_count >
  # 0` on every patch, and `app.js`'s app-wide <details> preservation only holds
  # the editor's own toggle while the *server-rendered* value is unchanged — so
  # unticking a group's last tag flipped that value true→false, the guard was
  # skipped, and the section folded shut under the cursor, hiding the siblings
  # they were about to click.
  #
  # So a section is judged EXACTLY ONCE: the first time it renders, when there
  # is no editor toggle to overrule. `@sections` is rebuilt from the reloaded
  # `record.tags` on every save, so that isn't only at mount — a section can
  # appear mid-session, most importantly "Also attached", which surfaces a tag a
  # collaborator hung off an out-of-scope group (#522) precisely so it can be
  # seen and undone before the next `append_and_remove` save, and which arriving
  # collapsed would undercut. After that first render the attribute is the
  # editor's (and the filter hook's), in both directions, for the session.
  defp refresh_tag_index(socket) do
    %{tags: tags, tag_groups: groups, kind: kind, record: record} = socket.assigns
    attached = record.tags |> current_ids() |> MapSet.new(&to_string/1)
    seen = socket.assigns.tag_sections_seen

    # `@tags` is loaded once at mount and never refreshed, but `record.tags` is
    # (every autosave's `fetch!`). So a tag created and attached after mount — a
    # collaborator, another tab — is in `record.tags` but not `@tags`, renders
    # no checkbox, and the next save submits `tag_ids` without it, which
    # `append_and_remove` reads as "detach me" (#522). Build from the union of
    # the two so every attached tag always has a control; the sections and the
    # empty-state guard both key on it, not on the stale `@tags` alone.
    pickable = all_pickable_tags(tags, record.tags)
    sections = tag_sections(pickable, groups, kind, attached)

    # Judged against what is PERSISTED, not what is ticked — see the template.
    counted = with_counts(sections, attached)

    fresh =
      for section <- counted,
          not MapSet.member?(seen, section.key),
          section.selected_count > 0,
          into: MapSet.new(),
          do: section.key

    socket
    # `rendered` is stamped here for the same reason `tag_view/1` downcases
    # here: the section list is built once per record change, and the thing
    # that reads this runs on every keystroke (`validate` rewrites the tag
    # params on each one). Walking every section's tags per keystroke to
    # rebuild a set that only changes with the record is the exact cost this
    # module already refuses to pay elsewhere.
    |> assign(:tag_index, %{
      sections: sections,
      pickable?: pickable != [],
      # `tag_view/1` already stringified the ids, so this is comparable to the
      # form params without further coercion.
      rendered: MapSet.new(for section <- sections, tag <- section.tags, do: tag.id)
    })
    |> update(:tag_sections_open, &MapSet.union(&1, fresh))
    |> assign(:tag_sections_seen, MapSet.union(seen, MapSet.new(sections, & &1.key)))
  end

  defp any_custom_field_errors?(form, definitions),
    do: Enum.any?(definitions, &(custom_field_errors(form, &1.name) != []))

  # A three-valued select: "" is `nil` ("use the site default"), and it is a
  # value in its own right rather than a missing one (#818). Anything else
  # unrecognised also reads as `nil`, so a hand-pushed payload lands on the
  # inheriting default rather than silently pinning the task.
  defp tri_state("true"), do: true
  defp tri_state("false"), do: false
  defp tri_state(_other), do: nil

  # Server-side substring search over filename/alt/caption (audit U-M2): finds
  # items beyond the mounted picker window, and matches partial input as the
  # user types (the library's `:search` action is whole-word tsquery, less
  # forgiving for a live picker). %, _ and \ in the input match literally.
  #
  # `kind` filters to the same image/document split the mounted `@media`/
  # `@file_media` lists use (#481) — the image picker must never surface a
  # document it can't render as an `<img>`, and vice versa.
  # The org tag vocabulary for the picker (#1149): three columns, alphabetical,
  # capped. A non-blank `filter` is an `ilike` on the name so tags past the
  # mount window stay reachable; attached tags outside the window are still
  # unioned in by `all_pickable_tags/2`.
  defp load_org_tags(actor, org, filter) do
    query =
      KilnCMS.CMS.Tag
      |> Ash.Query.select([:id, :name, :tag_group_id])
      |> Ash.Query.sort(name: :asc)
      |> Ash.Query.limit(max_tags())

    query =
      case String.trim(filter) do
        "" ->
          query

        text ->
          pattern = "%" <> String.replace(text, ~r/([\\%_])/, "\\\\\\1") <> "%"
          Ash.Query.filter(query, expr(ilike(name, ^pattern)))
      end

    CMS.list_tags!(actor: actor, tenant: org, query: query)
  end

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
        data-dirty={to_string(@save_state != :saved or @settings_dirty?)}
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
            <%!-- Duplicate into a new draft (#471). The copy is made from the
                  SAVED row, which is the part worth warning about — and the
                  warning has to cover two different reasons the saved row is not
                  what is on screen. A dirty buffer is your own unsaved work; a
                  conflict means the saved row is somebody ELSE's save, so the
                  copy would be of content you have never seen (#928).

                  `:if={@may_write?}` like every other write affordance in this
                  file (#922): this route deliberately admits an actor who may
                  OPEN a record without being able to write it (#550), and
                  forking someone else's draft is a write. --%>
            <button
              :if={@may_write?}
              type="button"
              phx-click="duplicate"
              data-confirm={duplicate_confirm(@save_state, @conflict)}
              class="btn btn-sm btn-default"
            >
              <.icon name="hero-document-duplicate" class="mr-1 size-4" />{gettext("Duplicate")}
            </button>
          </div>
        </div>

        <.editor_action_bar
          kind={@kind}
          record={@record}
          save_state={@save_state}
          settings_dirty?={@settings_dirty?}
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
              <%!-- The old addresses that still reach this record: a published
                    slug or alias change leaves a 301 behind, and this is where
                    the author sees it standing — and retires it, for the day
                    the old URL should stop answering. Empty for a record that
                    has never moved (most drafts), so the block is absent rather
                    than an empty heading. Delete is a write on the target's
                    behalf, hence `@may_write?` like every other write
                    affordance here; the policy re-checks it. --%>
              <div :if={@redirects != []} id="slug-redirects" class="text-xs sm:col-span-2">
                <p class="text-base-content/60">{gettext("Redirects to this address")}</p>
                <ul class="mt-1 space-y-1">
                  <li
                    :for={redirect <- @redirects}
                    id={"slug-redirect-#{redirect.id}"}
                    class="flex flex-wrap items-center gap-x-2 gap-y-1"
                  >
                    <span class="font-mono">{redirect.path}</span>
                    <span aria-hidden="true" class="text-base-content/40">&rarr;</span>
                    <span class="font-mono text-base-content/70">
                      {KilnCMS.CMS.Slugs.public_path_for(@content_type, @record)}
                    </span>
                    <span class="text-base-content/50">
                      {gettext("since %{date}", date: redirect_since(redirect))}
                    </span>
                    <button
                      :if={@may_write?}
                      type="button"
                      phx-click="delete_redirect"
                      phx-value-id={redirect.id}
                      data-confirm={gettext("Delete this redirect? The old URL will 404.")}
                      aria-label={gettext("Delete redirect")}
                      class="btn btn-xs btn-ghost text-base-content/60 hover:text-error"
                    >
                      {gettext("Delete")}
                    </button>
                  </li>
                </ul>
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

              <%!-- Narrow the tree to blocks with an open discussion. A count,
                    not a bare chip: "Unresolved" alone leaves an editor
                    guessing whether zero means "none" or "not loaded". Hidden
                    entirely when there is nothing to filter — a control that
                    can only ever hide everything is noise. --%>
              <div :if={unresolved_block_count(@comments) > 0} class="flex items-center gap-2">
                <button
                  type="button"
                  phx-click="toggle_thread_filter"
                  aria-pressed={to_string(@thread_filter == :unresolved)}
                  class={[
                    "inline-flex items-center gap-1 rounded-full border px-2.5 py-0.5 text-xs transition-colors duration-150",
                    @thread_filter == :unresolved &&
                      "border-warning/40 bg-warning/10 text-warning-ink",
                    @thread_filter != :unresolved && "border-base-content/20 hover:bg-base-200"
                  ]}
                >
                  <.icon name="hero-chat-bubble-left-ellipsis" class="size-3.5" />
                  {ngettext(
                    "%{count} unresolved discussion",
                    "%{count} unresolved discussions",
                    unresolved_block_count(@comments),
                    count: unresolved_block_count(@comments)
                  )}
                </button>
                <span :if={@thread_filter == :unresolved} class="text-xs text-base-content/60">
                  {gettext("Showing only blocks that need attention.")}
                </span>
              </div>

              <%!-- Insert a block before the first one (B2). --%>
              <.block_inserter
                :if={blocks_count(@form) > 0}
                id="insert-start"
                block_types={@block_types}
                anchor="start"
                compact
              />

              <div
                id="blocks-sortable"
                phx-hook="Sortable"
                data-thread-filter={@thread_filter}
                class="space-y-3"
              >
                <.inputs_for :let={bf} field={@form[:blocks]}>
                  <%!-- `BlockPresence` reports focus in and out of this card so
                        peers can see which block someone is on. `focusin`/
                        `focusout` rather than `phx-focus`/`phx-blur`: those bind
                        the non-bubbling `focus`/`blur`, which never fire for a
                        card whose focusable children are the inputs inside it. --%>
                  <div
                    id={"block-#{bf.index}"}
                    data-sort-id={bf.index}
                    phx-hook="BlockPresence"
                    data-block-id={bf[:id].value}
                    data-block-threads={discussion_state(@comments, @tasks, bf[:id].value)}
                    data-block-type={block_type_string(bf)}
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
                          class="cursor-grab active:cursor-grabbing rounded p-1 hover:bg-base-200 hover:text-base-content"
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
                          class="rt-block-toolbar mb-1 flex flex-wrap gap-1"
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
                        :if={
                          @assist_enabled? and @may_write? and @may_assist_blocks? and bf[:id].value
                        }
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
                          class="btn btn-sm btn-default"
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
                          class="btn btn-sm btn-default"
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
                    <div :if={block_type_string(bf) == "fragment"} class="space-y-2">
                      <%!-- One `<select>`, because a reference is one choice.
                            It posts `"type:id"`, which `normalize_fragment_ref/1`
                            turns into the stored reference map (#479). --%>
                      <.input
                        type="select"
                        name={bf[:ref].name}
                        value={fragment_ref_value(bf[:ref].value)}
                        label={gettext("Fragment")}
                        prompt={gettext("Choose published content…")}
                        options={fragment_options_for(@fragment_options, bf)}
                      />
                      <.input field={bf[:label]} label={gettext("Label (editor only)")} />
                      <p class="text-xs text-base-content/60">
                        {gettext(
                          "The target's blocks are inlined where this block sits. Editing the target updates every page that embeds it; an unpublished or restricted target renders nothing."
                        )}
                      </p>
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
                        "gallery",
                        "fragment"
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
                    <.block_discussion
                      :if={bf[:id].value}
                      block_id={bf[:id].value}
                      comments={@comments}
                      tasks={@tasks}
                      open?={@comment_block == bf[:id].value}
                      draft={if @comment_block == bf[:id].value, do: @comment_draft}
                      suggestions={
                        if @comment_block == bf[:id].value, do: @mention_suggestions, else: []
                      }
                      viewers={block_viewers(@editors, @actor.id, bf[:id].value)}
                      typing={typing_names(@typing, bf[:id].value)}
                      task_draft={if @comment_block == bf[:id].value, do: @block_task_draft}
                      assignable_users={@assignable_users}
                      linkable_tasks={linkable_tasks(@tasks)}
                      auto_complete_default={@auto_complete_default}
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

              <%!-- Discussions whose block is gone. Deleting a block cascades
                    nothing, so without this section the thread would simply
                    stop being rendered — still stored, still counted by every
                    org-wide read, invisible to the one person who could close
                    it out. --%>
              <div
                :if={orphan_block_ids(@form, @comments, @tasks) != []}
                class="space-y-2 rounded border border-dashed border-base-content/20 p-3"
              >
                <p class="text-sm font-medium text-base-content/70">
                  {gettext("Discussions on removed blocks")}
                </p>
                <.block_discussion
                  :for={orphan_id <- orphan_block_ids(@form, @comments, @tasks)}
                  block_id={orphan_id}
                  comments={@comments}
                  tasks={@tasks}
                  orphan?={true}
                  open?={@comment_block == orphan_id}
                  draft={if @comment_block == orphan_id, do: @comment_draft}
                  suggestions={if @comment_block == orphan_id, do: @mention_suggestions, else: []}
                  viewers={[]}
                  typing={typing_names(@typing, orphan_id)}
                  task_draft={if @comment_block == orphan_id, do: @block_task_draft}
                  assignable_users={@assignable_users}
                  linkable_tasks={linkable_tasks(@tasks)}
                  auto_complete_default={@auto_complete_default}
                />
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
            <.live_component
              module={KilnCMSWeb.ContentEditor.InspectorPreviewComponent}
              id="inspector-preview-panel"
              inspector_tab={@inspector_tab}
              form={@form}
              preview_html={@preview_html}
              kind={@kind}
              record={@record}
            />

            <%!-- ── Settings ────────────────────────────────────────────── --%>
            <.live_component
              module={KilnCMSWeb.ContentEditor.InspectorSettingsComponent}
              id="inspector-settings-panel"
              inspector_tab={@inspector_tab}
              form={@form}
              record={@record}
              kind={@kind}
              current_org={@current_org}
              tasks={@tasks}
              task_assign_open?={@task_assign_open?}
              task_draft={@task_draft}
              assignable_users={@assignable_users}
              auto_complete_default={@auto_complete_default}
              comments={@comments}
              release_item={@release_item}
              release_of_item={@release_of_item}
              releases={@releases}
              release_draft={@release_draft}
              categories={@categories}
              audiences={@audiences}
              tag_index={@tag_index}
              tag_sections_open={@tag_sections_open}
              tag_query={@tag_query}
              tags={@tags}
              max_tags={@max_tags}
              media={@media}
              related_field={@related_field}
              related_current={@related_current}
              siblings={@siblings}
              field_definitions={@field_definitions}
              reference_options={@reference_options}
              a11y_report={@a11y_report}
              compliance_report={@compliance_report}
              seo_report={@seo_report}
              slug_customized?={@slug_customized?}
              seo_enabled?={@seo_enabled?}
              seo_egress?={@seo_egress?}
              seo_provider={@seo_provider}
              seo_drafting?={@seo_drafting?}
              seo_drafts={@seo_drafts}
              seo_dismissed={@seo_dismissed}
              locked_fields={@locked_fields}
              cursors={@cursors}
              may_write?={@may_write?}
              may_suggest_seo?={@may_suggest_seo?}
              conflict={@conflict}
              editor_version={@editor_version}
              seo_links={@seo_links}
              seo_links_loading?={@seo_links_loading?}
              intel_duplicates={@intel_duplicates}
              intel_tags={@intel_tags}
              intel_loading?={@intel_loading?}
            />

            <%!-- ── History ─────────────────────────────────────────────── --%>
            <.live_component
              module={KilnCMSWeb.ContentEditor.InspectorHistoryComponent}
              id="inspector-history-panel"
              inspector_tab={@inspector_tab}
              record={@record}
              kind={@kind}
              may_write?={@may_write?}
              translations={@translations}
              versions={@versions}
              current_pick={@current_pick}
              compare_pick={@compare_pick}
            />
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
        unsplash_enabled?={@unsplash_enabled?}
        picker_tab={@picker_tab}
        unsplash_query={@unsplash_query}
        unsplash_photos={@unsplash_photos}
        unsplash_more?={@unsplash_more?}
        unsplash_searching?={@unsplash_searching?}
        unsplash_importing={@unsplash_importing}
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

  # Two reasons the saved row differs from what is on screen, and they need
  # different words: unsaved work is yours to lose, a conflict is someone else's
  # save you have not read.
  defp duplicate_confirm(_save_state, true),
    do:
      gettext(
        "Someone else saved this page. Duplicating copies their version, not what you see. Continue?"
      )

  defp duplicate_confirm(save_state, _conflict) when save_state != :saved,
    do: gettext("Unsaved changes won't be copied. Duplicate the last saved version?")

  defp duplicate_confirm(_save_state, _conflict), do: false

  # A field grant can leave a translation narrower than its source, and so can
  # the block-field policy (#1157/#890). Saying so is the difference between
  # "translation is broken" and "your role cannot copy those fields" — the same
  # distinction the Duplicate handler draws (#929).
  defp translation_flash(locale, []),
    do: gettext("Draft translation created (%{locale}).", locale: locale)

  defp translation_flash(locale, withheld) do
    gettext(
      "Draft translation created (%{locale}). Not copied, because your role cannot set them: %{fields}.",
      locale: locale,
      fields: Enum.join(withheld, ", ")
    )
  end
end
