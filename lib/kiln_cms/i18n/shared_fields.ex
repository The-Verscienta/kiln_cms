defmodule KilnCMS.I18n.SharedFields do
  @moduledoc """
  Copies a document's `:shared` field values from its **source variant** (the
  default-locale row) into every other locale variant (#1327, Design A in
  `docs/field-level-localization.md`).

  A shared value is copied, not resolved at read time, so every variant row
  stays self-contained: search, firing, the sync API and version history all
  see correct data without learning that siblings exist.

  ## When

  When the source **publishes** — `:publish`, `:publish_scheduled`,
  `:publish_changes`, or a live edit through `:update` — and when a sibling
  publishes (it takes the source's current values then). A source that is not
  published shares nothing: copying a draft's value into a live sibling would
  publish it by the back door. `KilnCMS.I18n.SharedFieldsWorker` runs the copy
  off the request path.

  ## What is copied

    * record attributes the type's `localization:` option lists as `shared:`;
    * custom fields whose definition's `localization` is `:shared`;
    * top-level block fields declared `localized: :shared`, addressed by the
      block `_id` the variants share (`ContentCopy` keeps ids on the
      translation path). A block the sibling no longer holds, or whose `_type`
      differs, is skipped. Both trees are read through the block union's
      `cast_stored`, which upcasts every block to its current version, so the
      two sides are compared at the same schema version.

  ## The sibling's working copy (#1815)

  A published sibling with a pending working copy gets the value in the copy
  too — `working_blocks`, and any held field in `working_fields` — so its next
  *Publish changes* does not put the old value back. The copy's recorded base
  (`working_base`) is moved to the new live value for each key whose base was
  the old live value, so the lost-update guard does not report the copy as a
  conflict with a change nobody made by hand.

  The write is the content resource's internal `:sync_shared_fields` action,
  under the `:localization` system actor. It writes a version, so the sync
  delta API reports the sibling as an upsert, and a published sibling is
  re-fired.
  """

  require Ash.Query

  alias KilnCMS.CMS.WorkingCopy
  alias KilnCMS.I18n.FieldLocalization

  @doc """
  Every variant of `record`'s document except `record` itself: same slug (and,
  on the entry tier, the same type definition), any workflow state, trashed
  rows excluded.
  """
  @spec siblings(struct()) :: [struct()]
  def siblings(%module{org_id: org_id, slug: slug, locale: locale} = record) do
    module
    |> Ash.Query.filter(slug == ^slug and locale != ^locale)
    |> scope_to_type(record)
    # authorize?: false — a background write path with no actor, pinned to
    # this tenant and this document's slug. The system actor holds no content
    # read by design (#1402); the write itself goes through the policy.
    |> Ash.read!(tenant: org_id, authorize?: false)
  end

  defp scope_to_type(query, %{type_definition_id: id}) when is_binary(id),
    do: Ash.Query.filter(query, type_definition_id == ^id)

  defp scope_to_type(query, _record), do: query

  @doc """
  The source variant of `record`'s document: `record` itself when it is in the
  default locale, else the default-locale sibling. `nil` when there is none.
  """
  @spec source(struct()) :: struct() | nil
  def source(record) do
    if FieldLocalization.source?(record),
      do: record,
      else: record |> siblings() |> Enum.find(&FieldLocalization.source?/1)
  end

  @doc """
  Copy the published `source`'s shared values into each sibling that differs.
  `only:` limits the copy to the sibling with that id, and `attributes:`
  overrides the record-attribute modes the source's type declares (see
  `plan/4`). Returns the number of siblings written.
  """
  @spec sync(struct(), [struct()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sync(source, definitions, opts \\ [])

  def sync(%{state: :published} = source, definitions, opts) do
    only = Keyword.get(opts, :only)

    attributes =
      Keyword.get_lazy(opts, :attributes, fn -> FieldLocalization.attributes(source) end)

    source
    |> siblings()
    |> Enum.filter(&(is_nil(only) or &1.id == only))
    |> Enum.reduce_while({:ok, 0}, fn sibling, {:ok, written} ->
      case plan(source, sibling, definitions, attributes) do
        changes when changes == %{} ->
          {:cont, {:ok, written}}

        changes ->
          case write(sibling, changes) do
            {:ok, _updated} -> {:cont, {:ok, written + 1}}
            {:error, error} -> {:halt, {:error, error}}
          end
      end
    end)
  end

  def sync(_source, _definitions, _opts), do: {:ok, 0}

  defp write(sibling, changes) do
    sibling
    |> Ash.Changeset.for_update(:sync_shared_fields, %{},
      context: %{shared_fields: changes},
      actor: KilnCMS.SystemActor.new(:localization),
      tenant: sibling.org_id
    )
    |> Ash.update()
  end

  @doc """
  The attribute values a sync would write onto `sibling`, keyed by attribute
  — `%{}` when it already carries the source's shared values. Includes the
  working-copy columns when the sibling has a pending copy.

  `modes` are the record-attribute modes, `%{shared: [...], fallback: [...]}`
  — by default what the source's type declares.
  """
  @spec plan(struct(), struct(), [struct()], map() | nil) :: %{atom() => term()}
  def plan(source, sibling, definitions, modes \\ nil) do
    modes = modes || FieldLocalization.attributes(source)

    attributes =
      for name <- modes.shared,
          Map.get(source, name) != Map.get(sibling, name),
          into: %{},
          do: {name, Map.get(source, name)}

    shared_custom = for {name, :shared} <- FieldLocalization.custom_fields(definitions), do: name

    changes =
      attributes
      |> put_custom_fields(source, sibling, shared_custom)
      |> put_blocks(:blocks, source.blocks, sibling.blocks)

    if changes != %{} and WorkingCopy.pending?(sibling),
      do: Map.merge(changes, working_copy(sibling, changes, source, shared_custom)),
      else: changes
  end

  defp put_custom_fields(changes, source, sibling, shared) do
    current = sibling.custom_fields || %{}
    updated = copy_keys(current, source.custom_fields || %{}, shared)

    if updated == current, do: changes, else: Map.put(changes, :custom_fields, updated)
  end

  defp copy_keys(target, from, keys) do
    Enum.reduce(keys, target, fn key, acc ->
      case Map.fetch(from, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> Map.delete(acc, key)
      end
    end)
  end

  defp put_blocks(changes, key, source_blocks, target_blocks) do
    target_blocks = target_blocks || []
    updated = copy_block_fields(source_blocks || [], target_blocks)

    if updated == target_blocks, do: changes, else: Map.put(changes, key, updated)
  end

  @doc false
  # The target tree with each shared field of each block replaced by the
  # source's value for the block with the same id and type.
  def copy_block_fields(source_blocks, target_blocks) do
    by_id =
      for block <- source_blocks,
          %{id: id} = value <- [value(block)],
          into: %{},
          do: {id, value}

    Enum.map(target_blocks, fn block ->
      with %module{id: id} = value <- value(block),
           shared when shared != [] <- shared_block_fields(module),
           %^module{} = from <- Map.get(by_id, id) do
        put_value(block, Enum.reduce(shared, value, &Map.put(&2, &1, Map.get(from, &1))))
      else
        _untouched -> block
      end
    end)
  end

  defp shared_block_fields(module),
    do: for({name, :shared} <- FieldLocalization.block_fields(module), do: name)

  defp value(%Ash.Union{value: value}), do: value
  defp value(%_{} = value), do: value
  defp value(_other), do: nil

  defp put_value(%Ash.Union{} = union, value), do: %{union | value: value}
  defp put_value(_block, value), do: value

  # The working-copy half of a sync onto a sibling with a pending copy.
  defp working_copy(sibling, changes, source, shared_custom) do
    resource = sibling.__struct__
    held = WorkingCopy.held_fields(sibling)

    working_blocks =
      if Map.has_key?(changes, :blocks),
        do: copy_block_fields(source.blocks || [], sibling.working_blocks || []),
        else: sibling.working_blocks

    working_fields =
      Enum.reduce(changes, held, fn
        {:blocks, _value}, acc ->
          acc

        {:custom_fields, _value}, acc ->
          case Map.fetch(acc, "custom_fields") do
            {:ok, held_map} when is_map(held_map) ->
              Map.put(
                acc,
                "custom_fields",
                copy_keys(held_map, source.custom_fields || %{}, shared_custom)
              )

            _not_held ->
              acc
          end

        {name, value}, acc ->
          key = to_string(name)

          if Map.has_key?(acc, key),
            do: Map.put(acc, key, WorkingCopy.dump(resource, name, value)),
            else: acc
      end)

    %{
      working_blocks: working_blocks,
      working_fields: working_fields,
      working_base: rebase(sibling, changes)
    }
  end

  # Each recorded base that was the old live value moves to the new one.
  defp rebase(sibling, changes) do
    resource = sibling.__struct__

    Enum.reduce(changes, WorkingCopy.base_fingerprints(sibling), fn {name, value}, base ->
      key = to_string(name)

      case Map.fetch(base, key) do
        {:ok, fingerprint} ->
          if fingerprint == WorkingCopy.live_fingerprint(sibling, key),
            do: Map.put(base, key, WorkingCopy.fingerprint(resource, key, value)),
            else: base

        :error ->
          base
      end
    end)
  end
end
