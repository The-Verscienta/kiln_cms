defmodule KilnCMSWeb.ContentEditor.Shared do
  @moduledoc """
  View helpers the content editor's LiveView and its extracted components
  share: the advisory collaborative field locks, per-collaborator colors and
  cursor badges, tag/custom-field/SEO-suggestion selection readers, and small
  label formatters.

  Extracted verbatim from `KilnCMSWeb.ContentEditorLive` (#1311).
  """

  use KilnCMSWeb, :html

  # The fields the SEO suggestion writes if the author accepts it.
  # `maybe_sync_slug/3` can also move `slug` off a `seo_keywords` accept, but
  # only while the slug is still auto-derived — a grant that withholds `slug`
  # from an editor who may edit the keywords is not a reason to withhold the
  # suggestion, so it is deliberately not required here.
  @seo_suggestion_fields ~w(seo_title seo_description seo_keywords)

  # Stable per-collaborator colors for live focus cursors. Static class strings
  # so Tailwind keeps them.
  @cursor_colors ~w(
    bg-rose-500 bg-amber-500 bg-emerald-500 bg-sky-500 bg-violet-500 bg-pink-500
  )

  # Re-exported so `may_write_fields?` checks and the suggestion panel read the
  # same canonical field list.
  def seo_suggestion_fields, do: @seo_suggestion_fields

  # Current ids for a (possibly unloaded) relationship list.
  def current_ids(records) when is_list(records), do: Enum.map(records, & &1.id)
  def current_ids(_), do: []

  # Selected values for a multi-select: the in-progress form value once the user
  # has touched it, otherwise the record's currently-linked ids. Without this
  # fallback an untouched submit would send an empty list and wipe the links.
  def selected_ids(form, field, fallback) do
    case form[field].value do
      nil -> fallback
      list when is_list(list) -> list
      other -> [other]
    end
  end

  # Which tags the picker should show ticked, as a MapSet of id strings.
  #
  # Two shapes reach it, which is why this is not just `selected_ids/3` (#638).
  # While editing, the form carries `tag_ids` — the raw checkbox state from the
  # last `validate`. But a **failed submit** leaves the form holding what Save
  # sent, and Save sends the merge verbs instead. Reading only `tag_ids` there
  # would fall through to the persisted tags and silently roll every unsaved
  # tick back, on the one screen where the editor is already being told to fix
  # something else.
  def selected_tag_ids(form, record) do
    attached = record.tags |> current_ids() |> MapSet.new(&to_string/1)

    case form[:tag_ids].value do
      nil -> apply_merge_verbs(form, attached)
      value -> value |> List.wrap() |> MapSet.new(&to_string/1)
    end
  end

  defp apply_merge_verbs(form, attached) do
    added = form |> merge_verb_ids(:add_tag_ids) |> MapSet.new()
    removed = form |> merge_verb_ids(:remove_tag_ids) |> MapSet.new()

    attached |> MapSet.union(added) |> MapSet.difference(removed)
  end

  defp merge_verb_ids(form, field) do
    form[field].value |> List.wrap() |> Enum.map(&to_string/1)
  end

  def version_label(version) do
    "#{version.version_action_name} · " <>
      Calendar.strftime(version.version_inserted_at, "%Y-%m-%d %H:%M")
  end

  def user_label(%{name: name}) when is_binary(name) and name != "", do: name
  def user_label(%{email: email}), do: to_string(email)

  def changeset_errors(%Phoenix.HTML.Form{source: source}), do: changeset_errors(source)
  def changeset_errors(%AshPhoenix.Form{source: source}), do: changeset_errors(source)
  def changeset_errors(%Ash.Changeset{errors: errors}), do: errors
  def changeset_errors(_other), do: []

  # Which fields the current draft actually proposes, in display order.
  def suggested_fields(nil), do: []

  def suggested_fields(draft) do
    Enum.filter(@seo_suggestion_fields, &(suggested_value(draft, &1) not in [nil, ""]))
  end

  def suggested_value(nil, _field), do: nil
  def suggested_value(draft, "seo_title"), do: draft.seo_title
  def suggested_value(draft, "seo_description"), do: draft.seo_description

  def suggested_value(draft, "seo_keywords"),
    do: KilnCMS.Seo.Draft.keywords_string(draft)

  def suggested_value(_draft, _field), do: nil

  # Stamp each section with how many of its tags are currently ticked. The only
  # part of the picker that depends on the live form, and therefore the only
  # part recomputed per render.
  def with_counts(sections, selected) do
    Enum.map(sections, fn section ->
      Map.put(
        section,
        :selected_count,
        Enum.count(section.tags, &MapSet.member?(selected, &1.id))
      )
    end)
  end

  # Current value of one custom field, from the form's `custom_fields` map
  # (param value mid-edit, otherwise the record's stored value). Keys are always
  # strings (jsonb / form params).
  def custom_field_value(form, name) do
    case AshPhoenix.Form.value(form, :custom_fields) do
      map when is_map(map) -> Map.get(map, name)
      _ -> nil
    end
  end

  # Validation messages `ApplyCustomFields` attached for one definition — the
  # errors land on the `:custom_fields` attribute with the field's name in
  # `value`, so they'd otherwise never render anywhere (audit U-H2).
  def custom_field_errors(form, name) do
    form
    |> changeset_errors()
    |> Enum.filter(fn
      %Ash.Error.Changes.InvalidAttribute{field: :custom_fields, value: value} -> value == name
      _ -> false
    end)
    |> Enum.map(& &1.message)
  end

  def seo_field_label("seo_title"), do: gettext("SEO title")
  def seo_field_label("seo_description"), do: gettext("SEO description")
  def seo_field_label("seo_keywords"), do: gettext("SEO keywords")
  def seo_field_label(field), do: field

  def blank_to_nil(value) do
    case String.trim(to_string(value || "")) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def color_for(id),
    do: Enum.at(@cursor_colors, rem(:erlang.phash2(id), length(@cursor_colors)))

  # Hex twins of @cursor_colors (same order), for the CRDT caret labels —
  # TipTap's CollaborationCursor needs CSS color values, not Tailwind classes.
  @cursor_colors_hex ~w(#f43f5e #f59e0b #10b981 #0ea5e9 #8b5cf6 #ec4899)

  def color_hex_for(id),
    do: Enum.at(@cursor_colors_hex, rem(:erlang.phash2(id), length(@cursor_colors_hex)))

  # Up-to-two-letter initials from a display name ("Jane Doe" → "JD",
  # "editor" → "E"), for the roster chips and remote caret labels.
  def initials(nil), do: "?"

  def initials(name) do
    case name |> String.split(~r/\s+/, trim: true) |> Enum.take(2) do
      [] -> "?"
      words -> Enum.map_join(words, &(&1 |> String.first() |> String.upcase()))
    end
  end

  # Focus-tracking attributes for an input; `field` keys the cursor badge.
  # `phx-debounce` coalesces the per-keystroke `validate` events (and the
  # `broadcast_preview/1` they trigger) so fast typing with a pop-out preview
  # open doesn't flood PubSub / LiveView diffing.
  def field_attrs(field) do
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
  def locked_fields(cursors, self_field, self_id) do
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
  def locked_fields(socket),
    do:
      locked_fields(
        socket.assigns.cursors,
        socket.assigns.self_field,
        socket.assigns.actor.id
      )

  def field_locked?(locked, field), do: MapSet.member?(locked, field)

  def lock_ring(locked, field) do
    if field_locked?(locked, field), do: "rounded-md ring-2 ring-warning/50", else: ""
  end

  def dsl_label(name), do: name |> to_string() |> Phoenix.Naming.humanize()

  attr :field, :string, required: true
  attr :cursors, :map, required: true

  # Floating badges naming the collaborators currently focused on `field`.
  def field_cursors(assigns) do
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

  # Safe `src` for the image-block preview: a pasted URL is untrusted, so it must
  # clear the same scheme allowlist as delivery before we echo it back. Returns
  # nil (image hidden) for rejected schemes like `javascript:`/`data:`.
  def safe_preview_src(url), do: KilnCMS.HTMLSanitizer.safe_image_src(url)
end
