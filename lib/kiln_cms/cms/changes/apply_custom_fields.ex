defmodule KilnCMS.CMS.Changes.ApplyCustomFields do
  @moduledoc """
  Coerces and validates a content record's `custom_fields` map against the
  `FieldDefinition` registry for its content type (the admin-UI-defined schema).

  Runs on create and whenever `custom_fields` changes. For each defined field it
  coerces the supplied value (or the field's default) to the declared type,
  enforces `required`, and checks `:select` membership — then writes back a
  cleaned map of JSON-native values (dates as ISO-8601 strings) so the jsonb
  column round-trips cleanly. Types beyond the built-ins dispatch to their
  registered `Kiln.FieldType`'s `cast/2` (see `KilnCMS.CMS.FieldTypes`). Definitions are
  read as `KilnCMS.CMS.Bookkeeping.system/0` (registry metadata, not user data),
  failing closed; `:media`/`:reference` targets are resolved as the caller.

  ## Partial updates merge; the payload is not the whole record

  On **update**, the supplied map is merged over the record's existing
  `custom_fields` with three-way, per-key semantics:

    * a key **present with a value** is coerced and written;
    * a key **present but blank** is cleared (or reset to its default);
    * a key **absent** from the payload keeps its stored value untouched.

  So an API/MCP client can `PATCH` a single field without resending the rest —
  omitting a field no longer silently wipes it. On **create** there is nothing
  to merge over, so absent fields fall to their defaults as before.

  The form editor is unaffected: it renders an input for every definition and
  submits the complete map (blank for empties), so every key is "present" and
  clearing a field by emptying it still works exactly as before.

  ## A key with no definition is refused, not quietly dropped

  The cleaned map is folded out of the *definitions*, so a key no
  `FieldDefinition` declares cannot be stored. What it used to do was vanish
  into a **successful** write: prose an editor typed came back `200 OK` and was
  simply not there, with nothing on any surface — response, log, editor — that
  said a key had been discarded.

  So a supplied key the registry does not know is now an **error** naming the
  key and listing the fields the type does define. Two shapes stay accepted,
  because neither is a value being lost: re-sending an undefined key with
  **exactly its stored value** (a client that reads a record, edits one field
  and writes the whole map back — its payload carries whatever the record
  already carries), and sending it **blank**, which asks for it to go.

  Machinery that copies a stored map wholesale — a version restore, a
  duplicate or translation, a content import — passes
  `context: %{custom_fields: :drop}`. Its payload is a whole map from
  *somewhere else*, which may legitimately hold keys this site never declared,
  and failing the copy over one would be a worse answer than dropping it. Those
  writes drop as before, but say so in the log rather than in silence.

  ## Nothing else should be left holding one

  Dropping is fold-shaped, not payload-shaped — and note what that does *not*
  mean. Since #329 a partial payload merges per key, so a **defined** key the
  caller left out is re-read from the record and written straight back; nothing
  about a one-field write endangers the other fields. The fold is over the
  *definitions*, so the only keys with nowhere to be re-read from are the ones
  the registry no longer declares.

  Which is enough to lose prose on an edit that had nothing to do with it. Any
  write touching `custom_fields` takes the stale keys with it, whether or not it
  mentions them — and on a type with a computed field, so does the refresh pass
  on a write that never mentions `custom_fields` at all. That lands hours or
  months after the definition it belonged to was deleted, on whoever happens to
  save next.

  Preserving those keys instead is not open to us — `custom_fields` is
  `public? true`, and #710 settled that deleting a definition must stop
  publishing its values, not leave them readable forever under a key nothing
  governs.

  What is fixed is the *window*: `KilnCMS.CMS.Changes.SyncFieldValues` keeps
  the stored keys in step with the registry, so destroying a `FieldDefinition`
  scrubs its key in the same breath (and renaming one *moves* the values, since
  a rename never asked for anything to be lost). The loss happens where an
  admin asked for it, instead of lying in wait for whoever next edits a title.
  A key that survives that — a row written by an older release — is dropped by
  the next write as it always was, now with a warning naming it, so the scrub
  is at least visible once.

  ## Computed fields are outside all of that

  A `:computed` definition (#429) has no editor-supplied value at all. Those
  fields resolve in a second pass, after the editable ones, from the document
  and the values just coerced — and the payload is never consulted, so posting
  a value under a computed field's key can't overwrite it.
  """
  use Ash.Resource.Change

  require Ash.Query
  require Logger

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.FieldDefinition

  @impl true
  def change(changeset, _opts, context) do
    # One date for every formula this write evaluates, and for the fire it
    # enqueues (`Computed.Context`, "Pinning today").
    changeset = KilnCMS.CMS.Computed.Context.pin_today(changeset)

    if changeset.action_type == :create or
         Ash.Changeset.changing_attribute?(changeset, :custom_fields) do
      apply_definitions(changeset, merge_base(changeset), mode(changeset), context)
    else
      # An update that never mentions `custom_fields` still has to refresh
      # computed fields: their inputs are the *document* — a retitled page
      # changes `{{ slugify(title) }}`, a reworded one changes reading time.
      refresh_computed(changeset)
    end
  end

  @doc """
  Run the registry pass over a `custom_fields` map a restore just force-changed
  onto the changeset (#710).

  A version restore folds the stored map in raw, in a `before_action`, so it
  never passes through `change/3` — leaving `:select` values outside a
  since-narrowed option list unchecked, `:media`/`:reference` ids unresolved
  (a trashed id sails past `featured_image_id`'s dangling-reference check),
  computed fields showing the pre-restore document's value, and keys for
  deleted definitions publicly readable again.

  It runs against an EMPTY base, not the record's current map: a restore is a
  wholesale replacement (the compare view reports a key added since the target
  as *added*), so a key absent from the restored map falls to its default — the
  record lands in a shape an ordinary save could also produce. Errors it raises
  (a now-dangling media id) fail the restore, the same stance
  `featured_image_id` already takes.

  It restores in `:drop` mode: a snapshot predates whatever definition was
  deleted since, and a restore must not fail over a key that was perfectly
  valid when it was written — nor reinstate one, which is the whole point of
  #710.
  """
  @spec apply_restored(Ash.Changeset.t(), Ash.Resource.Change.Context.t()) :: Ash.Changeset.t()
  def apply_restored(changeset, context), do: apply_definitions(changeset, %{}, :drop, context)

  # How this write treats a supplied `custom_fields` key no `FieldDefinition`
  # declares: `:strict` (the default) refuses it; `:drop` discards it with a
  # warning. Machinery that copies a stored map wholesale opts in via
  # `context: %{custom_fields: :drop}` — see the module doc.
  defp mode(changeset) do
    case changeset.context do
      %{custom_fields: :drop} -> :drop
      _other -> :strict
    end
  end

  # The base to merge the payload over. On create there is no record yet, so
  # absent fields fall to their defaults (empty base). On update we carry the
  # stored values forward, so a field the caller didn't mention is preserved
  # rather than dropped by the full-map rewrite. A restore passes `%{}` directly
  # (see `apply_restored/2`).
  defp merge_base(%{action_type: :create}), do: %{}
  defp merge_base(changeset), do: stringify_keys(changeset.data.custom_fields || %{})

  defp apply_definitions(changeset, existing, mode, context) do
    defs = definitions_for(changeset)

    # The writing org (epic #336). `:media`/`:reference` fields resolve a snapshot
    # by id under this tenant, so a value pointing at another site's media/content
    # simply won't resolve (nil under `global?: true` → a validation error rather
    # than a cross-org leak). Tenant-less writes (default org) resolve as before.
    #
    # And as the CALLER (#1659): the snapshot copies the target's title, slug,
    # url and alt text into this record, so resolving it under a bypass let an
    # editor who may not read a draft learn its title by referencing its id. A
    # target the caller cannot read resolves like a missing one — a validation
    # error, never a write.
    read_opts = context |> Ash.Context.to_opts() |> Keyword.put(:tenant, changeset.to_tenant)

    supplied = stringify_keys(Ash.Changeset.get_attribute(changeset, :custom_fields) || %{})

    # Computed fields (#429) are resolved in a second pass, after the editable
    # ones: their formulas reference sibling values, so they must see the
    # already-coerced results rather than raw params — and each other's, in
    # dependency order.
    {computed, editable} = Enum.split_with(defs, &(&1.field_type == :computed))

    {cleaned, errors} =
      Enum.reduce(editable, {%{}, []}, &accumulate(&1, supplied, existing, read_opts, &2))

    {cleaned, errors} = apply_computed(computed, changeset, cleaned, errors)

    {refused, dropped} = undefined(defs, supplied, existing, mode)
    errors = Enum.map(refused, &undefined_error(&1, defs)) ++ errors

    changeset
    |> Ash.Changeset.force_change_attribute(:custom_fields, cleaned)
    |> stash(defs)
    |> stash_supplied(supplied)
    |> note_dropped(dropped)
    |> then(fn cs -> Enum.reduce(errors, cs, &Ash.Changeset.add_error(&2, &1)) end)
  end

  # Split the keys no definition declares into the ones this write refuses and
  # the ones it drops. Neither is ever stored — the cleaned map is folded out of
  # the definitions — so the only question is whether the caller hears about it
  # as an error or as a log line.
  #
  # `:strict` refuses a supplied key, except when it merely re-states the value
  # already stored (a whole-map round-trip over a record that predates the
  # scrub) or is blank (asking for it to go). `:drop` refuses nothing. Stored
  # keys are always dropped: this write is rewriting the map either way, and
  # #710 forbids carrying a deleted definition's value forward.
  defp undefined(defs, supplied, existing, mode) do
    names = MapSet.new(defs, & &1.name)
    undefined? = &(not MapSet.member?(names, &1))

    stored = existing |> Map.keys() |> Enum.filter(undefined?)
    sent = supplied |> Map.keys() |> Enum.filter(undefined?)

    refused =
      if mode == :strict do
        Enum.reject(sent, fn key ->
          value = Map.get(supplied, key)
          blank?(value) or Map.get(existing, key) == value
        end)
      else
        []
      end

    {refused, Enum.uniq(stored ++ sent) -- refused}
  end

  # Say that a key was discarded — once, when the write actually runs.
  #
  # In a `before_action` rather than here, because `change/3` also runs on every
  # `AshPhoenix.Form.validate/2`: logging inline would put a line per keystroke
  # in the log for one record holding one stale key.
  defp note_dropped(changeset, []), do: changeset

  defp note_dropped(changeset, keys) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      Logger.warning(
        "custom_fields: dropped #{Enum.map_join(Enum.sort(keys), ", ", &inspect/1)} on " <>
          "#{inspect(changeset.resource)} — no FieldDefinition declares them"
      )

      changeset
    end)
  end

  # The computed-only path, for an update that changes the document but not
  # `custom_fields`. It deliberately does **not** re-run the editable pass: a
  # stored `:media`/`:reference` snapshot must not be re-resolved, and a
  # since-changed definition must not reject a value the caller never sent.
  #
  # This costs one indexed definitions read per content update. The attribute
  # is force-changed only when a computed value actually moved, so a write that
  # derives nothing new stays byte-identical to before — no spurious version
  # diff, no phantom "changed" attribute for anything downstream to react to.
  defp refresh_computed(changeset) do
    defs = definitions_for(changeset)
    changeset = stash(changeset, defs)

    case Enum.filter(defs, &(&1.field_type == :computed)) do
      [] -> changeset
      computed -> recompute(changeset, defs, computed)
    end
  end

  defp recompute(changeset, defs, computed) do
    stored =
      changeset.data.custom_fields
      |> Kernel.||(%{})
      |> stringify_keys()

    # Project onto the current definitions, as `apply_definitions/3` and
    # `Firing.CustomFields.resolve/2` both do. Carrying `stored` whole here
    # would let this path resurrect a key whose definition was deleted, and
    # would feed formulas a sibling value the other two paths no longer see —
    # three write paths giving three answers for one document.
    #
    # This is the path that made a *title edit* destroy a stale key, so it says
    # so. A record should not be in this state at all: `Changes.SyncFieldValues`
    # scrubs the key when the definition is destroyed and moves the values when
    # it is renamed, so what is left is a row written before that existed.
    {defined, undefined} = Map.split(stored, Enum.map(defs, & &1.name))

    editable = Map.drop(defined, Enum.map(computed, & &1.name))
    {cleaned, errors} = apply_computed(computed, changeset, editable, [])

    if cleaned == stored and errors == [] do
      changeset
    else
      changeset
      |> Ash.Changeset.force_change_attribute(:custom_fields, cleaned)
      |> note_dropped(Map.keys(undefined))
      |> then(fn cs -> Enum.reduce(errors, cs, &Ash.Changeset.add_error(&2, &1)) end)
    end
  end

  # Derive every computed field from the document plus the editable values just
  # resolved. The supplied payload is **not consulted**: a computed field is
  # read-only everywhere (editor, JSON:API, GraphQL, MCP), so whatever a client
  # posted under its key is discarded rather than trusted.
  #
  # A blank result simply skips the key — `required` is deliberately **not**
  # enforced here. There is no editor to require anything of: the input renders
  # read-only, so a formula that evaluates blank for a record would attach an
  # error nobody can clear, to *every* create and *every* update of that content
  # type, bricking it until an admin edits the definition.
  # `Validations.ComputeExpression` refuses `required` on a computed definition
  # up front so the option can't be set in the first place.
  defp apply_computed([], _changeset, cleaned, errors), do: {cleaned, errors}

  #
  # In dependency order (`Computed.derive/3`), so a formula over another
  # computed field sees the value it derives on this same write.
  defp apply_computed(defs, changeset, cleaned, errors) do
    context = KilnCMS.CMS.Computed.Context.from_changeset(changeset, cleaned)

    {KilnCMS.CMS.Computed.derive(defs, context, cleaned), errors}
  end

  # The definitions in scope: a compiled content type's (by its type atom) or,
  # on the generic entry tier, the owning dynamic type's (by definition id —
  # nil while the entry is still invalid means simply no custom fields yet).
  # Read under the writing org (epic #336) so a record only ever sees its own
  # site's field schema.
  #
  # As `KilnCMS.CMS.Bookkeeping.system/0` (#1659), not as the caller: this runs
  # on EVERY content update (the computed-field refresh), so its caller is
  # whoever wrote — an editor, the AshOban scheduler, a firing or search
  # worker. `FieldDefinition` admits the system actor to read (registry
  # metadata, not user data).
  #
  # FAIL CLOSED: `authorize_with: :error`. A refused read filters to `[]`, and
  # the cleaned map is folded out of the definitions — so "no definitions"
  # would drop every stored value on the record, skip every `required`, and
  # refuse every key the caller sent. A refusal raises instead.
  defp definitions_for(%{resource: resource} = changeset) do
    definitions(
      resource,
      Ash.Changeset.get_attribute(changeset, :type_definition_id),
      changeset.to_tenant
    )
  end

  @doc """
  The field definitions in scope for a record of `resource` on `tenant` — by
  its type atom, or on the generic entry tier by `type_definition_id` (`nil`
  there means no custom fields yet). The same system-actor, fail-closed read
  this change makes; public for `KilnCMS.CMS.SearchableFields`, which reads
  the same schema for a loaded record.
  """
  @spec definitions(module(), Ash.UUID.t() | nil, term()) :: [KilnCMS.CMS.FieldDefinition.t()]
  def definitions(resource, type_definition_id, tenant) do
    opts = [
      actor: KilnCMS.CMS.Bookkeeping.system(),
      authorize_with: :error,
      tenant: tenant
    ]

    if function_exported?(resource, :__kiln_dynamic_entry__, 0) do
      case type_definition_id do
        nil -> []
        id -> KilnCMS.CMS.field_definitions_for_definition!(id, opts)
      end
    else
      KilnCMS.CMS.field_definitions_for!(resource.__kiln_content_type__(), opts)
    end
  end

  @doc """
  The definitions this change read for `changeset`, if it ran — stashed in
  the changeset's context so `Changes.SetSearchText`, declared after it on
  every write that indexes, does not read them a second time.
  """
  @spec stashed_definitions(Ash.Changeset.t()) :: [KilnCMS.CMS.FieldDefinition.t()] | nil
  def stashed_definitions(changeset), do: changeset.context[:kiln_field_definitions]

  defp stash(changeset, defs),
    do: Ash.Changeset.set_context(changeset, %{kiln_field_definitions: defs})

  # The keys the caller actually sent, before the merge and the defaults
  # filled the rest in. `KilnCMS.I18n.Validations.SharedFieldsReadOnly` judges
  # only these: a default this change filled into a key the payload never
  # named is not a value the caller wrote (#1860).
  defp stash_supplied(changeset, supplied),
    do: Ash.Changeset.set_context(changeset, %{kiln_custom_fields_supplied: Map.keys(supplied)})

  @doc """
  The `custom_fields` keys the caller supplied on this write, if this change
  ran — `nil` when it did not.
  """
  @spec supplied_keys(Ash.Changeset.t()) :: [String.t()] | nil
  def supplied_keys(changeset), do: changeset.context[:kiln_custom_fields_supplied]

  # Resolve one definition's value and fold it into the {cleaned, errors} acc.
  # Three-way per key: a field the caller *supplied* is coerced/cleared; a field
  # they omitted keeps its `existing` stored value (the merge); a field with
  # neither falls to its default (fresh field / create).
  defp accumulate(def, supplied, existing, read_opts, {cleaned, errors}) do
    cond do
      Map.has_key?(supplied, def.name) ->
        fold(resolve(def, Map.get(supplied, def.name), read_opts), def, cleaned, errors)

      Map.has_key?(existing, def.name) ->
        # Untouched by this write: keep the stored (already-coerced) value as-is.
        # No re-coercion, so a stale reference/media snapshot isn't re-resolved
        # and a since-changed definition can't reject a value the caller never
        # sent.
        {Map.put(cleaned, def.name, Map.get(existing, def.name)), errors}

      true ->
        fold(resolve(def, nil, read_opts), def, cleaned, errors)
    end
  end

  defp fold(:skip, _def, cleaned, errors), do: {cleaned, errors}
  defp fold({:ok, value}, def, cleaned, errors), do: {Map.put(cleaned, def.name, value), errors}

  defp fold({:error, message}, def, cleaned, errors),
    do: {cleaned, [error(def, message) | errors]}

  # The coerced value for a definition from a supplied `raw` (or its default):
  # `:skip` when blank-and-optional, or an error when blank-and-required.
  defp resolve(def, raw, read_opts) do
    blank? = &blank_for?(def, &1)
    raw = if blank?.(raw), do: def.default, else: raw

    cond do
      blank?.(raw) and def.required -> {:error, "is required"}
      blank?.(raw) -> :skip
      true -> coerce(raw, def, read_opts)
    end
  end

  # Blankness, per field type. A **composite** type (one declaring
  # `input_parts/1`, e.g. `:geolocation`) submits a map of parts, and an
  # untouched widget submits a map of blanks — that is the field being empty.
  #
  # This must NOT apply to every map. `:media`/`:reference` accept an
  # unresolved payload like `%{"id" => ""}`, which is *invalid*, not absent:
  # treating it as blank silently clears the field, or substitutes the
  # definition's default, where it used to return "must be an existing media
  # item".
  defp blank_for?(def, value) when is_map(value) and not is_struct(value) do
    if composite?(def), do: Enum.all?(Map.values(value), &blank?/1), else: false
  end

  # A gallery (`multiple` media) is blank when every entry is: the editor
  # always submits a leading `""` so that removing the last image still sends
  # the key, and an emptied gallery must clear rather than keep what it held.
  #
  # The same holds for a single media field handed a list (a value stored while
  # the field was a gallery — a working copy, a version, an API round-trip).
  #
  # A list of references (`multiple` reference) follows the same rule, for the
  # same reasons.
  defp blank_for?(%{field_type: type}, value)
       when type in [:media, :reference] and is_list(value),
       do: Enum.all?(value, &blank?/1)

  defp blank_for?(_def, value), do: blank?(value)

  defp composite?(%{field_type: type} = def) do
    case KilnCMS.CMS.FieldTypes.get(type) do
      nil ->
        false

      module ->
        Code.ensure_loaded?(module) and function_exported?(module, :input_parts, 1) and
          module.input_parts(def) != []
    end
  end

  # Tenant-aware dispatch: only `:media`/`:reference` resolve records (and so need
  # the writing tenant and actor); every other field type coerces purely from its
  # value, so it delegates to the type-only `coerce/2` below.
  defp coerce(value, %{field_type: :media, multiple: true} = def, read_opts) do
    with {:ok, items} <- coerce_gallery(value, read_opts),
         do: within_bounds(items, def)
  end

  defp coerce(value, %{field_type: :reference, multiple: true} = def, read_opts) do
    with {:ok, items} <- coerce_reference_list(value, def, read_opts),
         do: within_bounds(items, def)
  end

  # A single media field handed a gallery list keeps its first item — the same
  # answer `SyncFieldValues` gives when a gallery is narrowed, so a working copy
  # or a version saved before the flip still promotes and restores.
  defp coerce(value, %{field_type: :media} = def, read_opts) when is_list(value),
    do: value |> Enum.reject(&blank?/1) |> List.first() |> coerce_media(def, read_opts)

  defp coerce(value, %{field_type: :media} = def, read_opts),
    do: coerce_media(value, def, read_opts)

  # A single reference handed a list (stored while the field was multiple)
  # keeps its first item, as a single media field does.
  defp coerce(value, %{field_type: :reference} = def, read_opts) when is_list(value),
    do: value |> Enum.reject(&blank?/1) |> List.first() |> coerce_reference(def, read_opts)

  defp coerce(value, %{field_type: :reference} = def, read_opts),
    do: coerce_reference(value, def, read_opts)

  defp coerce(value, def, _read_opts), do: coerce(value, def)

  # --- coercion to JSON-native values ----------------------------------------

  defp coerce(value, %{field_type: type}) when type in [:string, :text, :url] do
    {:ok, value |> to_string() |> String.trim()}
  end

  defp coerce(value, %{field_type: :select, options: options}) do
    str = value |> to_string() |> String.trim()
    if str in options, do: {:ok, str}, else: {:error, "is not one of the allowed options"}
  end

  defp coerce(value, %{field_type: :integer}) do
    case value do
      v when is_integer(v) -> {:ok, v}
      v -> parse(Integer, v, "must be a whole number")
    end
  end

  defp coerce(value, %{field_type: :float}) do
    case value do
      v when is_number(v) -> {:ok, v / 1}
      v -> parse(Float, v, "must be a number")
    end
  end

  defp coerce(value, %{field_type: :boolean}) do
    case value do
      v when is_boolean(v) -> {:ok, v}
      v when v in ["true", "1", "on"] -> {:ok, true}
      v when v in ["false", "0", "off", ""] -> {:ok, false}
      _ -> {:error, "must be a boolean"}
    end
  end

  defp coerce(value, %{field_type: :date}) do
    case Date.from_iso8601(to_string(value)) do
      {:ok, date} -> {:ok, Date.to_iso8601(date)}
      _ -> {:error, "must be a date (YYYY-MM-DD)"}
    end
  end

  defp coerce(value, %{field_type: :datetime}) do
    str = to_string(value)

    # Accept both full ISO-8601 and the HTML datetime-local shape (no seconds /
    # no offset), normalizing to an ISO-8601 string.
    with {:error, _} <- parse_datetime(str),
         {:error, _} <- parse_datetime(str <> ":00") do
      {:error, "must be a date and time"}
    end
  end

  # A plugin-contributed field type (`Kiln.FieldType`): the plugin's `cast/2`
  # owns coercion + validation. The contract requires a JSON-native return —
  # anything else is a loud contract violation, not a swallowed write.
  defp coerce(value, %{field_type: type} = definition) do
    case KilnCMS.CMS.FieldTypes.get(type) do
      nil ->
        {:error, "has an unregistered field type"}

      module ->
        case module.cast(value, definition) do
          {:ok, cast} ->
            {:ok, cast}

          {:error, message} when is_binary(message) ->
            {:error, message}

          other ->
            raise "#{inspect(module)}.cast/2 must return {:ok, value} | {:error, message}, " <>
                    "got: #{inspect(other)}"
        end
    end
  end

  # A media field: the editor submits a MediaItem id; the stored value is a
  # small snapshot (`%{"id", "url", "alt"}`) resolved at write time, so delivery
  # needs no extra lookup — the same embed-at-write-time stance image blocks
  # take. Re-saving refreshes the snapshot. Accepts a previously stored map too
  # (API writers may round-trip the stored shape). Scoped to the writing tenant
  # so a media reference can't point across sites (epic #336).
  defp coerce_media(value, _def, read_opts) do
    with {:ok, id} <- extract_id(value),
         {:ok, media} <- KilnCMS.CMS.get_media_item(id, read_opts) do
      {:ok, %{"id" => media.id, "url" => media.url, "alt" => media.alt}}
    else
      _ -> {:error, "must be an existing media item"}
    end
  end

  # A gallery media field (`multiple: true`): an ordered list of the same
  # snapshots a single media field stores, one per picked item. Order is the
  # editor's — it is the order the gallery renders in. Blanks (the editor's
  # leading `""`) drop out, and an item picked twice is kept once, where it
  # first appears. A lone id or snapshot is accepted as a one-item gallery, so a
  # writer that predates the flag still lands a valid value. Any id that does
  # not resolve fails the whole field rather than quietly shortening it.
  defp coerce_gallery(value, read_opts) do
    items = value |> List.wrap() |> Enum.reject(&blank?/1)

    with {:ok, ids} <- gallery_ids(items),
         {:ok, by_id} <- read_media(ids, read_opts),
         :ok <- all_found(ids, by_id) do
      {:ok,
       ids
       |> Enum.uniq()
       |> Enum.map(&by_id[&1])
       |> Enum.map(&%{"id" => &1.id, "url" => &1.url, "alt" => &1.alt})}
    end
  end

  defp gallery_ids(items) do
    items
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {item, position}, {:ok, acc} ->
      with {:ok, id} <- extract_id(item), {:ok, uuid} <- Ecto.UUID.cast(id) do
        {:cont, {:ok, [uuid | acc]}}
      else
        _ -> {:halt, {:error, missing_message(position, item)}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      error -> error
    end
  end

  # One read for the whole gallery, not one per image: this runs on every
  # editor validate, i.e. per keystroke. Read as the caller, under the writing
  # tenant, exactly as a single media field's `get_media_item` is.
  defp read_media([], _read_opts), do: {:ok, %{}}

  defp read_media(ids, read_opts) do
    query = Ash.Query.filter(KilnCMS.CMS.MediaItem, id in ^ids)

    case KilnCMS.CMS.list_media_items(Keyword.put(read_opts, :query, query)) do
      {:ok, items} -> {:ok, Map.new(items, &{&1.id, &1})}
      {:error, _error} -> {:error, "must only contain existing media items"}
    end
  end

  # Name the image that failed — the editor still shows its tile from the
  # stored snapshot, so "one of them" leaves the writer guessing which.
  defp all_found(ids, by_id) do
    case Enum.find_index(ids, &(not Map.has_key?(by_id, &1))) do
      nil -> :ok
      index -> {:error, missing_message(index + 1, Enum.at(ids, index))}
    end
  end

  defp missing_message(position, item) do
    id =
      case extract_id(item) do
        {:ok, id} -> " (#{id})"
        :error -> ""
      end

    "image #{position}#{id} is not an existing media item — remove it from the gallery"
  end

  @doc """
  The ids a stored media or reference value holds, in order: a list (gallery,
  list of references) or a single snapshot, as snapshots or bare ids, blanks
  dropped. One rule for every reader of the stored shape (the editor, the
  translation lock).
  """
  @spec snapshot_ids(term()) :: [String.t()]
  def snapshot_ids(value) do
    value
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"id" => id} when is_binary(id) and id != "" -> [id]
      id when is_binary(id) and id != "" -> [id]
      _blank -> []
    end)
  end

  # A content reference: resolves the target id against the field's declared
  # target type (compiled or dynamic) and stores a snapshot
  # (`%{"id", "type", "slug", "title"}`) — id/type are the stable keys
  # consumers fetch fresh content with; slug/title are display labels that may
  # go stale until the next save. Scoped to the writing tenant so a reference
  # can't point across sites (epic #336).
  #
  # A field that allows several types (`target_types`, R2) needs the input to
  # say which one it names — `%{"id", "type"}`, which a stored snapshot already
  # is. With one allowed type a bare id is enough, and a `"type"` the input
  # carries is not consulted, exactly as before R2.
  defp coerce_reference(value, def, read_opts) do
    allowed = FieldDefinition.reference_targets(def)

    with {:ok, id} <- extract_id(value),
         {:type, {:ok, target}} <- {:type, item_type(value, allowed)},
         ct when not is_nil(ct) <- KilnCMS.CMS.ContentTypes.get(target),
         {:ok, record} <- KilnCMS.CMS.ContentTypes.get_record(ct, id, read_opts) do
      {:ok, reference_snapshot(record, target)}
    else
      {:type, {:error, reason}} -> {:error, type_message(reason, allowed)}
      _ -> {:error, "must be an existing #{types_label(allowed)} record"}
    end
  end

  defp reference_snapshot(record, type),
    do: %{"id" => record.id, "type" => type, "slug" => record.slug, "title" => record.title}

  # Which allowed type an input item names. One allowed type is the answer
  # whatever the item says; several need the item to name one of them.
  defp item_type(_item, []), do: {:ok, nil}
  defp item_type(_item, [only]), do: {:ok, only}

  defp item_type(item, allowed) do
    case given_type(item) do
      nil -> {:error, :untyped}
      type -> if type in allowed, do: {:ok, type}, else: {:error, {:not_allowed, type}}
    end
  end

  defp given_type(%{"type" => type}) when is_binary(type) and type != "", do: type
  defp given_type(_item), do: nil

  defp type_message(:untyped, allowed),
    do: "must say which type of content it links to (one of: #{Enum.join(allowed, ", ")})"

  defp type_message({:not_allowed, type}, allowed),
    do: "can't link to #{type} — this field links to #{Enum.join(allowed, ", ")}"

  defp types_label([]), do: "content"
  defp types_label(allowed), do: Enum.join(allowed, " or ")

  # A list of references (`multiple: true`): an ordered list of the same
  # snapshots a single reference stores. Order is the writer's. Unlike a
  # gallery, a target named twice is an error rather than quietly kept once —
  # a list of references is an editorial choice per item (and, from R3, carries
  # per-link data), so the writer is told which one repeats. A lone id or
  # snapshot is a one-item list; any id that does not resolve fails the field.
  # On a field that allows several types every item names its own, and the
  # list may mix them.
  #
  # The messages are for an editor, not a developer: an item is named by its
  # title wherever one is known (the record's, or the stale snapshot's), and by
  # its id only when there is nothing else to call it.
  defp coerce_reference_list(value, def, read_opts) do
    allowed = FieldDefinition.reference_targets(def)
    items = value |> List.wrap() |> Enum.reject(&blank?/1)

    with {:ok, picked} <- reference_ids(items, allowed),
         {:ok, by_id} <- read_references(picked, read_opts),
         :ok <- no_repeats(picked, by_id),
         :ok <- all_resolved(picked, by_id) do
      {:ok, Enum.map(picked, fn {id, type, _title} -> reference_snapshot(by_id[id], type) end)}
    end
  end

  # `{uuid, type, title}` per item — the title a snapshot carried, if it was one.
  defp reference_ids(items, allowed) do
    items
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {item, position}, {:ok, acc} ->
      label = item_label(item, snapshot_title(item))

      with {:ok, id} <- extract_id(item),
           {:ok, uuid} <- Ecto.UUID.cast(id),
           {:ok, type} <- item_type(item, allowed) do
        {:cont, {:ok, [{uuid, type, snapshot_title(item)} | acc]}}
      else
        {:error, :untyped} ->
          {:halt, {:error, untyped(position, label, allowed)}}

        {:error, {:not_allowed, type}} ->
          {:halt, {:error, not_allowed(position, label, type, allowed)}}

        _ ->
          {:halt, {:error, unresolved(position, label)}}
      end
    end)
    |> case do
      {:ok, picked} -> {:ok, Enum.reverse(picked)}
      error -> error
    end
  end

  defp no_repeats(picked, by_id) do
    ids = Enum.map(picked, &elem(&1, 0))

    case ids -- Enum.uniq(ids) do
      [] ->
        :ok

      [id | _] ->
        {_id, _type, title} = Enum.find(picked, &(elem(&1, 0) == id))
        record_title = by_id |> Map.get(id, %{}) |> Map.get(:title)

        {:error,
         "lists #{item_label(id, record_title || title)} twice — each item can only be added once"}
    end
  end

  defp all_resolved(picked, by_id) do
    case Enum.find_index(picked, fn {id, _type, _title} -> not Map.has_key?(by_id, id) end) do
      nil ->
        :ok

      index ->
        {id, _type, title} = Enum.at(picked, index)
        {:error, unresolved(index + 1, item_label(id, title))}
    end
  end

  # One read per target type (one in all for a single-type field — this runs on
  # every editor validate), as the caller and under the writing tenant — the
  # same reach a single reference's `get_record` has, so a list cannot name
  # what a single field could not. An id is found only among the records of
  # the type its item named.
  defp read_references(picked, read_opts) do
    picked
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {type, ids}, {:ok, acc} ->
      case read_references(type, ids, read_opts) do
        {:ok, found} -> {:cont, {:ok, Map.merge(acc, found)}}
        error -> {:halt, error}
      end
    end)
  end

  defp read_references(type, ids, read_opts) do
    case KilnCMS.CMS.ContentTypes.get(type) do
      nil ->
        {:error, "links to a content type that no longer exists"}

      _ct ->
        records =
          KilnCMS.CMS.ContentTypes.list!(
            type,
            Keyword.put(read_opts, :query,
              filter: [id: [in: ids]],
              select: [:id, :slug, :title]
            )
          )

        {:ok, Map.new(records, &{&1.id, &1})}
    end
  rescue
    _error -> {:error, "could not be checked — try saving again"}
  end

  defp snapshot_title(%{"title" => title}) when is_binary(title) and title != "", do: title
  defp snapshot_title(_item), do: nil

  # `“Title”` when there is one, else the id as given, else nothing.
  defp item_label(_item, title) when is_binary(title), do: "“#{title}”"

  defp item_label(item, nil) do
    case extract_id(item) do
      {:ok, id} -> "(#{id})"
      :error -> nil
    end
  end

  defp untyped(position, label, allowed),
    do:
      "item #{position}#{label && " " <> label} doesn't say which type of content it is " <>
        "(one of: #{Enum.join(allowed, ", ")})"

  defp not_allowed(position, label, type, allowed),
    do:
      "item #{position}#{label && " " <> label} is of type #{type}, which this field can't link to " <>
        "— it links to #{Enum.join(allowed, ", ")}"

  defp unresolved(position, nil),
    do: "item #{position} no longer exists or can't be linked — remove it from the list"

  defp unresolved(position, label),
    do: "item #{position} #{label} no longer exists or can't be linked — remove it from the list"

  # `min_items` / `max_items` on a list field. Only a field that holds items
  # reaches here — an emptied optional field is `:skip`ped before coercion, and
  # `required` is what asks for at least one.
  defp within_bounds(items, def) do
    count = length(items)
    min = Map.get(def, :min_items)
    max = Map.get(def, :max_items)

    cond do
      is_integer(min) and count < min ->
        {:error, "needs at least #{min} items (has #{count})"}

      is_integer(max) and count > max ->
        {:error, "can have at most #{max} items (has #{count})"}

      true ->
        {:ok, items}
    end
  end

  defp extract_id(%{"id" => id}) when is_binary(id) and id != "", do: {:ok, id}
  defp extract_id(id) when is_binary(id), do: {:ok, id}
  defp extract_id(_other), do: :error

  defp parse_datetime(str) do
    case NaiveDateTime.from_iso8601(str) do
      {:ok, ndt} -> {:ok, NaiveDateTime.to_iso8601(ndt)}
      error -> error
    end
  end

  defp parse(mod, value, message) do
    case mod.parse(to_string(value)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, message}
    end
  end

  # --- helpers ---------------------------------------------------------------

  # Type-independent blankness. Maps are handled by `blank_for?/2`, which knows
  # the definition — an empty map is only "no value" for a composite type.
  defp blank?(%{} = value) when not is_struct(value), do: map_size(value) == 0

  defp blank?(value), do: value in [nil, ""] or (is_binary(value) and String.trim(value) == "")

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  # A key the registry does not declare. The message lists what the type DOES
  # define: the mistake is nearly always a typo or a name that drifted from the
  # definition, and the answer is right there in the list.
  defp undefined_error(key, defs) do
    defined =
      case Enum.map(defs, & &1.name) |> Enum.sort() do
        [] -> "this content type defines no custom fields"
        names -> "defined fields: " <> Enum.join(names, ", ")
      end

    InvalidAttribute.exception(
      field: :custom_fields,
      message: "\"#{key}\" is not a defined custom field (#{defined})",
      value: key
    )
  end

  defp error(def, message) do
    InvalidAttribute.exception(
      field: :custom_fields,
      message: "#{def.label} (#{def.name}) #{message}",
      value: def.name
    )
  end
end
