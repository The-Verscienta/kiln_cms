defmodule KilnCMSWeb.FormBuilderLive do
  @moduledoc """
  The visual form builder (`/editor/forms/:id`, admin-only): a field palette,
  a live canvas rendering the exact public-form markup
  (`BlockComponents.public_form_field/1`), and an options panel for editing the
  selected field in place — the WPForms/Formidable builder model
  (see `docs/form-builder-plan.md`, phase 1).

  Fields are added from the palette, reordered by drag (the shared `Sortable`
  hook persists `position`), and edited live via the options panel. Form-level
  settings live in tabs alongside the canvas: General, Notifications,
  Confirmations, Embed, and Entries (recent submissions).
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FormField
  alias KilnCMS.Forms.Autoresponder
  alias KilnCMS.Forms.EmbedPolicy

  import KilnCMSWeb.BlockComponents, only: [public_form_field: 1, field_width_class: 1]

  @tabs %{
    "fields" => :fields,
    "general" => :general,
    "notifications" => :notifications,
    "confirmations" => :confirmations,
    "embed" => :embed,
    "entries" => :entries
  }

  # The options panel's inputs (`field[<key>]`) and the attribute each edits.
  # A change event saves only the input it names (`_target`), so one refused
  # value never blocks edits to the others (#2139).
  @field_keys %{
    "label" => :label,
    "name" => :name,
    "field_type" => :field_type,
    "width" => :width,
    "required" => :required,
    "options" => :options,
    "placeholder" => :placeholder,
    "default_value" => :default_value,
    "help_text" => :help_text,
    "min_value" => :min_value,
    "max_value" => :max_value,
    "step" => :step
  }

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    actor = socket.assigns.current_user

    case CMS.get_form(id, actor: actor, tenant: socket.assigns.current_org) do
      {:ok, form} ->
        {:ok,
         socket
         |> assign(:actor, actor)
         |> assign(:form, form)
         |> assign(:page_title, form.name)
         |> assign(:tab, :fields)
         |> select_field(nil)
         |> assign(:submissions, [])
         # Entries moderation (#477): nil = every status; a submission id set
         # for the bulk mark actions, cleared on every filter change or reload
         # so a stale selection can't act on rows no longer in view.
         |> assign(:status_filter, nil)
         |> assign(:selected_submissions, MapSet.new())
         # The Embed tab's origins box as last typed, kept only while a save is
         # being refused (#648); nil means "render what is stored".
         |> assign(:embed_origins_draft, nil)
         |> assign(
           :challenge_available,
           KilnCMS.Challenge.forms_available?(KilnCMS.Challenge.config())
         )
         |> assign_embed_policy(form)
         |> reload_fields()}

      {:error, _error} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("That form doesn't exist."))
         |> push_navigate(to: ~p"/editor/forms")}
    end
  end

  # The palette: every field type with a friendly label + icon. A function
  # (not an attribute) so gettext resolves per-request locale.
  defp palette do
    [
      %{type: :string, label: gettext("Single line text"), icon: "hero-pencil"},
      %{type: :text, label: gettext("Paragraph text"), icon: "hero-bars-3-bottom-left"},
      %{type: :email, label: gettext("Email"), icon: "hero-at-symbol"},
      %{type: :integer, label: gettext("Number"), icon: "hero-hashtag"},
      %{type: :boolean, label: gettext("Checkbox"), icon: "hero-check-circle"},
      %{type: :date, label: gettext("Date"), icon: "hero-calendar"},
      %{type: :select, label: gettext("Dropdown"), icon: "hero-chevron-up-down"},
      %{type: :radio, label: gettext("Radio buttons"), icon: "hero-stop-circle"},
      %{type: :checkboxes, label: gettext("Checkbox group"), icon: "hero-list-bullet"},
      %{type: :phone, label: gettext("Phone"), icon: "hero-phone"},
      %{type: :url, label: gettext("Web address"), icon: "hero-link"},
      %{type: :number, label: gettext("Number (range)"), icon: "hero-calculator"},
      %{type: :rating, label: gettext("Rating"), icon: "hero-star"},
      %{type: :hidden, label: gettext("Hidden field"), icon: "hero-eye-slash"}
    ]
  end

  # Types whose value is picked from `options`.
  @choice_types [:select, :radio, :checkboxes]

  # Types with no free-text input to put a placeholder in.
  defp no_placeholder?(type),
    do: type in [:boolean, :select, :radio, :checkboxes, :rating, :hidden]

  defp starter_options, do: [gettext("Option 1"), gettext("Option 2")]

  # --- tabs --------------------------------------------------------------------

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) when is_binary(tab) do
    tab = Map.get(@tabs, tab, :fields)
    socket = assign(socket, :tab, tab)
    socket = if tab == :entries, do: reload_submissions(socket), else: socket
    {:noreply, socket}
  end

  # --- fields ------------------------------------------------------------------

  def handle_event("add_field", %{"type" => type}, socket) when is_binary(type) do
    fields = socket.assigns.fields
    entry = Enum.find(palette(), &(Atom.to_string(&1.type) == type))

    if entry do
      attrs = %{
        form_id: socket.assigns.form.id,
        name: unique_name(Atom.to_string(entry.type), fields),
        label: entry.label,
        field_type: entry.type,
        options: if(entry.type in @choice_types, do: starter_options(), else: []),
        position: next_position(fields)
      }

      case CMS.create_form_field(attrs, actor_opts(socket)) do
        {:ok, field} ->
          {:noreply, socket |> reload_fields() |> select_field(field.id)}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, error_message(error))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_field", %{"id" => id}, socket) when is_binary(id) do
    if Enum.any?(socket.assigns.fields, &(&1.id == id)) do
      {:noreply, select_field(socket, id)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("deselect_field", _params, socket) do
    {:noreply, select_field(socket, nil)}
  end

  # Both the panel's `phx-change` and its `phx-submit` (the Save button, or
  # Enter in any of its inputs) land here. A change event names the one input
  # that changed in `_target` and saves only that; a submit carries no target
  # and saves the whole panel.
  def handle_event("update_field", %{"field" => %{"id" => id} = params} = event, socket)
      when is_binary(id) do
    case Enum.find(socket.assigns.fields, &(&1.id == id)) do
      nil -> {:noreply, socket}
      field -> {:noreply, save_field(socket, field, edited_params(params, event["_target"]))}
    end
  end

  def handle_event("duplicate_field", %{"id" => id}, socket) when is_binary(id) do
    fields = socket.assigns.fields

    case Enum.find(fields, &(&1.id == id)) do
      nil -> {:noreply, socket}
      field -> copy_field(socket, field, fields)
    end
  end

  def handle_event("delete_field", %{"id" => id}, socket) when is_binary(id) do
    with %FormField{} = field <- Enum.find(socket.assigns.fields, &(&1.id == id)),
         # A refusal (the autoresponder still names the field, #2343) must
         # say why the field is still there.
         {:error, error} <- CMS.destroy_form_field(field, actor_opts(socket)) do
      {:noreply, put_flash(socket, :error, error_message(error))}
    else
      _deleted_or_unknown ->
        socket = reload_fields(socket)

        if socket.assigns.selected_id == id,
          do: {:noreply, select_field(socket, nil)},
          else: {:noreply, socket}
    end
  end

  # Pushed by the Sortable hook with the canvas' new data-sort-id order.
  def handle_event("reorder", %{"order" => order}, socket) when is_list(order) do
    {:noreply, socket |> apply_order(order) |> reload_fields()}
  end

  # --- form settings -----------------------------------------------------------

  def handle_event("save_form", %{"form" => params}, socket) when is_map(params) do
    with {:ok, attrs} <- form_params(params),
         {:ok, form} <- CMS.update_form(socket.assigns.form, attrs, actor_opts(socket)) do
      {:noreply,
       socket
       |> assign(:form, form)
       |> assign(:embed_origins_draft, nil)
       |> assign_embed_policy(form)
       |> assign(:page_title, form.name)
       |> put_flash(:info, gettext("Saved."))}
    else
      {:error, message} when is_binary(message) ->
        {:noreply, socket |> keep_embed_draft(params) |> put_flash(:error, message)}

      {:error, error} ->
        {:noreply, socket |> keep_embed_draft(params) |> put_flash(:error, error_message(error))}
    end
  end

  # --- submissions (moderation, #477) ------------------------------------------

  def handle_event("delete_submission", %{"id" => id}, socket) when is_binary(id) do
    opts = actor_opts(socket)

    with {:ok, submission} <- CMS.get_form_submission(id, opts) do
      CMS.destroy_form_submission(submission, opts)
    end

    # A row deleted by its own trash icon (not bulk-delete, which doesn't
    # exist yet) can be one a checkbox had selected — drop it so the "N
    # selected" bar doesn't count a row that's gone, and a later bulk action
    # doesn't silently no-op trying to find it.
    selected = MapSet.delete(socket.assigns.selected_submissions, id)

    {:noreply, socket |> assign(:selected_submissions, selected) |> reload_submissions()}
  end

  def handle_event("filter_status", %{"status" => status}, socket) when is_binary(status) do
    {:noreply,
     socket
     |> assign(:status_filter, parse_status(status))
     |> assign(:selected_submissions, MapSet.new())
     |> reload_submissions()}
  end

  def handle_event("toggle_select", %{"id" => id}, socket) when is_binary(id) do
    selected = socket.assigns.selected_submissions

    updated =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, :selected_submissions, updated)}
  end

  def handle_event("select_all_visible", _params, socket) do
    ids = socket.assigns.submissions |> Enum.map(& &1.id) |> MapSet.new()
    {:noreply, assign(socket, :selected_submissions, ids)}
  end

  def handle_event("clear_selection", _params, socket),
    do: {:noreply, assign(socket, :selected_submissions, MapSet.new())}

  def handle_event("mark_submission_spam", %{"id" => id}, socket) when is_binary(id),
    do: {:noreply, mark(socket, [id], :mark_form_submission_spam)}

  def handle_event("mark_submission_reviewed", %{"id" => id}, socket) when is_binary(id),
    do: {:noreply, mark(socket, [id], :mark_form_submission_reviewed)}

  def handle_event("bulk_mark_spam", _params, socket),
    do:
      {:noreply,
       mark(
         socket,
         MapSet.to_list(socket.assigns.selected_submissions),
         :mark_form_submission_spam
       )}

  def handle_event("bulk_mark_reviewed", _params, socket) do
    {:noreply,
     mark(
       socket,
       MapSet.to_list(socket.assigns.selected_submissions),
       :mark_form_submission_reviewed
     )}
  end

  # --- embed -------------------------------------------------------------------

  def handle_event("copied", _params, socket),
    do: {:noreply, put_flash(socket, :info, gettext("Embed code copied to clipboard."))}

  # The form's public page (#2138), on the org's own host like the snippet.
  defp public_url(form, org), do: KilnCMSWeb.Tenant.base_url(org) <> "/forms/" <> form.slug

  # The one-line snippet an embedder pastes on their site (see `/embed.js`) —
  # on the org's own host (#557); shared with the forms list.
  defp embed_snippet(slug, org), do: KilnCMSWeb.Embed.form_snippet(slug, org)

  # Since #562 the shipped default is same-origin only, so a copied snippet on a
  # third-party page renders blank until an origin is allowed. Say so here —
  # otherwise the only signal is a console CSP violation on someone else's site.
  #
  # One value, not a boolean and a label: it is the policy that will actually be
  # served for *this* form (#648), and `nil` is how "nobody but this site" is
  # spelled. Computed once when `:form` is assigned rather than per render,
  # since building it scans the allowlist.
  #
  # `EmbedPolicy.effective/1` first, so a form with no list of its own shows
  # its org's configured default here too (#1131) — otherwise this panel would
  # tell an admin their form is closed while the served response is actually
  # governed by an org-wide allowlist nobody here can see.
  defp assign_embed_policy(socket, form) do
    label = form |> EmbedPolicy.effective() |> KilnCMSWeb.Embed.allowed_origins_label()
    assign(socket, :embed_origins_label, label)
  end

  # The Embed tab edits `embed_origins` as one line of origins, with a radio for
  # which of its three states is meant — `nil` (inherit the deployment's
  # `EMBED_ORIGINS`) and `[]` (same-origin only, whatever the deployment allows)
  # render identically as an empty box, so the box alone cannot say which was
  # intended. Classified by `KilnCMSWeb.Embed`, the one place that reads the
  # attribute's shape, rather than by a fourth copy of the tri-state here.
  defp embed_mode(form) do
    case KilnCMSWeb.Embed.own_origins(form) do
      :deployment -> "inherit"
      [] -> "closed"
      _list -> "list"
    end
  end

  defp embed_origins_value(%{embed_origins: origins}) when is_list(origins),
    do: Enum.join(origins, ", ")

  defp embed_origins_value(_form), do: ""

  # A refused save must not empty the box. The origins are one field holding a
  # whole list, so re-rendering the stored value would make the admin retype
  # every entry to fix the one the error names.
  defp keep_embed_draft(socket, %{"embed_origins" => raw}) when is_binary(raw),
    do: assign(socket, :embed_origins_draft, raw)

  defp keep_embed_draft(socket, _params), do: socket

  # Only the Embed tab submits `embed_mode`, and only then is `embed_origins`
  # translated — every other tab posts its own subset and must leave the framing
  # policy exactly as it found it, so the key is dropped rather than trusted.
  #
  # Returns `{:ok, params}` or `{:error, message}`: the radio and the box can
  # contradict each other, and every way of resolving that silently gets the
  # admin's intent wrong. Typing a list under "use the deployment default" would
  # throw the list away; picking "only these sites" with an empty box would save
  # `[]`, which is *closed* — the opposite of the radio, and shown as the other
  # radio on the next render. Both are a refusal instead.
  defp form_params(%{"embed_mode" => mode} = params) do
    origins = KilnCMS.Config.OriginList.parse_list(params["embed_origins"])

    case {mode, origins} do
      {"inherit", []} ->
        {:ok, params |> Map.delete("embed_mode") |> Map.put("embed_origins", nil)}

      {"closed", []} ->
        {:ok, params |> Map.delete("embed_mode") |> Map.put("embed_origins", [])}

      {"list", [_ | _]} ->
        {:ok, params |> Map.delete("embed_mode") |> Map.put("embed_origins", origins)}

      {"list", []} ->
        {:error, gettext("Add at least one site to embed on, or choose “This site only”.")}

      {mode, [_ | _]} when mode in ["inherit", "closed"] ->
        {:error,
         gettext("Choose “Only these sites” to use the list you typed, or clear the box.")}

      _unknown_mode ->
        {:error, gettext("Something went wrong.")}
    end
  end

  defp form_params(params), do: {:ok, Map.delete(params, "embed_origins")}

  # --- submissions: moderation helpers (#477) -----------------------------------

  defp mark(socket, ids, action) do
    opts = actor_opts(socket)

    Enum.each(ids, fn id ->
      with {:ok, submission} <- CMS.get_form_submission(id, opts) do
        apply(CMS, action, [submission, %{}, opts])
      end
    end)

    socket |> assign(:selected_submissions, MapSet.new()) |> reload_submissions()
  end

  defp parse_status("all"), do: nil

  defp parse_status(status) when status in ~w(new reviewed spam),
    do: String.to_existing_atom(status)

  defp parse_status(_status), do: nil

  # A function (not an attribute) so gettext resolves per-request locale,
  # same reasoning as `palette/0`.
  defp status_filters do
    [
      {"all", gettext("All")},
      {"new", gettext("New")},
      {"reviewed", gettext("Reviewed")},
      {"spam", gettext("Spam")}
    ]
  end

  defp export_query(nil), do: []
  defp export_query(status), do: [status: status]

  # Same `bg-<tone>/15 text-<tone>-ink` convention as
  # `content_editor_live.ex`'s `state_badge_class/1` — the hand-authored kit
  # has no `.badge-*` classes, so a DaisyUI-named one here would render with
  # no styling at all.
  defp status_badge_class(:new), do: "bg-info/15 text-info-ink"
  defp status_badge_class(:reviewed), do: "bg-success/15 text-success-ink"
  defp status_badge_class(:spam), do: "bg-error/15 text-error-ink"

  defp status_label(:new), do: gettext("New")
  defp status_label(:reviewed), do: gettext("Reviewed")
  defp status_label(:spam), do: gettext("Spam")

  # What human verification decided for a submission (#2249).
  defp challenge_label(:passed), do: gettext("Verified")
  defp challenge_label(_held), do: gettext("Held")

  defp challenge_title(:passed), do: gettext("Passed the human-verification check.")
  defp challenge_title(:missing), do: gettext("Held: sent without completing the check.")

  defp challenge_title(:wrong_host),
    do: gettext("Held: the check was completed on a site this deployment doesn't serve.")

  defp challenge_title(:unavailable),
    do: gettext("Held: the verification service couldn't be reached.")

  # --- data --------------------------------------------------------------------

  defp copy_field(socket, field, fields) do
    attrs =
      field
      |> KilnCMS.Forms.copyable_field_attrs()
      |> Map.merge(%{
        form_id: field.form_id,
        name: unique_name(field.name, fields),
        position: field.position
      })

    case CMS.create_form_field(attrs, actor_opts(socket)) do
      {:ok, copy} ->
        # Slot the copy right after its original, then renumber everything.
        order = fields |> Enum.map(& &1.id) |> insert_after(field.id, copy.id)

        {:noreply, socket |> apply_order(order) |> reload_fields() |> select_field(copy.id)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  defp insert_after(ids, target, new_id),
    do: Enum.flat_map(ids, &if(&1 == target, do: [&1, new_id], else: [&1]))

  defp actor_opts(socket),
    do: [actor: socket.assigns.actor, tenant: socket.assigns.current_org]

  defp reload_fields(socket) do
    assign(
      socket,
      :fields,
      CMS.form_fields_for!(socket.assigns.form.id, actor_opts(socket))
    )
  end

  defp reload_submissions(socket) do
    submissions =
      CMS.recent_form_submissions!(
        socket.assigns.form.id,
        %{status: socket.assigns.status_filter},
        actor_opts(socket)
      )

    assign(socket, :submissions, submissions)
  end

  # Persist a full id ordering as 0-based positions, skipping no-op updates.
  defp apply_order(socket, order) do
    fields_by_id = Map.new(socket.assigns.fields, &{&1.id, &1})

    order
    |> Enum.with_index()
    |> Enum.each(fn {id, index} ->
      with %FormField{} = field <- fields_by_id[id],
           true <- field.position != index do
        CMS.update_form_field(field, %{position: index}, actor_opts(socket))
      end
    end)

    socket
  end

  defp next_position([]), do: 0
  defp next_position(fields), do: Enum.max_by(fields, & &1.position).position + 1

  # A machine name not yet taken on this form: `email`, `email_2`, `email_3`, …
  defp unique_name(base, fields) do
    taken = MapSet.new(fields, & &1.name)

    [base | Enum.map(2..1000, &"#{base}_#{&1}")]
    |> Enum.find(&(!MapSet.member?(taken, &1)))
  end

  # Options-panel params → update attrs. Options arrive newline-separated (only
  # while the textarea is rendered, i.e. the field is a select/radio/checkboxes).
  # The panel posts the inputs of the field's OLD type along with the new
  # `field_type`, so a type change drops what the new type can't carry
  # (range, default, options, placeholder) and seeds starter options when it
  # becomes a choice type — otherwise e.g. number -> rating would save a
  # `step` a rating rejects.
  defp field_params(params, field) do
    params = Map.drop(params, ["id", "_target"])

    params =
      case Map.fetch(params, "options") do
        {:ok, raw} ->
          Map.put(
            params,
            "options",
            raw |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
          )

        :error ->
          params
      end

    new_type = params["field_type"]

    if new_type in [nil, Atom.to_string(field.field_type)],
      do: params,
      else: retype_params(params, field, new_type)
  end

  defp retype_params(params, field, new_type) do
    entry = Enum.find(palette(), &(Atom.to_string(&1.type) == new_type))
    type = entry && entry.type

    params
    |> Map.merge(%{
      "min_value" => nil,
      "max_value" => nil,
      "step" => nil,
      "default_value" => nil,
      "options" => retyped_options(type, params["options"] || field.options)
    })
    |> then(fn params ->
      if no_placeholder?(type), do: Map.put(params, "placeholder", nil), else: params
    end)
    |> then(fn params ->
      if type == :hidden, do: Map.put(params, "required", "false"), else: params
    end)
  end

  defp retyped_options(type, options) when type in @choice_types,
    do: if(options in [nil, []], do: starter_options(), else: options)

  # A non-choice type keeps the stored options (the renderer and validation
  # ignore them), so switching back to a choice type restores the list instead
  # of reseeding it.
  defp retyped_options(_type, options), do: options || []

  # Opening, switching or closing the options panel starts it clean: a
  # refused value, its error and the last save's status belong to the field
  # they were typed for.
  defp select_field(socket, id) do
    socket
    |> assign(:selected_id, id)
    # Values the admin typed that were refused, by input key — rendered in
    # place of the stored value so a refusal never erases what was typed.
    |> assign(:field_draft, %{})
    # Inline error messages, by input key.
    |> assign(:field_errors, %{})
    # The panel's status line ("Saved.") and, after a rename, what it meant
    # for the form's entries and its autoresponder (one line each).
    |> assign(:field_status, nil)
    |> assign(:rename_notice, [])
  end

  # The inputs that render their own errors (`<.setting_errors>` below).
  @error_slots ~w(label name field_type options placeholder default_value help_text min_value max_value step)

  defp edited_params(params, ["field", key]) when is_map_key(@field_keys, key),
    do: Map.take(params, [key])

  defp edited_params(params, _target), do: Map.take(params, Map.keys(@field_keys))

  defp save_field(socket, field, params) do
    keys = Map.keys(params)

    case CMS.update_form_field(field, field_params(params, field), actor_opts(socket)) do
      {:ok, updated} ->
        # A new type changes which inputs exist (the options textarea is
        # select-only), so a draft or error held for one of them would come
        # back stale if the type switched back; drop them all.
        cleared = if "field_type" in keys, do: :all, else: keys

        socket
        |> assign(:field_draft, drop_keys(socket.assigns.field_draft, cleared))
        |> assign(:field_errors, drop_keys(socket.assigns.field_errors, cleared))
        |> note_saved(field, updated, keys)
        |> reload_fields()

      {:error, error} ->
        {slotted, unslotted} = Map.split(input_errors(error), @error_slots)

        # The typed values stay on screen beside the errors an input shows.
        socket =
          if slotted == %{},
            do: socket,
            else:
              socket
              |> assign(:field_draft, Map.merge(socket.assigns.field_draft, params))
              |> assign(
                :field_errors,
                socket.assigns.field_errors |> Map.drop(keys) |> Map.merge(slotted)
              )
              |> assign(:field_status, nil)

        # An error no input shows (a policy refusal, or an attribute without
        # an error slot such as width) must not vanish: say it in the flash.
        if slotted == %{} or unslotted != %{},
          do: put_flash(socket, :error, error_message(error)),
          else: socket
    end
  end

  defp drop_keys(_map, :all), do: %{}
  defp drop_keys(map, keys), do: Map.drop(map, keys)

  # Only a save that changed something says "Saved." — a debounce that sent
  # the value already stored is not news.
  defp note_saved(socket, field, updated, keys) do
    changed? =
      Enum.any?(keys, fn key ->
        attribute = Map.fetch!(@field_keys, key)
        Map.get(updated, attribute) != Map.get(field, attribute)
      end)

    cond do
      !changed? ->
        socket

      updated.name != field.name ->
        socket
        |> assign(:field_status, gettext("Saved."))
        |> note_rename(field.name, updated.name)

      true ->
        assign(socket, :field_status, gettext("Saved."))
    end
  end

  # What a rename meant beyond the field itself, said at the moment it
  # happens. One read of the form (as the admin) serves both lines, and becomes
  # `@form`: the rename rewrote the autoresponder's tokens in the stored
  # template (#2343), and a Confirmations tab still holding the old text would
  # show — and on its next save write back — a token for a field that no
  # longer exists.
  defp note_rename(socket, old_name, new_name) do
    opts = Keyword.put(actor_opts(socket), :load, [:submission_count])

    case CMS.get_form(socket.assigns.form.id, opts) do
      {:ok, form} ->
        notices = [
          entries_notice(form, old_name),
          autoresponder_notice(socket.assigns.form, form, old_name, new_name)
        ]

        socket
        |> assign(:form, form)
        |> assign(:rename_notice, Enum.reject(notices, &is_nil/1))

      {:error, _error} ->
        assign(socket, :rename_notice, [])
    end
  end

  # Entries already received are keyed by the name they were submitted under;
  # a rename does not rewrite them. Only on a form that has entries to strand.
  defp entries_notice(%{submission_count: count}, old_name)
       when is_integer(count) and count > 0 do
    # No count: `submission_count` includes entries received before this
    # field existed, which never carried the old key.
    gettext("Entries already received keep the old key “%{old}”.", old: old_name)
  end

  defp entries_notice(_form, _old_name), do: nil

  # Whether or not the form has entries: told by the template itself changing.
  defp autoresponder_notice(before, form, old_name, new_name) do
    if {before.autoresponder_subject, before.autoresponder_body} !=
         {form.autoresponder_subject, form.autoresponder_body} do
      gettext("The autoresponder now uses [field:%{new}] where it used [field:%{old}].",
        old: old_name,
        new: new_name
      )
    end
  end

  # A refused update as `%{input_key => [message]}`, through AshPhoenix's own
  # error protocol and `translate_error/1` (as the content editor does). The
  # `[:form_id, :name]` identity reports on `form_id`, which no input edits —
  # the name is what collided. Errors with no field (a policy refusal) map to
  # nothing and fall back to the flash.
  defp input_errors(error) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.flat_map(&field_error/1)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp field_error(error) do
    if AshPhoenix.FormData.Error.impl_for(error) do
      error
      |> AshPhoenix.FormData.Error.to_form_error()
      |> List.wrap()
      |> Enum.flat_map(fn
        {field, message, vars} when not is_nil(field) and is_binary(message) ->
          [{input_key(field), translate_error({message, error_vars(vars)})}]

        _other ->
          []
      end)
    else
      []
    end
  end

  defp input_key(:form_id), do: "name"
  defp input_key(field), do: to_string(field)

  defp error_vars(vars) when is_list(vars), do: vars
  defp error_vars(vars) when is_map(vars), do: Map.to_list(vars)
  defp error_vars(_vars), do: []

  # What an input shows: the refused value while one is held, else the stored one.
  defp shown(draft, key, stored), do: Map.get(draft, key, stored)

  defp invalid(errors, key), do: if(Map.has_key?(errors, key), do: "true")

  defp described_by(errors, key, hint_id \\ nil) do
    ids = [hint_id, Map.has_key?(errors, key) && "fs-#{key}-error"]

    case Enum.filter(ids, &is_binary/1) do
      [] -> nil
      ids -> Enum.join(ids, " ")
    end
  end

  # One submission's data split for the Entries tab: values under a current
  # field's name, in canvas order, and keys no current field has — left by a
  # renamed or removed field, shown raw rather than passed off as current.
  defp entry_rows(data, fields) when is_map(data) do
    names = MapSet.new(fields, & &1.name)
    current = for field <- fields, Map.has_key?(data, field.name), do: {field, data[field.name]}

    orphaned =
      data |> Enum.reject(fn {key, _value} -> key in names end) |> Enum.sort_by(&elem(&1, 0))

    {current, orphaned}
  end

  defp error_message(%{errors: errors}) when is_list(errors) and errors != [] do
    errors
    |> Enum.map_join("; ", fn
      # Splode interpolates an error's `vars` into its `%{…}` placeholders only
      # inside `Exception.message/1` — reading `.message` off the struct hands
      # the admin the raw template. That is how a refused CSP origin arrived as
      # a literal "%{value} is not an allowed CSP source", telling them a list
      # was wrong without telling them which entry (#648). `Exception.message/1`
      # names the field itself, so the prefix below is not repeated here.
      %{__exception__: true} = error -> Exception.message(error)
      %{field: field, message: message} when not is_nil(field) -> "#{field} #{message}"
      %{message: message} when is_binary(message) -> message
      other -> inspect(other)
    end)
  end

  defp error_message(_error), do: gettext("Something went wrong.")

  defp autoresponder_token_hint(form, fields) do
    Autoresponder.definitions(fields, form.name || "", false)
    |> Kiln.Tokens.names()
    |> Enum.map_join(", ", &"[#{&1}]")
  end

  defp tab_label(:fields), do: gettext("Fields")
  defp tab_label(:general), do: gettext("General")
  defp tab_label(:notifications), do: gettext("Notifications")
  defp tab_label(:confirmations), do: gettext("Confirmations")
  defp tab_label(:embed), do: gettext("Embed")
  defp tab_label(:entries), do: gettext("Entries")

  # An options-panel input's inline errors, under it; `id` matches the
  # input's `aria-describedby` (see `described_by/3`).
  attr :key, :string, required: true
  attr :errors, :map, required: true

  defp setting_errors(assigns) do
    ~H"""
    <div :if={Map.has_key?(@errors, @key)} id={"fs-#{@key}-error"} class="mt-1 space-y-0.5">
      <p :for={message <- @errors[@key]} class="flex items-start gap-1 text-xs text-error">
        <.icon name="hero-exclamation-circle" class="mt-px size-4 shrink-0" />{message}
      </p>
    </div>
    """
  end

  # --- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:forms}
    >
      <div class="space-y-4">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div class="min-w-0">
            <.link navigate={~p"/editor/forms"} class="text-sm text-base-content/60 hover:underline">
              &larr; {gettext("All forms")}
            </.link>
            <h1 class="mt-1 flex items-center gap-2 text-2xl font-semibold">
              <span class="truncate">{@form.name}</span>
              <span :if={!@form.active} class="rounded bg-base-200 px-1.5 py-0.5 text-xs font-normal">
                {gettext("Inactive")}
              </span>
            </h1>
            <%!-- The form's public page (#2138). Only an active form answers
                  there, so an inactive one says so instead of showing an
                  address that 404s. --%>
            <a
              :if={@form.active}
              id="form-public-url"
              href={public_url(@form, @current_org)}
              target="_blank"
              rel="noopener"
              class="break-all font-mono text-xs text-base-content/60 hover:underline"
            >
              {public_url(@form, @current_org)}
              <span class="sr-only">{gettext("(opens in a new tab)")}</span>
            </a>
            <p :if={!@form.active} id="form-public-url" class="text-xs text-base-content/60">
              {gettext("Not public while inactive.")}
            </p>
          </div>
          <a
            :if={@form.active}
            href={public_url(@form, @current_org)}
            target="_blank"
            rel="noopener"
            class="btn btn-sm btn-default"
          >
            {gettext("Preview")}
          </a>
        </div>

        <div
          id="form-builder-tabs"
          class="tabs flex-wrap"
          role="tablist"
          aria-label={gettext("Form sections")}
          phx-hook="TabKeys"
        >
          <button
            :for={tab <- [:fields, :general, :notifications, :confirmations, :embed, :entries]}
            id={"form-builder-tab-#{tab}"}
            type="button"
            role="tab"
            class="tab"
            aria-selected={to_string(@tab == tab)}
            aria-controls={@tab == tab && "form-builder-panel"}
            tabindex={if @tab == tab, do: "0", else: "-1"}
            phx-click="set_tab"
            phx-value-tab={tab}
          >
            {tab_label(tab)}
          </button>
        </div>

        <div
          id="form-builder-panel"
          role="tabpanel"
          aria-labelledby={"form-builder-tab-#{@tab}"}
          tabindex="0"
          class="focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-primary rounded"
        >
          <div :if={@tab == :fields} class="grid gap-4 lg:grid-cols-[13rem_minmax(0,1fr)_19rem]">
            <%!-- Palette: click a type to append it to the form. --%>
            <aside class="card card-pad h-fit space-y-1" aria-label={gettext("Add a field")}>
              <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
                {gettext("Add a field")}
              </h2>
              <button
                :for={entry <- palette()}
                type="button"
                phx-click="add_field"
                phx-value-type={entry.type}
                class="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-sm hover:bg-base-200"
              >
                <.icon name={entry.icon} class="size-4 text-base-content/60" />
                {entry.label}
              </button>
            </aside>

            <%!-- Canvas: the real public-form markup, one selectable card per field. --%>
            <section class="card card-pad" aria-label={gettext("Form preview")}>
              <p :if={@form.description} class="mb-3 text-sm text-base-content/70">
                {@form.description}
              </p>

              <p
                :if={@fields == []}
                class="rounded border border-dashed border-base-300 p-6 text-center text-sm text-base-content/60"
              >
                {gettext("No fields yet — add one from the palette.")}
              </p>

              <div
                id="builder-canvas"
                phx-hook="Sortable"
                class="grid grid-cols-1 gap-3 sm:grid-cols-6"
              >
                <div
                  :for={field <- @fields}
                  data-sort-id={field.id}
                  class={[
                    field_width_class(field),
                    "group relative rounded-lg border p-3",
                    @selected_id == field.id && "border-primary ring-1 ring-primary",
                    @selected_id != field.id && "border-base-300 hover:border-primary/40"
                  ]}
                >
                  <button
                    type="button"
                    phx-click="select_field"
                    phx-value-id={field.id}
                    aria-label={gettext("Edit field %{label}", label: field.label)}
                    class="absolute inset-0 z-[5] cursor-pointer rounded-lg"
                  ></button>

                  <div class={[
                    "absolute -top-2.5 right-2 z-10 gap-0.5 rounded border border-base-300 bg-base-100 px-0.5 shadow-sm",
                    @selected_id == field.id && "flex",
                    @selected_id != field.id && "hidden group-hover:flex"
                  ]}>
                    <button
                      type="button"
                      data-drag-handle
                      aria-label={gettext("Reorder field %{label}", label: field.label)}
                      class="cursor-grab active:cursor-grabbing p-1 text-base-content/60 hover:text-base-content"
                    >
                      <.icon name="hero-arrows-up-down" class="size-3.5" />
                    </button>
                    <button
                      type="button"
                      phx-click="duplicate_field"
                      phx-value-id={field.id}
                      aria-label={gettext("Duplicate field %{label}", label: field.label)}
                      class="p-1 text-base-content/60 hover:text-base-content"
                    >
                      <.icon name="hero-square-2-stack" class="size-3.5" />
                    </button>
                    <button
                      type="button"
                      phx-click="delete_field"
                      phx-value-id={field.id}
                      data-confirm={gettext("Delete this field?")}
                      aria-label={gettext("Delete field %{label}", label: field.label)}
                      class="p-1 text-base-content/60 hover:text-error"
                    >
                      <.icon name="hero-trash" class="size-3.5" />
                    </button>
                  </div>

                  <fieldset disabled class="pointer-events-none select-none">
                    <.public_form_field field={field} />
                  </fieldset>
                  <%!-- A hidden input draws nothing, so the card would be blank. --%>
                  <p :if={field.field_type == :hidden} class="text-sm text-base-content/70">
                    <.icon name="hero-eye-slash" class="size-4 align-text-bottom" />
                    {gettext("Hidden field — %{label}", label: field.label)}
                  </p>
                  <%!-- The key entries are stored under — so a rename shows here. --%>
                  <p
                    id={"canvas-field-name-#{field.id}"}
                    class="mt-1 font-mono text-xs text-base-content/50"
                  >
                    {field.name}
                  </p>
                </div>
              </div>

              <div :if={@fields != []} class="mt-4">
                <button
                  type="button"
                  disabled
                  class="rounded bg-primary px-4 py-2 text-sm font-medium text-primary-content opacity-70"
                >
                  {@form.submit_label || gettext("Submit")}
                </button>
              </div>
            </section>

            <%!-- Options panel: edit the selected field in place. --%>
            <aside class="card card-pad h-fit" aria-label={gettext("Field settings")}>
              <% selected = Enum.find(@fields, &(&1.id == @selected_id)) %>
              <p :if={!selected} class="text-sm text-base-content/60">
                {gettext("Select a field on the canvas to edit it, or add one from the palette.")}
              </p>

              <div :if={selected} class="space-y-3">
                <div class="flex items-center justify-between gap-2">
                  <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
                    {gettext("Field settings")}
                  </h2>
                  <button
                    type="button"
                    phx-click="deselect_field"
                    aria-label={gettext("Close field settings")}
                    class="text-base-content/70 hover:text-base-content"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </div>

                <form
                  id={"field-settings-#{selected.id}"}
                  phx-change="update_field"
                  phx-submit="update_field"
                  class="space-y-3 text-sm"
                >
                  <input type="hidden" name="field[id]" value={selected.id} />

                  <div>
                    <label for="fs-label" class="font-medium">{gettext("Label")}</label>
                    <input
                      id="fs-label"
                      name="field[label]"
                      value={shown(@field_draft, "label", selected.label)}
                      phx-debounce="300"
                      aria-invalid={invalid(@field_errors, "label")}
                      aria-describedby={described_by(@field_errors, "label")}
                      class="field-input mt-1"
                    />
                    <.setting_errors key="label" errors={@field_errors} />
                  </div>

                  <div>
                    <label for="fs-name" class="font-medium">{gettext("Machine name")}</label>
                    <input
                      id="fs-name"
                      name="field[name]"
                      value={shown(@field_draft, "name", selected.name)}
                      phx-debounce="blur"
                      aria-invalid={invalid(@field_errors, "name")}
                      aria-describedby={described_by(@field_errors, "name", "fs-name-hint")}
                      class="field-input mt-1 font-mono text-xs"
                    />
                    <.setting_errors key="name" errors={@field_errors} />
                    <p id="fs-name-hint" class="mt-1 text-xs text-base-content/60">
                      {gettext(
                        "Keys this field's value in submissions. Entries already received keep the old key: the Entries tab and CSV export show it as a renamed field; API clients and webhooks use the new name from now on. The autoresponder's [field:…] tokens follow the rename."
                      )}
                    </p>
                  </div>

                  <div class="grid grid-cols-2 gap-2">
                    <div>
                      <label for="fs-type" class="font-medium">{gettext("Type")}</label>
                      <select
                        id="fs-type"
                        name="field[field_type]"
                        aria-invalid={invalid(@field_errors, "field_type")}
                        aria-describedby={described_by(@field_errors, "field_type")}
                        class="field-select mt-1"
                      >
                        <option
                          :for={entry <- palette()}
                          value={entry.type}
                          selected={
                            to_string(entry.type) ==
                              to_string(shown(@field_draft, "field_type", selected.field_type))
                          }
                        >
                          {entry.label}
                        </option>
                      </select>
                      <.setting_errors key="field_type" errors={@field_errors} />
                    </div>
                    <div>
                      <label for="fs-width" class="font-medium">{gettext("Width")}</label>
                      <select id="fs-width" name="field[width]" class="field-select mt-1">
                        <option value="full" selected={selected.width == :full}>
                          {gettext("Full")}
                        </option>
                        <option value="half" selected={selected.width == :half}>
                          {gettext("Half")}
                        </option>
                        <option value="third" selected={selected.width == :third}>
                          {gettext("Third")}
                        </option>
                      </select>
                    </div>
                  </div>

                  <label class="flex items-center gap-2">
                    <input type="hidden" name="field[required]" value="false" />
                    <input
                      type="checkbox"
                      name="field[required]"
                      value="true"
                      checked={selected.required}
                      class="size-4 rounded border border-base-content/30 accent-primary"
                    />
                    {gettext("Required")}
                  </label>

                  <div :if={selected.field_type in [:select, :radio, :checkboxes]}>
                    <label for="fs-options" class="font-medium">
                      {gettext("Options — one per line")}
                    </label>
                    <textarea
                      id="fs-options"
                      name="field[options]"
                      phx-debounce="300"
                      rows="4"
                      aria-invalid={invalid(@field_errors, "options")}
                      aria-describedby={described_by(@field_errors, "options")}
                      class="field-input mt-1 text-xs"
                    >{shown(@field_draft, "options", Enum.join(selected.options, "\n"))}</textarea>
                    <.setting_errors key="options" errors={@field_errors} />
                  </div>

                  <div :if={selected.field_type == :number} class="grid grid-cols-3 gap-2">
                    <div>
                      <label for="fs-min" class="font-medium">{gettext("Min")}</label>
                      <input
                        id="fs-min"
                        type="number"
                        step="any"
                        name="field[min_value]"
                        value={selected.min_value}
                        phx-debounce="300"
                        class="field-input mt-1"
                      />
                    </div>
                    <div>
                      <label for="fs-max" class="font-medium">{gettext("Max")}</label>
                      <input
                        id="fs-max"
                        type="number"
                        step="any"
                        name="field[max_value]"
                        value={selected.max_value}
                        phx-debounce="300"
                        class="field-input mt-1"
                      />
                    </div>
                    <div>
                      <label for="fs-step" class="font-medium">{gettext("Step")}</label>
                      <input
                        id="fs-step"
                        type="number"
                        step="any"
                        min="0"
                        name="field[step]"
                        value={selected.step}
                        phx-debounce="300"
                        class="field-input mt-1"
                      />
                    </div>
                  </div>

                  <div :if={selected.field_type == :rating}>
                    <label for="fs-stars" class="font-medium">{gettext("Stars")}</label>
                    <input
                      id="fs-stars"
                      type="number"
                      min="1"
                      max="10"
                      step="1"
                      name="field[max_value]"
                      value={selected.max_value && trunc(selected.max_value)}
                      placeholder="5"
                      phx-debounce="300"
                      class="field-input mt-1"
                    />
                  </div>

                  <div :if={!no_placeholder?(selected.field_type)}>
                    <label for="fs-placeholder" class="font-medium">{gettext("Placeholder")}</label>
                    <input
                      id="fs-placeholder"
                      name="field[placeholder]"
                      value={shown(@field_draft, "placeholder", selected.placeholder)}
                      phx-debounce="300"
                      aria-invalid={invalid(@field_errors, "placeholder")}
                      aria-describedby={described_by(@field_errors, "placeholder")}
                      class="field-input mt-1"
                    />
                    <.setting_errors key="placeholder" errors={@field_errors} />
                  </div>

                  <div>
                    <label for="fs-default" class="font-medium">{gettext("Default value")}</label>
                    <input
                      id="fs-default"
                      name="field[default_value]"
                      value={shown(@field_draft, "default_value", selected.default_value)}
                      phx-debounce="300"
                      aria-invalid={invalid(@field_errors, "default_value")}
                      aria-describedby={described_by(@field_errors, "default_value")}
                      class="field-input mt-1"
                    />
                    <.setting_errors key="default_value" errors={@field_errors} />
                    <p :if={selected.field_type == :boolean} class="mt-1 text-xs text-base-content/60">
                      {gettext("Use \"true\" to pre-check the box.")}
                    </p>
                  </div>

                  <div>
                    <label for="fs-help" class="font-medium">{gettext("Help text")}</label>
                    <input
                      id="fs-help"
                      name="field[help_text]"
                      value={shown(@field_draft, "help_text", selected.help_text)}
                      phx-debounce="300"
                      aria-invalid={invalid(@field_errors, "help_text")}
                      aria-describedby={described_by(@field_errors, "help_text")}
                      class="field-input mt-1"
                    />
                    <.setting_errors key="help_text" errors={@field_errors} />
                  </div>

                  <div class="flex items-center gap-3 border-t border-base-content/10 pt-3">
                    <button type="submit" class="btn btn-primary btn-sm">{gettext("Save")}</button>
                    <%!-- Always present, so assistive tech hears each new status
                         rather than a node that appeared and was missed. --%>
                    <p
                      id="field-settings-status"
                      role="status"
                      aria-live="polite"
                      class="min-w-0 text-xs text-base-content/70"
                    >
                      <span :if={@field_status} class="text-success-ink">{@field_status}</span>
                      <span :for={notice <- @rename_notice} class="block">{notice}</span>
                    </p>
                  </div>
                </form>
              </div>
            </aside>
          </div>

          <section :if={@tab == :general} class="card card-pad max-w-2xl">
            <form phx-submit="save_form" class="grid gap-3 sm:grid-cols-2">
              <div>
                <label for="gf-name" class="text-sm font-medium">{gettext("Name")}</label>
                <input
                  id="gf-name"
                  name="form[name]"
                  value={@form.name}
                  required
                  class="field-input mt-1"
                />
              </div>
              <div>
                <label for="gf-slug" class="text-sm font-medium">{gettext("Slug")}</label>
                <input
                  id="gf-slug"
                  name="form[slug]"
                  value={@form.slug}
                  required
                  class="field-input mt-1"
                />
              </div>
              <div class="sm:col-span-2">
                <label for="gf-description" class="text-sm font-medium">{gettext("Description")}</label>
                <textarea
                  id="gf-description"
                  name="form[description]"
                  rows="2"
                  class="field-input mt-1"
                >{@form.description}</textarea>
              </div>
              <div>
                <label for="gf-submit-label" class="text-sm font-medium">
                  {gettext("Submit button label")}
                </label>
                <input
                  id="gf-submit-label"
                  name="form[submit_label]"
                  value={@form.submit_label}
                  placeholder={gettext("Submit")}
                  class="field-input mt-1"
                />
              </div>
              <label class="flex items-center gap-2 self-end text-sm">
                <input type="hidden" name="form[active]" value="false" />
                <input
                  type="checkbox"
                  name="form[active]"
                  value="true"
                  checked={@form.active}
                  class="size-4 rounded border border-base-content/30 accent-primary"
                />
                {gettext("Active (accepting submissions)")}
              </label>
              <%!-- Human verification (#2249). While no form can ask for it the
                    box is disabled and not submitted at all, so a save of this
                    tab leaves the setting as it is — unless it is on, when it
                    stays editable so the admin can still switch it off (the
                    validation only refuses switching it on). --%>
              <div class="sm:col-span-2 space-y-1">
                <label class="flex items-center gap-2 text-sm">
                  <input
                    :if={@challenge_available or @form.challenge == :always}
                    type="hidden"
                    name="form[challenge]"
                    value="off"
                  />
                  <input
                    id="gf-challenge"
                    type="checkbox"
                    name="form[challenge]"
                    value="always"
                    checked={@form.challenge == :always}
                    disabled={!@challenge_available and @form.challenge != :always}
                    aria-describedby="gf-challenge-help"
                    class="size-4 rounded border border-base-content/30 accent-primary"
                  />
                  {gettext("Ask visitors to complete a human-verification check")}
                </label>
                <p
                  :if={!@challenge_available}
                  id="gf-challenge-help"
                  class="text-xs text-base-content/70"
                >
                  {gettext(
                    "Human verification isn't available on this deployment. Ask the operator to configure it."
                  )}
                </p>
                <p
                  :if={@challenge_available}
                  id="gf-challenge-help"
                  class="text-xs text-base-content/70"
                >
                  {gettext(
                    "Submissions without a completed check are kept in Spam for review instead of being sent on. Headless sites must send the check's token as _kiln_challenge, and their hostnames must be listed by the operator, or everything they send lands in Spam. Submissions from pages loaded before you switch this on also land in Spam."
                  )}
                </p>
              </div>
              <div class="sm:col-span-2">
                <.button type="submit" variant="primary">{gettext("Save")}</.button>
              </div>
            </form>
          </section>

          <section :if={@tab == :notifications} class="card card-pad max-w-2xl">
            <form phx-submit="save_form" class="space-y-3">
              <div>
                <label for="nf-email" class="text-sm font-medium">{gettext("Notify email")}</label>
                <input
                  id="nf-email"
                  name="form[notify_email]"
                  value={@form.notify_email}
                  placeholder="team@example.com"
                  class="field-input mt-1"
                />
                <p class="mt-1 text-xs text-base-content/60">
                  {gettext("Each submission is mailed here. Leave blank for no notification.")}
                </p>
              </div>
              <.button type="submit" variant="primary">{gettext("Save")}</.button>
            </form>
          </section>

          <section :if={@tab == :confirmations} class="card card-pad max-w-2xl">
            <form phx-submit="save_form" class="space-y-3">
              <div>
                <label for="cf-success" class="text-sm font-medium">{gettext("Success message")}</label>
                <input
                  id="cf-success"
                  name="form[success_message]"
                  value={@form.success_message}
                  class="field-input mt-1"
                />
                <p class="mt-1 text-xs text-base-content/60">
                  {gettext("Shown on the thank-you page after a successful submission.")}
                </p>
              </div>

              <hr class="border-t border-base-content/10" />

              <label class="flex items-center gap-2 text-sm">
                <input type="hidden" name="form[autoresponder_enabled]" value="false" />
                <input
                  type="checkbox"
                  name="form[autoresponder_enabled]"
                  value="true"
                  checked={@form.autoresponder_enabled}
                  class="size-4 rounded border border-base-content/30 accent-primary"
                />
                {gettext("Email the submitter a confirmation")}
              </label>
              <p class="text-xs text-base-content/60">
                {gettext("Only sends when the form has an email field and the visitor filled it in.")}
              </p>

              <div>
                <label for="cf-ar-subject" class="text-sm font-medium">{gettext("Subject")}</label>
                <input
                  id="cf-ar-subject"
                  name="form[autoresponder_subject]"
                  value={@form.autoresponder_subject}
                  placeholder={gettext("Thanks for reaching out, [field:name]!")}
                  class="field-input mt-1"
                />
              </div>
              <div>
                <label for="cf-ar-body" class="text-sm font-medium">{gettext("Body")}</label>
                <textarea
                  id="cf-ar-body"
                  name="form[autoresponder_body]"
                  rows="4"
                  class="field-input mt-1"
                >{@form.autoresponder_body}</textarea>
              </div>
              <p class="text-xs text-base-content/60">
                {gettext("Available tokens: %{tokens}",
                  tokens: autoresponder_token_hint(@form, @fields)
                )}
              </p>

              <.button type="submit" variant="primary">{gettext("Save")}</.button>
            </form>
          </section>

          <section :if={@tab == :embed} class="card card-pad max-w-2xl space-y-2">
            <label class="text-sm font-medium">{gettext("Embed on another site")}</label>

            <p :if={!@form.active} class="text-xs text-warning">
              {gettext(
                "This form is inactive — the embed shows “Form not found” until you activate it."
              )}
            </p>

            <p :if={is_nil(@embed_origins_label)} class="text-xs text-warning">
              {gettext(
                "Cross-site embedding is off: this form may only be framed by pages on its own site. List the sites that should be allowed to embed it below."
              )}
            </p>

            <p :if={@embed_origins_label} class="text-xs text-base-content/60">
              {gettext("Sites allowed to embed this form: %{origins}",
                origins: @embed_origins_label
              )}
            </p>

            <div class="flex items-center gap-2">
              <input
                type="text"
                value={embed_snippet(@form.slug, @current_org)}
                readonly
                aria-label={gettext("Embed code")}
                class="field-input min-w-0 flex-1 font-mono text-xs"
              />
              <button
                type="button"
                id="copy-embed-code"
                phx-hook="Clipboard"
                data-clipboard-text={embed_snippet(@form.slug, @current_org)}
                class="btn btn-sm btn-default shrink-0"
              >
                {gettext("Copy")}
              </button>
            </div>

            <p class="text-xs text-base-content/60">
              {gettext("The iframe sizes itself to the form.")}
            </p>

            <hr class="border-t border-base-content/10" />

            <form phx-submit="save_form" class="space-y-3">
              <fieldset class="space-y-1">
                <legend class="text-sm font-medium">{gettext("Who may embed this form")}</legend>
                <p class="text-xs text-base-content/60">
                  {gettext(
                    "This setting applies to this form only — another site's forms are unaffected by what you allow here."
                  )}
                </p>
                <%!-- #1133: the operator's ceiling. Says that one exists, never
                   what is in it — the list would enumerate other sites'
                   partners on a shared deployment (#1130). --%>
                <p :if={KilnCMS.Forms.EmbedCeiling.locked?()} class="text-xs text-base-content/60">
                  {gettext(
                    "The operator of this deployment has capped which sites may embed forms. You can narrow that list here but not add to it — ask them to allow a site that is refused."
                  )}
                </p>

                <label class="flex items-center gap-2 text-sm">
                  <input
                    type="radio"
                    name="form[embed_mode]"
                    value="inherit"
                    checked={embed_mode(@form) == "inherit"}
                    class="size-4 accent-primary"
                  />
                  {gettext("Use this site's default")}
                </label>

                <label class="flex items-center gap-2 text-sm">
                  <input
                    type="radio"
                    name="form[embed_mode]"
                    value="closed"
                    checked={embed_mode(@form) == "closed"}
                    class="size-4 accent-primary"
                  />
                  {gettext("This site only")}
                </label>

                <label class="flex items-center gap-2 text-sm">
                  <input
                    type="radio"
                    name="form[embed_mode]"
                    value="list"
                    checked={embed_mode(@form) == "list"}
                    class="size-4 accent-primary"
                  />
                  {gettext("Only these sites:")}
                </label>
              </fieldset>

              <input
                id="cf-embed-origins"
                name="form[embed_origins]"
                value={@embed_origins_draft || embed_origins_value(@form)}
                aria-label={gettext("Sites allowed to embed this form")}
                placeholder="https://example.com, https://blog.example.com"
                class="field-input font-mono text-xs"
              />
              <p class="text-xs text-base-content/60">
                {gettext(
                  "Comma-separated origins (scheme and host, optionally a port). Pages on this form's own site may always frame it."
                )}
              </p>

              <.button type="submit" variant="primary">{gettext("Save")}</.button>
            </form>
          </section>

          <section :if={@tab == :entries} class="max-w-3xl space-y-3">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <div role="group" aria-label={gettext("Filter by status")} class="flex gap-1">
                <button
                  :for={{value, label} <- status_filters()}
                  type="button"
                  phx-click="filter_status"
                  phx-value-status={value}
                  aria-pressed={to_string(@status_filter == parse_status(value))}
                  class={[
                    "rounded border px-2 py-1 text-xs",
                    if(@status_filter == parse_status(value),
                      do: "border-primary bg-primary text-primary-content",
                      else: "border-base-content/20 hover:bg-base-200"
                    )
                  ]}
                >
                  {label}
                </button>
              </div>

              <a
                href={
                  ~p"/editor/forms/#{@form.id}/entries/export.csv?#{export_query(@status_filter)}"
                }
                class="btn btn-default px-2 py-1 text-xs"
              >
                <.icon name="hero-arrow-down-tray" class="size-3.5" />{gettext("Export CSV")}
              </a>
            </div>

            <div
              :if={MapSet.size(@selected_submissions) > 0}
              class="flex items-center gap-2 rounded border border-base-content/15 bg-base-200/50 p-2 text-xs"
            >
              <span>
                {ngettext(
                  "%{count} selected",
                  "%{count} selected",
                  MapSet.size(@selected_submissions),
                  count: MapSet.size(@selected_submissions)
                )}
              </span>
              <button
                type="button"
                phx-click="bulk_mark_spam"
                class="btn btn-default px-2 py-0.5 text-xs"
              >
                {gettext("Mark as spam")}
              </button>
              <button
                type="button"
                phx-click="bulk_mark_reviewed"
                class="btn btn-default px-2 py-0.5 text-xs"
              >
                {gettext("Mark as reviewed")}
              </button>
              <button
                type="button"
                phx-click="clear_selection"
                class="btn-link text-base-content/60 underline hover:text-base-content"
              >
                {gettext("Clear")}
              </button>
            </div>

            <.empty_state
              :if={@submissions == []}
              id="form-submissions-empty"
              icon="hero-inbox-arrow-down"
              title={gettext("No submissions yet")}
              compact
            >
              {gettext("Entries appear here as soon as someone submits this form.")}
            </.empty_state>

            <button
              :if={@submissions != []}
              type="button"
              phx-click="select_all_visible"
              class="btn-link text-xs text-base-content/60 underline hover:text-base-content"
            >
              {gettext("Select all visible")}
            </button>

            <ul :if={@submissions != []} class="space-y-2">
              <li
                :for={submission <- @submissions}
                class="card rounded border border-base-content/10 p-3 text-sm"
              >
                <div class="flex items-center justify-between gap-2">
                  <div class="flex items-center gap-2">
                    <input
                      type="checkbox"
                      phx-click="toggle_select"
                      phx-value-id={submission.id}
                      checked={MapSet.member?(@selected_submissions, submission.id)}
                      aria-label={gettext("Select this submission")}
                      class="size-4 rounded border-base-content/30 accent-primary"
                    />
                    <span class={[
                      "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
                      status_badge_class(submission.status)
                    ]}>
                      {status_label(submission.status)}
                    </span>
                    <span :if={submission.spam_score > 0} class="text-xs text-base-content/50">
                      {gettext("score %{score}", score: submission.spam_score)}
                    </span>
                    <span
                      :if={submission.challenge}
                      class="inline-flex items-center rounded-full bg-base-content/10 px-2 py-0.5 text-xs font-medium text-base-content/70"
                      title={challenge_title(submission.challenge)}
                    >
                      {challenge_label(submission.challenge)}
                    </span>
                  </div>
                  <time
                    id={"submission-#{submission.id}"}
                    phx-hook="LocalTime"
                    datetime={DateTime.to_iso8601(submission.inserted_at)}
                    class="text-xs text-base-content/60"
                  >
                    {Calendar.strftime(submission.inserted_at, "%Y-%m-%d %H:%M")} UTC
                  </time>
                </div>
                <% {current, orphaned} = entry_rows(submission.data, @fields) %>
                <dl class="mt-1 grid gap-x-4 gap-y-0.5 sm:grid-cols-2">
                  <div :for={{field, value} <- current} class="flex gap-2">
                    <dt class="font-medium">
                      {field.label}
                      <span class="font-mono text-xs font-normal text-base-content/50">
                        {field.name}
                      </span>
                    </dt>
                    <dd class="min-w-0 break-words text-base-content/80">
                      {KilnCMS.Forms.display_value(value)}
                    </dd>
                  </div>
                </dl>
                <div
                  :if={orphaned != []}
                  id={"submission-#{submission.id}-orphaned"}
                  class="mt-2 rounded border border-dashed border-base-content/20 p-2"
                >
                  <p class="text-xs font-medium text-base-content/70">
                    {gettext("From a renamed or removed field")}
                  </p>
                  <dl class="mt-1 grid gap-x-4 gap-y-0.5 sm:grid-cols-2">
                    <div :for={{key, value} <- orphaned} class="flex gap-2">
                      <dt class="font-mono text-xs">{key}</dt>
                      <dd class="min-w-0 break-words text-base-content/80">
                        {KilnCMS.Forms.display_value(value)}
                      </dd>
                    </div>
                  </dl>
                </div>
                <div class="mt-2 flex items-center gap-2 text-xs">
                  <button
                    :if={submission.status != :spam}
                    type="button"
                    phx-click="mark_submission_spam"
                    phx-value-id={submission.id}
                    class="btn btn-default px-2 py-0.5 text-xs"
                  >
                    {gettext("Mark as spam")}
                  </button>
                  <button
                    :if={submission.status != :reviewed}
                    type="button"
                    phx-click="mark_submission_reviewed"
                    phx-value-id={submission.id}
                    class="btn btn-default px-2 py-0.5 text-xs"
                  >
                    {gettext("Mark as reviewed")}
                  </button>
                  <button
                    type="button"
                    phx-click="delete_submission"
                    phx-value-id={submission.id}
                    data-confirm={gettext("Delete this submission?")}
                    aria-label={gettext("Delete submission")}
                    class="ml-auto rounded p-1 hover:bg-base-200 hover:text-error"
                  >
                    <.icon name="hero-trash" class="size-3.5" />
                  </button>
                </div>
              </li>
            </ul>
          </section>
        </div>
      </div>
    </Layouts.console>
    """
  end
end
