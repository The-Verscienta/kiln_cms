defmodule KilnCMS.I18n.Validations.SharedFieldsReadOnly do
  @moduledoc """
  Refuses a write that changes a `:shared` field on a **translation** (#1860).

  A shared field is owned by the source variant (the default-locale row) and
  copied into every translation when the source publishes
  (`KilnCMS.I18n.SharedFields`). The editor shows it read-only on a
  translation, but the API did not: a JSON:API or GraphQL `PATCH` could set it,
  the write succeeded, and the source's next publish quietly put the source's
  value back. The client was never told, and its value was lost later. This
  makes the API say what the editor says, as a validation error naming the
  field and the locale that owns it.

  ## What is refused

  On a variant whose locale is not the source locale, a value the caller
  wrote into a shared field is refused when **both**:

    * it **differs from the variant's current value** — re-sending what is
      already stored passes, so a client that reads a record and writes the
      whole thing back is not refused; and
    * it **differs from what the next sync would write** — the source's
      current value. Setting a translation to the source's value passes.

  Together those refuse exactly the values the next sync would overwrite,
  and nothing else. A translation created before a field became `:shared`
  holds its own value until the source next publishes; it stays editable in
  every other respect, because a write that leaves the old value alone is not
  refused for it. The value is compared with the source's *current* row in
  whatever state it is in: a sync only runs once the source is published, but
  whatever it copies then is owned by the source, not by this variant.

  Nothing is refused when there is no source variant, since then nothing will
  overwrite the value.

  ## Per kind of field

    * **Record attributes** the type shares (`FieldLocalization.attributes/1`):
      any that this write changes.
    * **Custom fields** whose definition is `:shared`: only the keys the
      caller **supplied** (`ApplyCustomFields.supplied_keys/1`), compared
      after coercion, present-or-absent like the sync's own copy. A default
      `ApplyCustomFields` fills into a key the payload never named, and a
      `:computed` field's value, are the engine's, not the caller's.
    * **Block fields** declared `localized: :shared`: matched by block `_id`
      and module, the way the sync matches them. A field on a block the
      source does not hold (or holds as another type) is never overwritten, so
      it is never refused.

  ## Where it runs

  On the actions that take content input on an existing row: `:update` (the
  JSON:API `PATCH`, the GraphQL `update*` mutations, and every code path
  through the `update_*` interfaces), `:autosave`, and `:save_working_copy`
  (option `blocks: :working_blocks`, for the held body; the held settings are
  judged by `:update` itself through `Changes.StageWorkingFields`' probe, so
  they meet this check there). The internal `:sync_shared_fields` action does
  not carry it — it is the write that is *meant* to change these fields — and
  a source variant's writes never meet it.

  Not on `:create`: a create has no current value to compare with, and the
  paths that create a variant in bulk (a content import, a restore) carry
  whatever the exported pair held, which for a pair that predates the field
  becoming shared differs legitimately. See `docs/localization-workflows.md`,
  "Limits".
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.Changes.ApplyCustomFields
  alias KilnCMS.CMS.WorkingCopy
  alias KilnCMS.I18n.FieldLocalization
  alias KilnCMS.I18n.SharedFields

  @impl true
  def init(opts) do
    case Keyword.get(opts, :blocks, :blocks) do
      attr when attr in [:blocks, :working_blocks] -> {:ok, Keyword.put(opts, :blocks, attr)}
      other -> {:error, "blocks: must be :blocks or :working_blocks, got: #{inspect(other)}"}
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "compares against the source variant, which is another row"}

  @impl true
  def validate(%{action_type: :update} = changeset, opts, _context) do
    locale = Ash.Changeset.get_attribute(changeset, :locale)

    if locale == FieldLocalization.source_locale() do
      :ok
    else
      changeset
      |> candidates(opts[:blocks])
      |> refuse(%{changeset.data | locale: locale})
    end
  end

  def validate(_changeset, _opts, _context), do: :ok

  # ── What this write changes ────────────────────────────────────────────────
  # Cheap and read-free, so a write that touches no shared field (every write
  # on a site that shares nothing) never reads the source.

  defp candidates(changeset, blocks_attr) do
    attribute_candidates(changeset) ++
      custom_field_candidates(changeset) ++ block_candidates(changeset, blocks_attr)
  end

  defp attribute_candidates(changeset) do
    for name <- FieldLocalization.attributes(changeset.resource).shared,
        Ash.Changeset.changing_attribute?(changeset, name),
        value <- [Ash.Changeset.get_attribute(changeset, name)],
        value != Map.get(changeset.data, name),
        do: {:attribute, name, value}
  end

  defp custom_field_candidates(changeset) do
    with true <- Ash.Changeset.changing_attribute?(changeset, :custom_fields),
         supplied when is_list(supplied) <- ApplyCustomFields.supplied_keys(changeset) do
      written = Ash.Changeset.get_attribute(changeset, :custom_fields) || %{}
      current = changeset.data.custom_fields || %{}

      for key <- shared_custom_fields(changeset),
          key in supplied,
          value <- [Map.fetch(written, key)],
          value != Map.fetch(current, key),
          do: {:custom_field, key, value}
    else
      _not_written -> []
    end
  end

  # Shared, and not `:computed`: a computed value is derived on every write
  # from the variant's own document, never supplied.
  defp shared_custom_fields(changeset) do
    definitions =
      ApplyCustomFields.stashed_definitions(changeset) ||
        ApplyCustomFields.definitions(
          changeset.resource,
          Ash.Changeset.get_attribute(changeset, :type_definition_id),
          changeset.to_tenant
        )

    for %{name: name, localization: :shared, field_type: type} <- definitions,
        type != :computed,
        do: name
  end

  defp block_candidates(changeset, attr) do
    if Ash.Changeset.changing_attribute?(changeset, attr) do
      current = changeset |> current_blocks(attr) |> by_id()

      for block <- Ash.Changeset.get_attribute(changeset, attr) || [],
          %module{id: id} = value <- [value(block)],
          is_binary(id),
          name <- shared_block_fields(module),
          new <- [Map.get(value, name)],
          changed_block_field?(Map.get(current, id), module, name, new),
          do: {:block, attr, id, module, name, new}
    else
      []
    end
  end

  # The body the held copy is edited from: the copy while one is pending, the
  # live body before the first save opens one.
  defp current_blocks(changeset, :working_blocks) do
    if WorkingCopy.pending?(changeset.data),
      do: changeset.data.working_blocks || [],
      else: changeset.data.blocks || []
  end

  defp current_blocks(changeset, :blocks), do: changeset.data.blocks || []

  defp changed_block_field?(%module{} = current, module, name, new),
    do: Map.get(current, name) != new

  # A new block, or one whose type changed under the same id: there is no
  # current value, so any value is a change.
  defp changed_block_field?(_current, _module, _name, _new), do: true

  # ── Against the source ─────────────────────────────────────────────────────

  defp refuse([], _record), do: :ok

  defp refuse(candidates, record) do
    case SharedFields.source(record) do
      nil ->
        :ok

      source ->
        source_blocks = by_id(source.blocks || [])

        case Enum.reject(candidates, &matches_source?(&1, source, source_blocks)) do
          [] -> :ok
          refused -> {:error, Enum.map(refused, &error(&1, source.locale))}
        end
    end
  end

  defp matches_source?({:attribute, name, value}, source, _blocks),
    do: value == Map.get(source, name)

  defp matches_source?({:custom_field, key, value}, source, _blocks),
    do: value == Map.fetch(source.custom_fields || %{}, key)

  # The sync copies a block field only from the source block with the same id
  # and type; with no such block, nothing will overwrite this value.
  defp matches_source?({:block, _attr, id, module, name, value}, _source, blocks) do
    case Map.get(blocks, id) do
      %^module{} = from -> value == Map.get(from, name)
      _no_counterpart -> true
    end
  end

  # ── Errors ─────────────────────────────────────────────────────────────────

  defp error({:attribute, name, value}, locale) do
    InvalidAttribute.exception(field: name, message: "#{name} #{owned_by(locale)}", value: value)
  end

  defp error({:custom_field, key, _value}, locale) do
    InvalidAttribute.exception(
      field: :custom_fields,
      message: "\"#{key}\" #{owned_by(locale)}",
      value: key
    )
  end

  defp error({:block, attr, id, module, name, _value}, locale) do
    InvalidAttribute.exception(
      field: attr,
      message: "#{block_type(module)}.#{name} (block #{id}) #{owned_by(locale)}",
      value: id
    )
  end

  defp owned_by(locale) do
    "is shared across this document's locales and can only be changed on the " <>
      "#{locale} version; set it there and it is copied here when that version publishes"
  end

  defp block_type(module), do: Kiln.Block.Info.name(module)

  # ── Blocks ─────────────────────────────────────────────────────────────────

  defp by_id(blocks) do
    for block <- blocks, %{id: id} = value <- [value(block)], into: %{}, do: {id, value}
  end

  defp shared_block_fields(module),
    do: for({name, :shared} <- FieldLocalization.block_fields(module), do: name)

  defp value(%Ash.Union{value: value}), do: value
  defp value(%_{} = value), do: value
  defp value(_other), do: nil
end
