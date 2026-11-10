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

  ## A new draft from the editor may start blank

  The content editor creates a document's row from a scaffold title and slug
  before the writer has seen a single field
  (`KilnCMSWeb.ContentEditor.NewDraft.create/4`), so it passes
  `context: %{custom_fields_required: :defer}` and that one create leaves a
  blank required field blank. Every later save sends the whole map, so the
  writer is asked for the value on the first save, and the editor saves the
  form before Publish or Submit for review. The flag is ignored on anything but
  a create.

  ## Link fields: data on each connection

  A `:reference` definition may declare link fields (`FieldDefinition`
  rows with `link_of_id`, R3) — "Quantity" and "Role" on each ingredient a
  recipe connects. Their values ride on the snapshot as an added `"link"`
  map, `%{"id", "type", "slug", "title", "link" => %{"quantity" => 2}}`,
  and are coerced exactly as a top-level field is: the same types, the same
  `required`, `default` and `:select` rules. A snapshot whose connection
  carries no link value has no `"link"` key, so a field without link fields
  stores what it always did.

  An input item names its link values under `"link"`. Each link field merges
  the way a top-level key does, per connection: a supplied value is coerced,
  one the item leaves out keeps what the same connection stored before, and
  a connection new to the field falls to the defaults. A link key no link
  field declares is refused (or dropped, in `:drop` mode), as an undefined
  top-level key is.

  `KilnCMS.CMS.ContentLinks` copies each connection's `"link"` map onto its
  edge's `metadata` in the same transaction.

  ## Groups: an object, or a list of them

  A `:group` definition holds structured rows whose keys are its sub-fields
  (`FieldDefinition` rows with `group_of_id`) — `dosages` as a list of
  `%{"amount" => 2, "unit" => "g"}`. A group that is not `multiple` holds one
  object; a `multiple` one holds a list (repeating rows), bounded by
  `min_items`/`max_items` like a gallery. Each key is coerced by the
  sub-field's own rules — the same types, `required`, `default` and
  `:select` checks a top-level field gets — and a key no sub-field declares
  is refused (dropped, in `:drop` mode). A row whose values are all blank is
  no row at all, the way an emptied gallery slot is no image.

  There is no per-row merge: rows carry no identity to match an earlier row
  by, so a write that names the group sends all of it. Leaving the group's
  key out keeps it, as with any field.

  Every problem names its path — `Unit (dosages[2].unit) must be one of the
  allowed options`, rows counted from 0 as the stored list indexes them — and
  a write reports every bad key at once rather than the first.

  A group's `default` is not used: a one-line string is not an object.

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
  alias KilnCMS.CMS.Conditions
  alias KilnCMS.CMS.DynamicDefaults
  alias KilnCMS.CMS.FieldConstraints
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.PrivateFields
  alias KilnCMS.CMS.ScalarLists
  alias KilnCMS.CMS.UniqueValues
  alias KilnCMS.CMS.WorkingCopy

  @scalar_list_types ScalarLists.types()
  @typed_list_types ScalarLists.typed()

  @impl true
  def change(changeset, opts, context) do
    # One date for every formula this write evaluates, and for the fire it
    # enqueues (`Computed.Context`, "Pinning today").
    changeset = KilnCMS.CMS.Computed.Context.pin_today(changeset)

    cond do
      opts[:resnapshot] == :media ->
        resnapshot_media(changeset, context)

      opts[:convert] == true ->
        convert(changeset, context)

      changeset.action_type == :create or
          Ash.Changeset.changing_attribute?(changeset, :custom_fields) ->
        apply_definitions(changeset, merge_base(changeset), mode(changeset), context)

      # An update that never mentions `custom_fields` still has to refresh
      # computed fields: their inputs are the *document* — a retitled page
      # changes `{{ slugify(title) }}`, a reworded one changes reading time.
      true ->
        changeset |> refresh_computed() |> unique_after_move()
    end
  end

  # Bulk writes run `change/3` per record, as before; the batch hook exists so
  # a batch's unique-value locks are taken together and in order (#2276).
  @impl true
  def batch_change(changesets, opts, context),
    do: Enum.map(changesets, &change(&1, opts, context))

  @impl true
  def before_batch(changesets, _opts, _context), do: UniqueValues.lock_batch(changesets)

  # A locale or type change moves the record into another uniqueness scope
  # (#2276) even when `custom_fields` is untouched.
  defp unique_after_move(changeset) do
    if Ash.Changeset.changing_attribute?(changeset, :locale) or
         Ash.Changeset.changing_attribute?(changeset, :type_definition_id),
       do: UniqueValues.register(changeset, stashed_definitions(changeset) || []),
       else: changeset
  end

  # `:resnapshot_media` (`mix kiln.media.resnapshot`): re-resolve every stored
  # `:media` snapshot through the same coercion an editor's save runs, as if
  # the caller had re-sent exactly those values. Every other key is absent from
  # the "payload", so it merges through untouched — the editable pass never
  # re-resolves a `:reference`, and never re-checks a value nobody sent.
  defp resnapshot_media(changeset, context) do
    existing = merge_base(changeset)

    supplied =
      for %{field_type: :media, name: name} <- definitions_for(changeset),
          Map.has_key?(existing, name),
          into: %{},
          do: {name, existing[name]}

    apply_definitions(changeset, existing, :strict, context, supplied)
  end

  # `:convert_custom_field` (`mix kiln.fields.convert`): the rows parsed out of
  # the source field ride in the changeset context as `convert_custom_field:
  # %{name: group, live: rows}`, and are coerced as if the caller had sent
  # exactly that key — every other key merges through as stored.
  #
  # A live record's pending working copy may hold its own `custom_fields` map
  # (`KilnCMS.CMS.WorkingCopy`), saved before the group existed. Publishing the
  # copy replaces the live map with it, so the copy gets its own rows too
  # (`held:`, parsed from the copy's source value) — see `convert_held/4`.
  defp convert(changeset, context) do
    case changeset.context do
      %{convert_custom_field: %{name: _, live: _} = conversion} ->
        convert(changeset, conversion, context)

      _none ->
        Ash.Changeset.add_error(changeset, "no conversion in the changeset context")
    end
  end

  defp convert(changeset, %{name: name, live: live} = conversion, context) do
    changeset =
      apply_definitions(changeset, merge_base(changeset), :strict, context, %{name => live})

    case Map.fetch(conversion, :held) do
      {:ok, held} -> convert_held(changeset, name, held, context)
      :error -> changeset
    end
  end

  # The copy's `custom_fields` gets the group coerced from `rows` exactly as
  # the live map does. Its lost-update base (`working_base`) moves with it, so
  # the conversion is never what makes "Publish changes" report a conflict:
  # a base that matched the held map now matches the converted held map, one
  # that matched the live map now matches the converted live map, and any
  # other base (a conflict already) is left alone.
  defp convert_held(changeset, name, rows, context) do
    fields = WorkingCopy.held_fields(changeset.data)
    held = stringify_keys(fields["custom_fields"] || %{})
    def = Enum.find(definitions_for(changeset), &(&1.name == name))
    read_opts = context |> Ash.Context.to_opts() |> Keyword.put(:tenant, changeset.to_tenant)

    case accumulate(def, %{name => rows}, held, {read_opts, :strict, true}, {%{}, []}) do
      {cleaned, []} ->
        converted =
          case Map.fetch(cleaned, name) do
            {:ok, value} -> Map.put(held, name, value)
            :error -> Map.delete(held, name)
          end

        changeset
        |> Ash.Changeset.force_change_attribute(
          :working_fields,
          Map.put(fields, "custom_fields", converted)
        )
        |> Ash.Changeset.force_change_attribute(
          :working_base,
          rebase(changeset, held, converted)
        )

      {_cleaned, errors} ->
        Enum.reduce(errors, changeset, fn error, acc ->
          Ash.Changeset.add_error(acc, %{error | message: "(working copy) " <> error.message})
        end)
    end
  end

  defp rebase(changeset, held, converted) do
    record = changeset.data
    base = WorkingCopy.base_fingerprints(record)
    fingerprint = &WorkingCopy.fingerprint(changeset.resource, "custom_fields", &1)
    recorded = base["custom_fields"]

    cond do
      recorded == nil ->
        base

      recorded == fingerprint.(held) ->
        Map.put(base, "custom_fields", fingerprint.(converted))

      recorded == fingerprint.(stringify_keys(record.custom_fields || %{})) ->
        live = Ash.Changeset.get_attribute(changeset, :custom_fields)
        Map.put(base, "custom_fields", fingerprint.(live))

      true ->
        base
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
  def apply_restored(changeset, context) do
    # A restored or promoted map was valid when it was written; a constraint
    # tightened since (#2276) is for the next edit, not a reason to fail this.
    changeset
    |> Ash.Changeset.set_context(%{custom_fields_constraints: :skip})
    |> apply_definitions(%{}, :drop, context)
  end

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

  defp apply_definitions(changeset, existing, mode, context, supplied \\ nil) do
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

    # Value constraints (#2276) are skipped for machinery that carries values
    # the record already holds (a restore, a copy): `custom_fields_constraints:
    # :skip` in the changeset context.
    check? = changeset.context[:custom_fields_constraints] != :skip
    # `required_when` (#2277) binds an ordinary write only: a restore, a copy
    # and the media/convert passes (which hand their own `supplied`) skip it.
    required_when? = mode == :strict and is_nil(supplied)

    supplied =
      supplied ||
        stringify_keys(Ash.Changeset.get_attribute(changeset, :custom_fields) || %{})

    # Computed fields (#429) are resolved in a second pass, after the editable
    # ones: their formulas reference sibling values, so they must see the
    # already-coerced results rather than raw params — and each other's, in
    # dependency order.
    {computed, editable} = Enum.split_with(defs, &(&1.field_type == :computed))

    # A duplicate (#2276) starts a new record, which must not claim the
    # source's unique values: they are left blank, and `required` does not
    # ask for them (the draft needs a value before it can be published).
    editable =
      if changeset.context[:custom_fields_unique] == :blank,
        do: Enum.reject(editable, &UniqueValues.unique_def?/1),
        else: editable

    # Dynamic defaults (#2286) settle first: on an ordinary create each stands
    # in for its field's `default`; on any other write none does.
    {editable, defaulted} =
      DynamicDefaults.settle(editable, %{
        create?:
          changeset.action_type == :create and
            changeset.context[:custom_fields_constraints] != :skip,
        today: DynamicDefaults.today(changeset),
        actor: context.actor,
        tenant: changeset.to_tenant,
        supplied: supplied
      })

    # Conditional rules (#2277) read the merged view; they only adjust `required`.
    editable =
      editable
      |> Conditions.apply_to(Map.merge(existing, supplied), required_when: required_when?)
      |> defer_required(changeset)

    {cleaned, errors} =
      Enum.reduce(
        editable,
        {%{}, []},
        &accumulate(&1, supplied, existing, {read_opts, mode, check?}, &2)
      )

    {cleaned, errors} = apply_computed(computed, changeset, cleaned, errors)

    {refused, dropped} = undefined(defs, supplied, existing, mode)
    errors = Enum.map(refused, &undefined_error(&1, defs)) ++ errors

    changeset
    |> Ash.Changeset.force_change_attribute(:custom_fields, cleaned)
    |> stash(defs)
    |> stash_supplied(supplied)
    |> stash_defaulted(defaulted)
    |> note_dropped(dropped)
    |> then(fn cs -> Enum.reduce(errors, cs, &Ash.Changeset.add_error(&2, &1)) end)
    |> UniqueValues.register(defs)
  end

  # The editor's scaffold create (`KilnCMSWeb.ContentEditor.NewDraft`) writes a
  # row before the writer has seen a single field, so it cannot satisfy
  # `required` — and refusing it left a type with a required, default-less
  # field impossible to start from the editor at all. It passes
  # `custom_fields_required: :defer`: on that create only, a blank required
  # field is left blank. Every later write the editor makes sends the whole
  # map, so the first save — and the flush that runs before Publish or Submit
  # — asks for the value as usual. Ignored on any write but a create, so the
  # flag cannot be used to clear a required field on an existing record.
  defp defer_required(editable, %{
         action_type: :create,
         context: %{custom_fields_required: :defer}
       }),
       do: Enum.map(editable, &%{&1 | required: false})

  defp defer_required(editable, _changeset), do: editable

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
  #
  # A private field (#2044) is out of the formulas' sight: a computed value is
  # delivered, so one derived from a private value would publish it. The
  # private values are put back for storage, untouched.
  defp apply_computed(defs, changeset, cleaned, errors) do
    private =
      Map.take(cleaned, PrivateFields.names_for(written_document(changeset), changeset.to_tenant))

    visible = Map.drop(cleaned, Map.keys(private))
    context = KilnCMS.CMS.Computed.Context.from_changeset(changeset, visible)

    {defs |> KilnCMS.CMS.Computed.derive(context, visible) |> Map.merge(private), errors}
  end

  # The record a changeset writes, as `PrivateFields.names_for/2` reads it: an
  # entry being created carries its type definition on the changeset only.
  defp written_document(changeset) do
    case Ash.Changeset.get_attribute(changeset, :type_definition_id) do
      id when is_binary(id) -> Map.put(changeset.data, :type_definition_id, id)
      _ -> changeset.data
    end
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

  defp stash_defaulted(changeset, names),
    do: Ash.Changeset.set_context(changeset, %{kiln_custom_fields_defaulted: names})

  @doc """
  The keys a dynamic default (#2286) stands in for on this write: the payload
  left them blank or absent. A field grant does not count them as the editor's
  change.
  """
  @spec defaulted_keys(Ash.Changeset.t()) :: [String.t()]
  def defaulted_keys(changeset), do: changeset.context[:kiln_custom_fields_defaulted] || []

  @doc """
  One error per required custom field that `changeset` would leave blank on
  the record — read off the `custom_fields` it writes, after `required_when`
  (#2277) has settled. Computed fields never count: they cannot be required.

  The check `KilnCMS.CMS.Validations.RequiredCustomFields` runs at publish. A
  write that never names `custom_fields` does not run the editable pass, and
  the editor's scaffold create defers `required` (module doc, "A new draft
  from the editor may start blank"), so a draft can reach Publish with a
  required field still empty.
  """
  @spec missing_required(Ash.Changeset.t()) :: [Exception.t()]
  def missing_required(changeset) do
    defs = stashed_definitions(changeset) || definitions_for(changeset)

    values =
      changeset
      |> Ash.Changeset.get_attribute(:custom_fields)
      |> Kernel.||(%{})
      |> stringify_keys()

    defs
    |> Enum.reject(&(&1.field_type == :computed))
    |> Conditions.apply_to(values, required_when: true)
    |> Enum.filter(&(&1.required and blank_for?(&1, Map.get(values, &1.name))))
    |> Enum.map(&error(&1, "is required before publishing"))
  end

  # Resolve one definition's value and fold it into the {cleaned, errors} acc.
  # Three-way per key: a field the caller *supplied* is coerced/cleared; a field
  # they omitted keeps its `existing` stored value (the merge); a field with
  # neither falls to its default (fresh field / create).
  defp accumulate(def, supplied, existing, {read_opts, mode, check?}, {cleaned, errors}) do
    ctx = {read_opts, mode, check?}

    cond do
      Map.has_key?(supplied, def.name) ->
        def
        |> resolve_field(
          Map.get(supplied, def.name),
          read_opts,
          {mode, grandfather(check?, Map.get(existing, def.name))}
        )
        |> constrain(def, Map.get(existing, def.name), check?)
        |> with_links(def, Map.get(supplied, def.name), Map.get(existing, def.name), ctx)
        |> fold(def, cleaned, errors)

      Map.has_key?(existing, def.name) ->
        # Untouched by this write: keep the stored (already-coerced) value as-is.
        # No re-coercion, so a stale reference/media snapshot isn't re-resolved
        # and a since-changed definition can't reject a value the caller never
        # sent.
        {Map.put(cleaned, def.name, Map.get(existing, def.name)), errors}

      true ->
        def
        |> resolve_field(nil, read_opts, {mode, grandfather(check?, nil)})
        |> constrain(def, nil, check?)
        |> with_links(def, def.default, nil, ctx)
        |> fold(def, cleaned, errors)
    end
  end

  # What a group row is compared against to be left unchecked: the rows the
  # field stored, or nothing when constraints are off (every row passes).
  defp grandfather(false, _stored), do: :skip
  defp grandfather(true, stored), do: {:rows, List.wrap(stored)}

  # Value constraints (#2276) on a coerced value. A value equal to the stored
  # one is grandfathered — a form resubmits every field, and a constraint
  # tightened since must not reject what the record already holds. Groups
  # check their own rows (`coerce_row`), where the row index is still known.
  defp constrain({:ok, _value} = ok, %{field_type: :group}, _stored, _check?), do: ok
  defp constrain({:ok, _value} = ok, _def, _stored, false), do: ok

  defp constrain({:ok, value} = ok, def, stored, true) do
    cond do
      value == stored ->
        ok

      stored_item_list?(def, value, stored) ->
        constrain_problems(ok, new_items(def, value, stored))

      true ->
        constrain_problems(ok, FieldConstraints.check(def, value))
    end
  end

  defp constrain(other, _def, _stored, _check?), do: other

  defp constrain_problems(ok, []), do: ok
  defp constrain_problems(_ok, problems), do: {:errors, problems}

  # A scalar list (`multiple` string, integer, date, …) is checked per item;
  # an item already stored is not re-litigated, so adding a tag to a list
  # holding one now-too-long tag — or a score to a list holding one above a
  # since-tightened `max` — still saves. Only the items it did not hold are
  # checked, each under its own position (`scores[2]`).
  defp stored_item_list?(%{multiple: true, field_type: type}, value, stored)
       when type in @scalar_list_types,
       do: is_list(value) and is_list(stored)

  defp stored_item_list?(_def, _value, _stored), do: false

  defp new_items(def, value, stored) do
    value
    |> Enum.with_index()
    |> Enum.reject(fn {item, _index} -> item in stored end)
    |> Enum.flat_map(fn {item, index} ->
      FieldConstraints.check(def, item, "#{def.name}[#{index}]")
    end)
  end

  # --- link fields (R3) ----------------------------------------------------------

  # Attach each connection's link values to a coerced reference value: one
  # snapshot or a list of them. `raw` is what the caller supplied for the
  # field; `stored` the field's value before this write, whose connections
  # keep the link values an item leaves out.
  defp with_links({:ok, value}, %{field_type: :reference} = def, raw, stored, ctx) do
    case FieldDefinition.link_fields(def) do
      [] -> {:ok, value}
      links -> attach_links(value, links, inputs(raw, def), stored_links(stored), ctx)
    end
  end

  defp with_links(result, _def, _raw, _stored, _ctx), do: result

  # The non-blank input items, in order — the same items the coercion kept,
  # since a list of references refuses repeats rather than dropping them. A
  # blank input was coerced from the field's default, which names no link
  # values.
  defp inputs(raw, def) do
    case raw |> List.wrap() |> Enum.reject(&blank?/1) do
      [] -> def.default |> List.wrap() |> Enum.reject(&blank?/1)
      items -> items
    end
  end

  defp stored_links(stored) do
    stored
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"id" => id, "link" => %{} = link} -> [{id, link}]
      _other -> []
    end)
    |> Map.new()
  end

  defp attach_links(items, links, inputs, stored, ctx) when is_list(items) do
    items
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {item, position}, {:ok, acc} ->
      case link_item(item, Enum.at(inputs, position - 1), links, stored, ctx) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, message} -> {:halt, {:error, "— item #{position} #{message}"}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp attach_links(item, links, inputs, stored, ctx) do
    case link_item(item, List.first(inputs), links, stored, ctx) do
      {:ok, item} -> {:ok, item}
      {:error, message} -> {:error, "— #{message}"}
    end
  end

  # One connection's link values: per link field, the supplied value
  # (coerced), else the one this connection stored, else the default.
  defp link_item(item, input, links, stored, {read_opts, mode, check?}) do
    given = link_input(input)
    kept = Map.get(stored, item["id"], %{})

    {cleaned, problems} =
      Enum.reduce(links, {%{}, []}, fn link, {cleaned, problems} ->
        case link_value(link, given, kept, read_opts, check?) do
          :skip -> {cleaned, problems}
          {:ok, value} -> {Map.put(cleaned, link.name, value), problems}
          {:error, {:full, text}} -> {cleaned, [text | problems]}
          {:error, message} -> {cleaned, ["#{link.label} #{message}" | problems]}
        end
      end)

    problems = Enum.reverse(problems) ++ undefined_links(given, links, kept, mode)

    case problems do
      [] when cleaned == %{} -> {:ok, Map.delete(item, "link")}
      [] -> {:ok, Map.put(item, "link", cleaned)}
      _ -> {:error, "#{item_label(item, item["title"])}: #{Enum.join(problems, "; ")}"}
    end
  end

  defp link_value(link, given, kept, read_opts, check?) do
    cond do
      Map.has_key?(given, link.name) ->
        link
        |> resolve(Map.get(given, link.name), read_opts)
        |> link_constraints(link, Map.get(kept, link.name), check?)

      Map.has_key?(kept, link.name) ->
        {:ok, Map.get(kept, link.name)}

      true ->
        resolve(link, nil, read_opts)
    end
  end

  # The same constraints a top-level field gets, on a connection's value; the
  # first problem stands for the item (`link_item` joins what it collects).
  defp link_constraints({:ok, value} = ok, link, kept, true) when value != kept do
    case FieldConstraints.check(link, value, link.name) do
      [] -> ok
      [{_path, _label, text} | _] -> {:error, text}
    end
  end

  defp link_constraints(result, _link, _kept, _check?), do: result

  defp link_input(%{"link" => %{} = link}), do: stringify_keys(link)
  defp link_input(%{link: %{} = link}), do: stringify_keys(link)
  defp link_input(_input), do: %{}

  # A link key no link field declares, the way `undefined/4` treats a
  # top-level one: refused unless it is blank or re-states the stored value.
  defp undefined_links(_given, _links, _kept, :drop), do: []

  defp undefined_links(given, links, kept, :strict) do
    names = Enum.map(links, & &1.name)

    given
    |> Enum.reject(fn {key, value} ->
      key in names or blank?(value) or Map.get(kept, key) == value
    end)
    |> Enum.map(fn {key, _value} ->
      "\"#{key}\" is not a detail of this connection (details: #{Enum.join(Enum.sort(names), ", ")})"
    end)
  end

  # --- groups ------------------------------------------------------------------

  defp resolve_field(%{field_type: :group} = def, raw, _read_opts, {mode, held}),
    do: resolve_group(def, raw, mode, held)

  defp resolve_field(def, raw, read_opts, _mode), do: resolve(def, raw, read_opts)

  # Whether a coerced group row still has to meet its sub-fields' constraints:
  # not when constraints are off, nor when the field already stores that row.
  defp row_unchecked?(:skip, _row), do: true
  defp row_unchecked?({:rows, stored}, row), do: row in stored

  # A group's value from what the caller sent: `:skip` when there are no rows
  # and none are required, else one coerced object (or a list of them), or
  # every problem found, each under its path.
  defp resolve_group(def, raw, mode, held) do
    rows =
      raw
      |> group_rows()
      |> Enum.with_index()
      |> Enum.reject(fn {row, _index} -> blank_row?(row) end)

    cond do
      rows == [] and def.required -> {:error, "is required"}
      rows == [] -> :skip
      def.multiple -> coerce_rows(rows, def, mode, held)
      # A single group handed a list (stored while the field was `multiple`)
      # keeps its first row, as a single media field keeps its first image.
      true -> rows |> hd() |> elem(0) |> coerce_row(def, def.name, mode, held) |> one_row()
    end
  end

  defp group_rows(rows) when is_list(rows), do: rows
  defp group_rows(nil), do: []
  defp group_rows(row), do: [row]

  defp blank_row?(%{} = row) when not is_struct(row),
    do: row |> Map.values() |> Enum.all?(&blank?/1)

  defp blank_row?(row), do: blank?(row)

  defp coerce_rows(rows, def, mode, held) do
    {kept, problems} =
      Enum.reduce(rows, {[], []}, fn {row, index}, {kept, problems} ->
        case coerce_row(row, def, "#{def.name}[#{index}]", mode, held) do
          {:ok, cleaned} -> {[cleaned | kept], problems}
          {:errors, found} -> {kept, problems ++ found}
        end
      end)

    case problems do
      [] -> kept |> Enum.reverse() |> within_bounds(def)
      _ -> {:errors, problems}
    end
  end

  defp one_row({:ok, row}), do: {:ok, row}
  defp one_row(errors), do: errors

  # One object: each sub-field coerced from its key (or its default when the
  # key is absent), and every key no sub-field declares refused.
  defp coerce_row(%{} = row, def, path, mode, held) when not is_struct(row) do
    given = stringify_keys(row)

    subs =
      Conditions.apply_to(FieldDefinition.group_fields(def), given,
        required_when: mode == :strict
      )

    {cleaned, problems} =
      Enum.reduce(subs, {%{}, []}, fn sub, {cleaned, problems} ->
        case sub_value(sub, Map.get(given, sub.name)) do
          :skip -> {cleaned, problems}
          {:ok, value} -> {Map.put(cleaned, sub.name, value), problems}
          {:error, message} -> {cleaned, [{"#{path}.#{sub.name}", sub.label, message} | problems]}
        end
      end)

    # Constraints (#2276) on the coerced values, under this row's index. A row
    # the field already stores is left alone.
    constraints =
      if row_unchecked?(held, cleaned),
        do: [],
        else: FieldConstraints.check_row(def, cleaned, path)

    case Enum.reverse(problems) ++
           undefined_sub_fields(given, subs, def, path, mode) ++ constraints do
      [] -> {:ok, cleaned}
      problems -> {:errors, problems}
    end
  end

  defp coerce_row(_row, def, path, _mode, _held),
    do: {:errors, [{path, def.label, "must be an object"}]}

  # Sub-fields are scalar (`FieldDefinition.link_field_types/0`), so a nested
  # object or list is refused before it reaches a coercion that would
  # stringify it.
  defp sub_value(_sub, value) when is_map(value) or is_list(value),
    do: {:error, "must be a single value, not an object or a list"}

  defp sub_value(sub, value), do: resolve(sub, value, [])

  # A blank key no sub-field declares asks for nothing, as at the top level.
  defp undefined_sub_fields(_given, _subs, _def, _path, :drop), do: []

  defp undefined_sub_fields(given, subs, def, path, :strict) do
    names = Enum.map(subs, & &1.name)

    given
    |> Enum.reject(fn {key, value} -> key in names or blank?(value) end)
    |> Enum.sort()
    |> Enum.map(fn {key, _value} ->
      {"#{path}.#{key}", def.label,
       "is not a sub-field of this group (sub-fields: #{Enum.join(Enum.sort(names), ", ")})"}
    end)
  end

  defp fold(:skip, _def, cleaned, errors), do: {cleaned, errors}
  defp fold({:ok, value}, def, cleaned, errors), do: {Map.put(cleaned, def.name, value), errors}

  defp fold({:error, message}, def, cleaned, errors),
    do: {cleaned, [error(def, message) | errors]}

  defp fold({:errors, problems}, def, cleaned, errors),
    do: {cleaned, Enum.reverse(Enum.map(problems, &path_error(def, &1)), errors)}

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

  # A key/value list (#2278) has no parts: it is empty when it holds no pair,
  # or only pairs with neither key nor value. Never stored as `[]`.
  defp blank_for?(%{field_type: :key_value}, value) when is_list(value),
    do: Enum.all?(value, &blank_pair?/1)

  defp blank_for?(%{field_type: :key_value}, value) when is_map(value) and not is_struct(value),
    do: map_size(value) == 0

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

  # A multiple select's picker, a list of phrases and every other scalar list
  # post the same leading `""`, so the same rule — and a single one handed a
  # list follows it too.
  defp blank_for?(%{field_type: type}, value)
       when type in @scalar_list_types and is_list(value),
       do: Enum.all?(value, &blank?/1)

  defp blank_for?(_def, value), do: blank?(value)

  defp blank_pair?(%{} = pair) when not is_struct(pair),
    do: pair |> Map.values() |> Enum.all?(&blank?/1)

  defp blank_pair?(other), do: blank?(other)

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

  defp coerce(value, %{field_type: :user}, read_opts), do: coerce_user(value, read_opts)

  defp coerce(value, %{field_type: :select, multiple: true} = def, _read_opts) do
    with {:ok, terms} <- coerce_terms(value, def), do: within_bounds(terms, def)
  end

  defp coerce(value, %{field_type: :string, multiple: true} = def, _read_opts) do
    with {:ok, items} <- coerce_phrases(value), do: within_bounds(items, def)
  end

  # A typed list (`ScalarLists.typed/0`: numbers, dates, links, …): each item
  # coerced as the single field would coerce it, then counted.
  defp coerce(value, %{field_type: type, multiple: true} = def, _read_opts)
       when type in @typed_list_types do
    with {:ok, items} <- coerce_items(value, def), do: within_bounds(items, def)
  end

  # A single scalar field handed a list (stored while the field was multiple —
  # a working copy, a restored version — or an API client sending an array)
  # keeps its first item, as a single media field does, rather than
  # stringifying the whole list into one value.
  defp coerce(value, %{field_type: type} = def, _read_opts)
       when type in @scalar_list_types and is_list(value) do
    case value |> Enum.reject(&blank?/1) |> List.first() do
      item when is_binary(item) or is_number(item) -> coerce(item, def)
      other -> {:error, "must be a single value (got #{inspect(other)})"}
    end
  end

  defp coerce(value, def, _read_opts), do: coerce(value, def)

  # A console account (#2044): the user's id, which must name one of the
  # writing site's people — an admin, or a member with any role
  # (`Scoping.users_with_tier/2`, the roster the editor's picker offers).
  # Stored as the bare id; the field is private, so it is never delivered.
  # A stored id round-trips; an account removed from the site since is
  # refused on the next write of the field, as a deleted reference target is.
  defp coerce_user(value, read_opts) do
    with {:ok, id} <- extract_id(value),
         true <- site_person?(id, read_opts[:tenant]) do
      {:ok, id}
    else
      _ -> {:error, "must be a person on this site"}
    end
  end

  @doc false
  def site_person?(id, tenant) do
    tenant
    |> KilnCMS.Accounts.Scoping.users_with_tier([:admin, :editor, :viewer])
    |> Enum.any?(&(&1.id == id))
  end

  @doc """
  One item of a typed list (`KilnCMS.CMS.ScalarLists.typed/0`) as the list
  would store it — `{:ok, value}` or `{:error, message}` — so the content
  editor can tell that a date-time picked as `T10:00` repeats a stored
  `T10:00:00` (#2289). Any other definition gets the item back unchanged.
  """
  @spec coerce_item(map(), term()) :: {:ok, term()} | {:error, String.t()}
  def coerce_item(%{field_type: type} = definition, item) when type in @typed_list_types,
    do: coerce(item, Map.put(definition, :multiple, false))

  def coerce_item(_definition, item), do: {:ok, item}

  # --- coercion to JSON-native values ----------------------------------------

  # A rich `:text` field (the default `format`) is HTML the TipTap field
  # editor wrote, or an importer did: sanitized to the rich-text block's
  # allow-list (`KilnCMS.CMS.TextFormat`), so the field is no wider a hole
  # than a block. A plain one is stored as typed.
  defp coerce(value, %{field_type: :text} = def) do
    text = value |> to_string() |> String.trim()

    if Map.get(def, :format, :rich) == :rich,
      do: {:ok, KilnCMS.CMS.TextFormat.sanitize(text)},
      else: {:ok, text}
  end

  defp coerce(value, %{field_type: type}) when type in [:string, :url] do
    {:ok, value |> to_string() |> String.trim()}
  end

  # A write may name an option by its label (`option_labels`); the value is
  # what is stored.
  defp coerce(value, %{field_type: :select, options: options} = def) do
    str = FieldDefinition.option_value(def, value |> to_string() |> String.trim())
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

  # A multiple select's terms: each a string (a number is taken as its text),
  # trimmed, blanks and repeats dropped, order kept. Each must be one of the
  # `options` unless the field takes terms of its own (`allow_custom`), and
  # none may be a JSON-encoded list — the string form this type replaces, which
  # an old client sending `"[\"a\",\"b\"]"` would otherwise store as one
  # term named after the whole list.
  defp coerce_terms(value, def) do
    terms =
      value
      |> List.wrap()
      |> Enum.reject(&blank?/1)

    case Enum.find(terms, &(not (is_binary(&1) or is_number(&1)))) do
      nil ->
        terms
        |> Enum.map(&FieldDefinition.option_value(def, &1 |> to_string() |> String.trim()))
        |> Enum.uniq()
        |> check_terms(def)

      other ->
        {:error, "must be a list of terms (got #{inspect(other)})"}
    end
  end

  # A list of phrases (`multiple` `:string`, "Symptoms"): the terms rules
  # without a vocabulary — and an item holding several lines is several
  # items, so a pasted list (or an API client's `"a\nb"`) splits rather than
  # storing one item with line breaks in it. `\R` needs the `u` flag: without
  # it `:re` reads bytes, takes 0x85 (NEL) for a line break, and splits inside
  # any character whose UTF-8 holds that byte (內 is E5 85 A7), leaving invalid
  # UTF-8 that fails the write.
  defp coerce_phrases(value) do
    with {:ok, items} <- coerce_terms(value, %{allow_custom: true, options: []}) do
      items
      |> Enum.flat_map(&String.split(&1, ~r/\R/u))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> then(&{:ok, &1})
    end
  end

  # A typed list's items: blanks dropped, a string item holding several lines
  # split into one item per line (as a list of phrases is), each coerced by
  # the single field's own rules (`multiple: false` — a built-in such as
  # `:email` goes through its module's `cast/2`), repeats dropped *after*
  # coercion (so `#FFF` and `#ffffff` are one colour) unless the type keeps
  # them (numbers), order kept. An item that is not a string or a number, or
  # a string holding a JSON-encoded list, is refused rather than stored.
  defp coerce_items(value, %{field_type: type} = def) do
    raw = value |> List.wrap() |> Enum.reject(&blank?/1)
    {_items, others} = Enum.split_with(raw, &(is_binary(&1) or is_number(&1)))

    cond do
      others != [] ->
        {:error, "must be a list of values (got #{inspect(hd(others))})"}

      Enum.any?(raw, &json_list?(trim_item(&1))) ->
        {:error, "holds a JSON-encoded list — send the items as a list instead"}

      true ->
        with {:ok, items} <- coerce_each(raw, Map.put(def, :multiple, false)) do
          {:ok, if(ScalarLists.distinct?(type), do: Enum.uniq(items), else: items)}
        end
    end
  end

  # Each item coerced as the single field (`single`) would coerce it, in
  # order; the first refusal is named by its position.
  defp coerce_each(raw, single) do
    raw
    |> Enum.flat_map(&split_item/1)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {item, position}, {:ok, acc} ->
      case coerce(item, single) do
        {:ok, coerced} -> {:cont, {:ok, [coerced | acc]}}
        {:error, message} -> {:halt, {:error, "item #{position} #{message}"}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp split_item(item) when is_binary(item) do
    item
    |> String.split(~r/\R/u)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_item(item), do: [item]

  defp trim_item(item) when is_binary(item), do: String.trim(item)
  defp trim_item(item), do: item

  defp check_terms(terms, def) do
    line = KilnCMS.Limits.line()

    cond do
      Enum.any?(terms, &json_list?/1) ->
        {:error, "holds a JSON-encoded list — send the terms as a list instead"}

      Enum.any?(terms, &(String.length(&1) > line)) ->
        {:error, "has a term longer than #{line} characters"}

      not Map.get(def, :allow_custom, false) and Enum.any?(terms, &(&1 not in def.options)) ->
        stray = Enum.reject(terms, &(&1 in def.options))
        {:error, "has terms that are not allowed options: #{Enum.join(stray, ", ")}"}

      true ->
        {:ok, terms}
    end
  end

  defp json_list?("[" <> _ = term), do: match?({:ok, list} when is_list(list), Jason.decode(term))
  defp json_list?(_term), do: false

  # A media field: the editor submits a MediaItem id; the stored value is a
  # snapshot (`KilnCMS.Media.Snapshot`: id, url, alt, dimensions, focal point,
  # variants) resolved at write time, so delivery needs no extra lookup — the
  # same embed-at-write-time stance image blocks take. Re-saving refreshes the
  # snapshot (see that module for what else does). Accepts a previously stored map too
  # (API writers may round-trip the stored shape). Scoped to the writing tenant
  # so a media reference can't point across sites (epic #336).
  defp coerce_media(value, _def, read_opts) do
    with {:ok, id} <- extract_id(value),
         {:ok, media} <- KilnCMS.CMS.get_media_item(id, read_opts) do
      {:ok, KilnCMS.Media.Snapshot.of(media)}
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
       |> Enum.map(&KilnCMS.Media.Snapshot.of/1)}
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

  # A problem inside a group, named in the message by its path rather than
  # the field's name. `value` stays the group's name: it is what the editor
  # files a custom-field error under.
  defp path_error(def, {_path, _label, {:full, text}}) do
    InvalidAttribute.exception(field: :custom_fields, message: text, value: def.name)
  end

  defp path_error(def, {path, label, message}) do
    InvalidAttribute.exception(
      field: :custom_fields,
      message: "#{label} (#{path}) #{message}",
      value: def.name
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
