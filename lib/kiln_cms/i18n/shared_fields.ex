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
    * block fields declared `localized: :shared`, on top-level blocks and on
      blocks nested inside `columns` at any depth, addressed by the block
      `_id` the variants share (`ContentCopy` keeps ids at every depth on the
      translation path). A block the sibling no longer holds, or whose `_type`
      differs, is skipped. Top-level blocks are read through the block union's
      `cast_stored` and nested children through `TypedBlocks.to_typed/1`; both
      upcast every block to its current version, so the two sides are
      compared at the same schema version. A nested child is rewritten only
      when one of its shared values changes;
    * the **tags**, when the type shares `:tags` (#1859): the source's tag set,
      as tag ids — a tag has no locale, so the references are copied and no
      tag is touched;
    * the curated **related content**, when the type shares `:related`
      (#1859): each of the source's targets resolved to its document's variant
      in the sibling's locale, or the first variant along the site's fallback
      chain (#1579), in the source's order (`resolve_related/6`). A target
      with no variant on the chain is left out.

  ## The sibling's working copy (#1815)

  A published sibling with a pending working copy gets the value in the copy
  too — `working_blocks` (nested children included), and any held field in
  `working_fields` — so its next
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

  alias KilnCMS.CMS.ContentLinks
  alias KilnCMS.CMS.WorkingCopy
  alias KilnCMS.I18n.Fallback
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
  `only:` limits the copy to the sibling with that id, `attributes:`
  overrides the record-attribute modes the source's type declares (see
  `plan/5`), and `relationships:` the relationships it shares. Returns the
  number of siblings written.
  """
  @spec sync(struct(), [struct()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sync(source, definitions, opts \\ [])

  def sync(%{state: :published} = source, definitions, opts) do
    only = Keyword.get(opts, :only)

    attributes =
      Keyword.get_lazy(opts, :attributes, fn -> FieldLocalization.attributes(source) end)

    relationships =
      Keyword.get_lazy(opts, :relationships, fn -> FieldLocalization.relationships(source) end)

    siblings = source |> siblings() |> Enum.filter(&(is_nil(only) or &1.id == only))
    links = if siblings == [], do: %{}, else: links(source, relationships)

    Enum.reduce_while(siblings, {:ok, 0}, fn sibling, {:ok, written} ->
      case sync_one(sibling, plan(source, sibling, definitions, attributes, links)) do
        :unchanged -> {:cont, {:ok, written}}
        {:ok, _updated} -> {:cont, {:ok, written + 1}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  def sync(_source, _definitions, _opts), do: {:ok, 0}

  defp sync_one(_sibling, changes) when changes == %{}, do: :unchanged
  defp sync_one(sibling, changes), do: write(sibling, changes)

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
  working-copy columns when the sibling has a pending copy, and `:tags` /
  `:related` (lists of ids) when a shared relationship differs.

  `modes` are the record-attribute modes, `%{shared: [...], fallback: [...]}`
  — by default what the source's type declares. `links` is the source's
  shared relationships as `links/2` reads them; `%{}` shares none.
  """
  @spec plan(struct(), struct(), [struct()], map() | nil, map()) :: %{atom() => term()}
  def plan(source, sibling, definitions, modes \\ nil, links \\ %{}) do
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
      |> put_links(links, sibling)

    if changes != %{} and WorkingCopy.pending?(sibling),
      do: Map.merge(changes, working_copy(sibling, changes, source, shared_custom)),
      else: changes
  end

  # ── Shared relationships (#1859) ───────────────────────────────────────────

  @doc """
  What `source` shares of its relationships, read once per sync:
  `%{tags: [tag_id]}` (sorted, a set) and `%{related: {targets, chains}}`
  (the targets in the source's order, with the site's fallback chains), each
  only when `relationships` names it.
  """
  @spec links(struct(), [atom()]) :: map()
  def links(source, relationships) do
    Enum.reduce(relationships, %{}, fn
      :tags, acc ->
        Map.put(acc, :tags, tag_ids(source))

      :related, acc ->
        Map.put(acc, :related, {related_targets(source), Fallback.chains(source.org_id)})

      _other, acc ->
        acc
    end)
  end

  defp put_links(changes, links, sibling) do
    changes
    |> put_tags(Map.fetch(links, :tags), sibling)
    |> put_related(Map.fetch(links, :related), sibling)
  end

  defp put_tags(changes, {:ok, wanted}, sibling) do
    if tag_ids(sibling) == wanted, do: changes, else: Map.put(changes, :tags, wanted)
  end

  defp put_tags(changes, :error, _sibling), do: changes

  defp put_related(changes, {:ok, {targets, chains}}, sibling) do
    wanted =
      resolve_related(sibling.__struct__, targets, sibling.locale, chains, sibling.org_id,
        except: sibling.id
      )

    if related_ids(sibling) == wanted, do: changes, else: Map.put(changes, :related, wanted)
  end

  defp put_related(changes, :error, _sibling), do: changes

  @doc "`record`'s tag ids, sorted — the tags are a set."
  @spec tag_ids(struct()) :: [String.t()]
  def tag_ids(record) do
    record
    # authorize?: false — ids only, of a document this sync (or a write
    # already authorized on it) is about; nothing read leaves the copy.
    |> Ash.load!([tags: Ash.Query.select(KilnCMS.CMS.Tag, [:id])],
      authorize?: false,
      tenant: record.org_id,
      lazy?: false
    )
    |> Map.fetch!(:tags)
    |> Enum.map(&to_string(&1.id))
    |> Enum.sort()
  end

  @doc "`record`'s curated related targets' ids, in the related list's order."
  @spec related_ids(struct()) :: [String.t()]
  def related_ids(record),
    do: record |> ContentLinks.related_order() |> Enum.map(&to_string/1)

  @doc """
  `record`'s curated related targets, in order, as the rows `resolve_related/6`
  matches documents by. A link to a target that has since been trashed is
  left out.
  """
  @spec related_targets(struct()) :: [struct()]
  def related_targets(%module{} = record) do
    case related_ids(record) do
      [] ->
        []

      ids ->
        rows =
          module
          |> Ash.Query.filter(id in ^ids)
          |> Ash.Query.select(document_fields(module))
          # authorize?: false — the targets' document identity only (slug,
          # type, locale), to match them across locales; see `siblings/1`.
          |> Ash.read!(tenant: record.org_id, authorize?: false)
          |> Map.new(&{to_string(&1.id), &1})

        for id <- ids, row = Map.get(rows, id), do: row
    end
  end

  @doc """
  The ids a shared related list holds on a variant of `resource` in `locale`:
  each of `targets` (rows of `resource`, in order) resolved to its document's
  variant in `locale`, or else the first variant along
  `Fallback.chain(chains, locale, :site)` (#1579). A target whose document has
  no variant on the chain is left out; two targets that resolve to the same
  variant are linked once, at the first one's place.

  `except:` drops one id — the variant being written, which cannot be its
  own related content.
  """
  @spec resolve_related(module(), [struct()], String.t(), term(), term(), keyword()) :: [
          String.t()
        ]
  def resolve_related(resource, targets, locale, chains, org_id, opts \\ [])

  def resolve_related(_resource, [], _locale, _chains, _org_id, _opts), do: []

  def resolve_related(resource, targets, locale, chains, org_id, opts) do
    chain = Fallback.chain(chains, locale, :site)
    slugs = targets |> Enum.map(& &1.slug) |> Enum.uniq()
    except = opts |> Keyword.get(:except) |> then(&(&1 && to_string(&1)))

    variants =
      resource
      |> Ash.Query.filter(slug in ^slugs and locale in ^chain)
      |> Ash.Query.select(document_fields(resource))
      # authorize?: false — as `related_targets/1`: which variants exist, by
      # document identity, and nothing read leaves the copy but their ids.
      |> Ash.read!(tenant: org_id, authorize?: false)
      |> Enum.group_by(&document/1)

    targets
    |> Enum.flat_map(&variant_along(Map.get(variants, document(&1), []), chain))
    |> Enum.reject(&(&1 == except))
    |> Enum.uniq()
  end

  # The id of the first of a document's `rows` along `chain`, as a list of
  # zero or one.
  defp variant_along(rows, chain) do
    case Enum.find_value(chain, fn locale -> Enum.find(rows, &(&1.locale == locale)) end) do
      nil -> []
      variant -> [to_string(variant.id)]
    end
  end

  # What names a document across its variants: the slug, and on the entry
  # tier the type definition (the identity `[type_definition_id, slug, locale]`).
  defp document(row), do: {row.slug, Map.get(row, :type_definition_id)}

  defp document_fields(resource) do
    if Ash.Resource.Info.attribute(resource, :type_definition_id),
      do: [:id, :slug, :locale, :type_definition_id],
      else: [:id, :slug, :locale]
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
  # The target tree with each shared field of each block, top-level or nested
  # inside `columns`, replaced by the source's value for the block with the
  # same id and type, wherever in the source's tree that block sits.
  def copy_block_fields(source_blocks, target_blocks) do
    by_id = FieldLocalization.blocks_by_id(source_blocks)

    {blocks, nil} =
      FieldLocalization.map_reduce_block_fields(target_blocks, nil, fn %module{} = value, nil ->
        {shared_changes(value, module, Map.get(by_id, Map.get(value, :id))), nil}
      end)

    blocks
  end

  # Only the fields that differ, so a nested child whose shared values already
  # match is left exactly as stored.
  defp shared_changes(value, module, %module{} = from) do
    for name <- shared_block_fields(module),
        Map.get(from, name) != Map.get(value, name),
        into: %{},
        do: {name, Map.get(from, name)}
  end

  defp shared_changes(_value, _module, _from), do: %{}

  defp shared_block_fields(module),
    do: for({name, :shared} <- FieldLocalization.block_fields(module), do: name)

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

        {link, ids}, acc when link in [:tags, :related] ->
          hold_link(acc, link_key(resource, link), ids)

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

  # A held tag set or related list is replaced by the shared one, as a held
  # shared attribute is; one the copy does not hold stays unheld.
  defp hold_link(held, key, ids) do
    if key && Map.has_key?(held, key),
      do: Map.put(held, key, ids),
      else: held
  end

  # Each recorded base that was the old live value moves to the new one.
  defp rebase(sibling, changes) do
    resource = sibling.__struct__

    Enum.reduce(changes, WorkingCopy.base_fingerprints(sibling), fn {name, value}, base ->
      rebase_key(base, sibling, base_key(resource, name), value)
    end)
  end

  defp rebase_key(base, _sibling, nil, _value), do: base

  defp rebase_key(base, sibling, key, value) do
    if Map.get(base, key) == WorkingCopy.live_fingerprint(sibling, key),
      do: Map.put(base, key, WorkingCopy.fingerprint(sibling.__struct__, key, value)),
      else: base
  end

  defp base_key(resource, link) when link in [:tags, :related], do: link_key(resource, link)
  defp base_key(_resource, name), do: to_string(name)

  # The working copy's key for a shared relationship: its complete-set
  # argument, `"tag_ids"` or `"related_<type>_ids"`.
  defp link_key(resource, link) do
    Enum.find_value(WorkingCopy.held_relationships(resource), fn {argument, relationship} ->
      if relationship_link(relationship) == link, do: to_string(argument)
    end)
  end

  defp relationship_link(:tags), do: :tags

  defp relationship_link(relationship) do
    if String.starts_with?(to_string(relationship), "related_"), do: :related
  end
end
