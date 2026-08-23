defmodule KilnCMS.CMS.ContentCopy do
  @moduledoc """
  Shared mechanics for copying one content record's authored payload into a
  **brand-new** record.

  Two features clone content: the one-click translation
  (`KilnCMS.CMS.Translations`, into a new locale) and the duplicate action
  (`KilnCMS.CMS.Duplication`, into a new draft of the same locale). They differ
  in what identifies the copy — a translation keeps the slug and changes the
  locale, a duplicate keeps the locale and regenerates the slug — but the
  payload in between is the same, and so are the parts that are easy to get
  wrong:

    * **blocks** must go back through the union's storage shape so the create
      action re-casts (and re-sanitizes) them. A duplicate strips their stable
      ids at *every* depth, since `columns` children carry ids of their own, so
      it gets fresh ones; a translation keeps them (`:keep_ids?` on
      `dump_blocks/2`), because a locale variant is the same document in
      another language;
    * **tags** are a `manage_relationship` argument on `:create`, not an
      attribute, so they travel as an id list — and the load that reads them
      must project ids only, or one click drags every tag's full row into the
      caller's heap.

  Everything here is payload-only. Workflow (`state`, schedules), delivery
  bookkeeping (published version, artifacts) and history start fresh on the
  copy, by virtue of simply not being copied. Curated **related content** is
  not here either: those rows carry a per-link payload (`kind`, `position`,
  `label`, `metadata`) that the `related_<type>_ids` argument would flatten, so
  `KilnCMS.CMS.Duplication` clones the `ContentLink` rows themselves.
  """

  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Tag

  # The authored content attributes shared by every clone. Deliberately absent:
  # `slug`/`locale` (each caller decides — they're what identifies the copy),
  # `canonical_url` (points at the *source*'s canonical URL, never the copy's),
  # `path_alias` (re-derived from the type's alias pattern), and every workflow
  # / scheduling column.
  @content_attrs [
    :title,
    :excerpt,
    :seo_title,
    :seo_description,
    :seo_keywords,
    :seo_image,
    :audience,
    :custom_fields,
    :category_id,
    :featured_image_id
  ]

  @doc """
  The authored content attributes every clone carries (see the module doc for
  what is deliberately excluded).
  """
  @spec content_attrs() :: [atom()]
  def content_attrs, do: @content_attrs

  @doc """
  The caller's `opts`, plus the context a clone's create needs.

  `custom_fields: :drop` — what is being copied is a whole *stored* map, which
  may still hold a key whose `FieldDefinition` was deleted before
  `CMS.Changes.SyncFieldValues` existed to scrub it. A clone is not where that
  gets litigated: refusing the key would fail the entire copy over a value the
  source is sitting on, so the copy drops it (with a warning) exactly as an
  ordinary save of the source would.
  """
  @spec create_opts(keyword()) :: keyword()
  def create_opts(opts) do
    Keyword.update(
      opts,
      :context,
      %{custom_fields: :drop},
      &Map.put(&1, :custom_fields, :drop)
    )
  end

  @doc """
  The acting editor's per-field write grant for `source`'s type — `nil` when no
  restriction applies, otherwise the attribute names they may write.

  Cloning is the one kind of create that carries **another record's** values,
  which is why it has to ask. `Changes.EnforceFieldGrants` deliberately skips
  creates (authoring a *new* document is gated by `editable_types` instead),
  and that reasoning holds for a document written from scratch — not for one
  arriving pre-filled from a record the actor may only partly write.

  `nil` for an effective admin and for an actor-less internal caller, mirroring
  the policy bypass the change itself respects. Note the shape: `nil` means
  "everything", an empty list means "nothing" — reading one as the other
  inverts the grant, which is how #927 happened.
  """
  @spec field_grant(struct(), keyword()) :: [String.t()] | nil
  def field_grant(source, opts) do
    actor = Keyword.get(opts, :actor)
    subject = Keyword.get(opts, :tenant)

    with %{} <- actor,
         :editor <- Scoping.effective_tier(actor, subject) do
      Scoping.field_grant(actor, subject, ContentTypes.type_name_for(source))
    else
      _ -> nil
    end
  end

  @doc """
  `attrs` filtered to what `grant` permits, plus the names it dropped.

  `exempt` attributes survive a grant that does not name them, and each caller
  has its own reasons — see `KilnCMS.CMS.Duplication` and
  `KilnCMS.CMS.Translations`, which both state theirs. They are not reported as
  withheld, because they were not withheld.
  """
  @spec permitted([atom()], [String.t()] | nil, [atom()]) :: {[atom()], [String.t()]}
  def permitted(attrs, nil, _exempt), do: {attrs, []}

  def permitted(attrs, grant, exempt) do
    {kept, dropped} =
      Enum.split_with(attrs, &(&1 in exempt or to_string(&1) in grant))

    {kept, Enum.map(dropped, &to_string/1)}
  end

  @doc """
  The load a caller must request so `tag_ids/1` sees a real list rather than
  `%Ash.NotLoaded{}` — projected to ids, because that is all it reads.
  """
  @spec tag_load() :: keyword()
  def tag_load, do: [tags: Ash.Query.select(Tag, [:id])]

  @doc """
  `record`'s values for `keys`, as create-action attrs. `nil` values are
  dropped rather than sent, so the create action's own defaults apply.
  """
  @spec take(struct(), [atom()]) :: map()
  def take(record, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case Map.get(record, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  @doc """
  `record`'s block tree, dumped back to the union's storage shape so the create
  action re-casts it, with every block's stable id stripped so the copy mints
  fresh ones.

  `:keep_ids?` suppresses the strip. Only the translation path passes it, and
  only because a locale variant is the *same document in another language*:
  it is what lets a translation vendor's XLIFF file (#502) address a paragraph
  by identity instead of by position. A **duplicate** is a different document
  and keeps minting fresh ids; that is the whole difference between the two
  callers here.

  Sharing ids is safe because every consumer reads them **inside one record**:
  version folds (`KilnCMS.History`), experiment patches, block comments
  (keyed `(content_type, content_id, block_id)`), the CRDT document key
  (`collab:<type>:<record id>`), and the `_id` a fired `:json` artifact carries.
  There is no unique index on anything derived from a block id.

  The one place that was *not* record-scoped is worth knowing about, because it
  is what this option would otherwise have broken: the visual-editing consoles
  resolved a record by slug alone and then matched the clicked block by id, so
  with shared ids a click on a French page could open — and save into — the
  English record. Both now pin the locale (`KilnCMSWeb.PresentationLive`,
  `KilnCMSWeb.InContextEditLive`), and the presentation console additionally
  refuses a stega payload naming a record other than the one it loaded.

  `:role` resets every block field that role may not edit to its declared
  default, and returns which ones were reset.

  Without it a copy dead-ended. `Changes.EnforceBlockFieldPolicy` runs on create
  as well as update, and on a create there is no stored tree to diff against —
  so `permitted_value/2` falls to the field's **declared default** and every
  admin-set value trips it. An editor duplicating (or translating) a page whose
  `quote` block has `featured: true` got a refusal they could do nothing about,
  on content they were allowed to read (#890).

  Resetting rather than refusing mirrors what duplication already does with
  per-field write grants: the copy carries what the actor could have authored.
  """
  @spec dump_blocks(struct(), keyword()) :: {[map()], [String.t()]}
  def dump_blocks(record, opts \\ []) do
    attribute = Ash.Resource.Info.attribute(record.__struct__, :blocks)

    {:ok, dumped} =
      Ash.Type.dump_to_embedded(attribute.type, record.blocks || [], attribute.constraints)

    {blocks, legacy_notes} =
      dumped
      |> then(fn blocks ->
        if Keyword.get(opts, :keep_ids?, false), do: blocks, else: Enum.map(blocks, &strip_ids/1)
      end)
      |> drop_stale_required()

    {blocks, restricted_notes} = reset_restricted(blocks, Keyword.get(opts, :role))
    {blocks, (legacy_notes ++ restricted_notes) |> Enum.uniq() |> Enum.sort()}
  end

  # A pre-#935 nested child — the shape `columns` children were always stored
  # as, raw maps that skipped Ash validation entirely until #935 added
  # `TypedBlocks.validate_child!` — can already hold `nil` in a field this
  # codebase now declares `required: true`. Before #935 that gap just rode
  # along silently on a duplicate/translate copy; #935 makes the copy's
  # write-time re-cast reject it, hard-failing the *entire* action for any
  # actor (`reset_restricted/2` below is a no-op for `nil` role, i.e. admin —
  # there is nothing here for it to catch).
  #
  # Runs before role-based restriction reset, and independent of role: this is
  # about the *source* value already being invalid, not about who is copying
  # it. Drops only the specific block/child holding the stale `nil`, the same
  # "can't produce a valid value, so remove rather than corrupt" rule
  # `unsafe_reset?/2` already applies to the required + restricted case,
  # rather than failing the whole duplicate/translate write.
  defp drop_stale_required(blocks) do
    Enum.flat_map_reduce(blocks, [], fn block, notes ->
      case block_module(block) do
        nil -> {[block], notes}
        module -> drop_stale_required_block(block, module, notes)
      end
    end)
  end

  defp drop_stale_required_block(%{"value" => value} = block, module, notes) when is_map(value) do
    if stale_required?(value, module) do
      {[], [stale_required_note(module) | notes]}
    else
      {value, notes} = drop_stale_required_nested(value, module, notes)
      {[%{block | "value" => value}], notes}
    end
  end

  defp drop_stale_required_block(block, _module, notes), do: {[block], notes}

  # Only `columns` nests children (see `reset_nested/3`'s note on the same
  # shape), so it is the one module whose children need walking here too.
  defp drop_stale_required_nested(value, KilnCMS.Blocks.Columns, notes) do
    update_field(value, :columns, "columns", fn columns ->
      columns
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map_reduce(notes, &drop_stale_required_column/2)
    end)
  end

  defp drop_stale_required_nested(value, _module, notes), do: {value, notes}

  defp drop_stale_required_column(column, notes) do
    update_field(column, :blocks, "blocks", fn blocks ->
      blocks
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.flat_map_reduce(notes, &drop_stale_required_nested_child/2)
    end)
  end

  defp drop_stale_required_nested_child(child, notes) do
    case nested_child_module(child) do
      nil ->
        {[child], notes}

      module ->
        if stale_required?(child, module) do
          {[], [stale_required_note(module) | notes]}
        else
          {child, notes} = drop_stale_required_nested(child, module, notes)
          {[child], notes}
        end
    end
  end

  defp stale_required?(carrier, module) do
    module
    |> Kiln.Block.Info.fields()
    |> Enum.any?(&(&1.required and is_nil(stale_field_value(carrier, &1.name))))
  end

  # Tolerant of both key shapes `dump_to_embedded` produces: atom keys on a
  # top-level block's own `"value"`, string keys on a nested child (never
  # re-cast until #935's `validate_child!`).
  defp stale_field_value(%{} = map, name), do: Map.get(map, name, Map.get(map, to_string(name)))

  defp stale_required_note(module),
    do: "#{block_name(module)} (dropped: legacy content left a required field nil)"

  # `nil` role = admin, or an actor-less internal caller: nothing is restricted,
  # matching the policy bypass `EnforceBlockFieldPolicy` respects.
  defp reset_restricted(blocks, nil), do: {blocks, []}

  defp reset_restricted(blocks, role) do
    Enum.flat_map_reduce(blocks, [], fn block, reset ->
      case block_module(block) do
        nil -> {[block], reset}
        module -> reset_block(block, module, role, reset)
      end
    end)
    |> then(fn {blocks, reset} -> {blocks, reset |> Enum.uniq() |> Enum.sort()} end)
  end

  # A field this role cannot edit, declared `required: true` with no default,
  # cannot be reset the way an optional restricted field is — there is no
  # default to fall back to (nulling it is not "resetting to the default", it
  # is producing an invalid block: post-#935 `TypedBlocks.validate_child!`
  # refuses a nil there, same as it always has for a top-level block). Rather
  # than let that hard-fail the *entire* duplicate/translate write, the block
  # holding it is dropped from the copy outright and reported withheld,
  # instead of `reset_fields/4` ever being asked to null a field that has no
  # safe null.
  #
  # Rarely reachable today: only one currently-registered block (a test
  # fixture) combines `required: true` with `editable_by:` at all, and this
  # only trips when that combination ALSO has no `default:` — the DSL allows
  # `required: true` (`allow_nil?: false`) and `default:` together, and when
  # both are present `reset_fields/4` can reset the field to its declared
  # default same as any other restricted field, so the block does not need to
  # be dropped (code-review finding #2 on this PR's own review, following
  # #1250's finding #7).
  defp unsafe_reset?(module, role) do
    module
    |> Kiln.Block.Info.fields()
    |> Enum.any?(fn field ->
      field.required and is_nil(field.default) and
        not Kiln.Block.Policy.can_edit_field?(module, field.name, role)
    end)
  end

  defp drop_note(module), do: "#{block_name(module)} (dropped: holds a restricted required field)"

  defp reset_block(%{"value" => value} = block, module, role, reset) when is_map(value) do
    if unsafe_reset?(module, role) do
      {[], [drop_note(module) | reset]}
    else
      {value, reset} = reset_fields(value, module, role, reset)
      {value, reset} = reset_nested(value, module, role, reset)
      {[%{block | "value" => value}], reset}
    end
  end

  defp reset_block(block, _module, _role, reset), do: {[block], reset}

  # `columns` nests its children as raw maps rather than union members (a
  # recursive-type compile cycle), so `dump_blocks/2` never recursed into
  # them — a `columns` block holding a `quote` with `featured: true` hard-
  # refused BOTH duplication and translation for a non-admin, because
  # `Changes.EnforceBlockFieldPolicy.check_nested_tree/3` DOES check them,
  # and the copy handed back the unreset admin-set value verbatim (#1168).
  # This is the same reset `reset_fields/4` already gives top-level blocks,
  # walked to whatever depth `columns` nests (a column may itself hold a
  # `columns` block) — mirroring `KilnCMS.Blocks.Columns.child_maps/1`'s own
  # shape rather than guessing where children live, for the reason #956
  # documents on the enforcement side.
  defp reset_nested(value, KilnCMS.Blocks.Columns, role, reset) do
    # `dump_to_embedded` emits ATOM keys for the block's own attributes — so a
    # TOP-level `columns` block's `value` carries its columns under `:columns`
    # — while nested children are plain maps that never go through it and keep
    # the STRING keys they were cast/stored with (a nested `columns` block's
    # own `columns` field included). Reading/writing back under whichever key
    # is actually present avoids silently updating a copy nothing reads (the
    # #1157 "key shapes are mixed on purpose" note applies here too).
    update_field(value, :columns, "columns", fn columns ->
      columns
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map_reduce(reset, &reset_column(&1, role, &2))
    end)
  end

  defp reset_nested(value, _module, _role, reset), do: {value, reset}

  defp reset_column(column, role, reset) do
    update_field(column, :blocks, "blocks", fn blocks ->
      blocks
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.flat_map_reduce(reset, &reset_nested_child(&1, role, &2))
    end)
  end

  # Reads `map[atom_key] || map[string_key]` (defaulting to `[]`), runs
  # `fun.(value)` — which must itself return `{new_value, reset}` — and writes
  # the result back under whichever key was actually read, so a value stored
  # under one key shape is never left beside a spurious empty one under the
  # other.
  defp update_field(map, atom_key, string_key, fun) do
    cond do
      Map.has_key?(map, atom_key) ->
        {value, reset} = fun.(Map.get(map, atom_key))
        {Map.put(map, atom_key, value), reset}

      Map.has_key?(map, string_key) ->
        {value, reset} = fun.(Map.get(map, string_key))
        {Map.put(map, string_key, value), reset}

      true ->
        {_value, reset} = fun.([])
        {map, reset}
    end
  end

  # A nested child carries its fields inline (`"_type"` + attrs, no `"value"`
  # wrapper) — the same envelope shape `reset_fields/4` already tolerates via
  # its declared-fields-only rule (#1157) — so it resets exactly like a
  # top-level block once its own module is resolved.
  defp reset_nested_child(child, role, reset) do
    case nested_child_module(child) do
      nil ->
        {[child], reset}

      module ->
        if unsafe_reset?(module, role) do
          {[], [drop_note(module) | reset]}
        else
          {child, reset} = reset_fields(child, module, role, reset)
          {child, reset} = reset_nested(child, module, role, reset)
          {[child], reset}
        end
    end
  end

  defp nested_child_module(child), do: KilnCMS.Blocks.module_for_tagged_map(child)

  defp reset_fields(value, module, role, reset) do
    declared = MapSet.new(Kiln.Block.Info.fields(module), & &1.name)

    Enum.reduce(value, {value, reset}, fn {key, _current}, {acc, reset} ->
      name = field_atom(key)

      cond do
        is_nil(name) ->
          {acc, reset}

        # `_type`, `_version` and `id` live in the same stored map as the
        # authored fields but are the union's own envelope, not fields anyone
        # declares or edits. Asking a *field* policy about them answered "no"
        # for every non-admin — so a plain editor duplicating a plain page had
        # them overwritten with `nil` and was told, in a flash, that their role
        # could not set `heading._type` (#1157).
        #
        # Declared-fields-only is the rule, not a denylist of the three names:
        # the envelope is the union's business and can gain a key without this
        # having to hear about it.
        not MapSet.member?(declared, name) ->
          {acc, reset}

        Kiln.Block.Policy.can_edit_field?(module, name, role) ->
          {acc, reset}

        true ->
          {Map.put(acc, key, field_default(module, name)),
           ["#{block_name(module)}.#{name}" | reset]}
      end
    end)
  end

  defp block_module(%{"type" => type}) do
    case Keyword.get(KilnCMS.Blocks.union_types(), to_atom(type)) do
      nil -> nil
      config -> Keyword.get(config, :type)
    end
  end

  defp block_module(_other), do: nil

  defp block_name(module), do: module |> Kiln.Block.Info.name() |> to_string()

  defp field_default(module, name) do
    case Enum.find(Kiln.Block.Info.fields(module), &(&1.name == name)) do
      %{default: default} -> default
      _ -> nil
    end
  end

  defp to_atom(value) when is_atom(value), do: value

  defp to_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp to_atom(_other), do: nil

  defp field_atom(key), do: to_atom(key)

  # Drop `id` from every block-shaped map in the tree, at any depth. The union
  # dumps nested (`%{"type" => …, "value" => %{id: …, _type: "columns", …}}`)
  # and a `columns` block holds its children as raw maps that carry ids of their
  # own — a top-level-only strip would leave the copy sharing nested block ids
  # with its source. `_type` is what marks a map as a block, so ordinary maps in
  # a block field (a media reference, a custom-field map) keep their `id`.
  #
  # Key shapes are mixed on purpose: `dump_to_embedded` emits atom keys for the
  # block's own attributes, while nested children keep the string keys they were
  # cast from.
  defp strip_ids(%{} = map) when not is_struct(map) do
    map
    |> drop_block_id()
    |> Map.new(fn {key, value} -> {key, strip_ids(value)} end)
  end

  defp strip_ids(list) when is_list(list), do: Enum.map(list, &strip_ids/1)
  defp strip_ids(other), do: other

  defp drop_block_id(map) do
    if Map.has_key?(map, :_type) or Map.has_key?(map, "_type"),
      do: Map.drop(map, ["id", :id]),
      else: map
  end

  @doc "The source's tag ids, for the create action's `tag_ids` argument."
  @spec tag_ids(struct()) :: [Ash.UUID.t()]
  def tag_ids(record) do
    case Map.get(record, :tags) do
      tags when is_list(tags) -> Enum.map(tags, & &1.id)
      _not_loaded -> []
    end
  end
end
