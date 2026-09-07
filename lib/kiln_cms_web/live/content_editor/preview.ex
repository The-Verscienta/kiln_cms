defmodule KilnCMSWeb.ContentEditor.Preview do
  @moduledoc """
  The content editor's live-preview and advisory refresh pipeline: rendering
  the typed block tree through the same serializers firing uses, the memoized
  SEO/accessibility/compliance body analysis, and the pop-out preview
  broadcasts.

  Extracted verbatim from `KilnCMSWeb.ContentEditorLive` (#1311). Functions
  here take the editor's socket and return it; nothing persists.
  """

  import Phoenix.Component, only: [assign: 3]
  import KilnCMSWeb.ContentEditor.BlockParams, only: [block_field_map: 2]

  alias Kiln.Advisory.Registry
  alias Kiln.Advisory.Report
  alias KilnCMS.Accounts

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
  def refresh_preview(socket) do
    typed =
      socket.assigns.form
      |> preview_block_maps()
      |> KilnCMS.CMS.TypedBlocks.to_typed()
      |> expand_fragments(socket)

    socket
    |> refresh_preview_html(typed)
    |> refresh_body_stats(typed)
    |> refresh_seo_report()
  end

  # A `%Fragment{}` block renders nothing on its own — until inlined, the
  # Preview tab shows it as empty and the SEO/readability panel (word count,
  # reading time, heading outline, alt-text, internal links) scores the
  # document as if it were missing (#910). `Fragments.expand/3` no-ops when
  # the tree carries no fragment, so this costs a tree walk on the common
  # document and a bounded, cached target read only when one is actually
  # embedded — the same cost every publish already pays in
  # `KilnCMS.Firing.Engine.fire/2`.
  #
  # Expanded with the record's OWN audience, mirroring `Engine.host_audiences/1`
  # exactly: a `:member` document's preview must not show a wider-audience
  # fragment than delivery will ever grant it, or the author sees text a
  # reader of the finished page could never see.
  defp expand_fragments(typed, socket) do
    record = socket.assigns.record

    KilnCMS.CMS.Fragments.expand(typed, record.org_id,
      audiences: KilnCMS.Firing.Engine.host_audiences(record),
      ancestry: [{KilnCMS.Firing.Engine.public_type(record), record.id}]
    )
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
    # This site's settings, not the deployment's (#857) — resolved here rather
    # than at mount so an admin turning the panel on, or editing the site's
    # phrase list, reaches an editor session already open. `Settings.for_org/1`
    # is cached per org, so this is an ETS read per form change.
    settings = KilnCMS.Compliance.Settings.for_org(socket.assigns.current_org)

    # The resolved settings are part of the digest, not just the blocks: the
    # body scan is memoized here, so switching claim checking on (or editing the
    # rules) while an editor session is open would otherwise leave that session
    # showing the previous scan — or no panel at all — until the author
    # happened to touch the body.
    digest = :erlang.phash2({typed, settings})

    if digest == socket.assigns[:seo_body_digest] do
      socket
    else
      body = Kiln.Advisory.Body.from_typed(typed)

      socket
      |> assign(:seo_body_digest, digest)
      |> assign(:seo_body_stats, body)
      |> assign(:compliance_settings, settings)
      # Scanning the whole document for every configured claim phrase is body
      # work, so it is memoized here with the rest of it (#377). The short
      # scalar fields are scanned per keystroke in `refresh_seo_report/1` and
      # merged in — see `KilnCMS.Compliance.merge/2`.
      |> assign(:claim_body_matches, scan_claims(settings, body.text))
      |> refresh_link_targets()
    end
  end

  # `%{}` rather than `nil` when nothing matched, so the check can tell "scanned
  # and clean" from "nobody scanned" — which it reports as `:n_a`, because a
  # document nobody checked is not a document that is clean.
  defp scan_claims(%KilnCMS.Compliance.Settings{enabled?: true} = settings, text),
    do: KilnCMS.Compliance.scan(text, settings.rules)

  defp scan_claims(_off, _text), do: nil

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
          Accounts.org_id(socket.assigns.current_org)
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
          # Both compliance facts come from the one resolve in
          # `refresh_body_stats/2`: matches computed under this site's
          # vocabulary have to be graded under the same one (#857).
          compliance_settings: socket.assigns[:compliance_settings],
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
        rules = socket.assigns.compliance_settings.rules

        @claim_scanned_fields
        |> Enum.reduce(body_matches, fn field, acc ->
          fields
          |> Map.get(field)
          |> to_string()
          |> KilnCMS.Compliance.scan(rules)
          |> then(&KilnCMS.Compliance.merge(acc, &1))
        end)
    end
  end

  # Push the current title + blocks to any open decoupled preview windows.
  # Skipped entirely while no window is watching (audit P-M2) — otherwise every
  # editor paid the full typed→legacy block conversion per debounced keystroke
  # for a payload nobody received.
  def broadcast_preview(%{assigns: %{preview_open?: false}} = socket), do: socket

  def broadcast_preview(socket) do
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

  def broadcast_preview_and_refresh(socket) do
    socket = refresh_preview(socket)
    broadcast_preview(socket)
    socket
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

  def preview_block_maps(form) do
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
  def block_full_map(%AshPhoenix.Form{} = subform) do
    subform
    |> block_field_map("_type")
    |> sanitize_preview_block()
  end

  defp sanitize_preview_block(%{"_type" => "rich_text"} = map),
    do: Map.update(map, "legacy_html", nil, &KilnCMS.HTMLSanitizer.sanitize_rich_text/1)

  defp sanitize_preview_block(map), do: map
end
