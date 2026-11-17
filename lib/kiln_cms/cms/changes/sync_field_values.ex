defmodule KilnCMS.CMS.Changes.SyncFieldValues do
  @moduledoc """
  Keeps the `custom_fields` keys stored on content in step with the
  `FieldDefinition` rows that govern them: **destroying** a definition purges
  its key, **renaming** one moves the values to the new key, and flipping a
  media, reference or select field's `multiple` flag **reshapes** its values
  between a single value and a list (a gallery, a list of references, several
  terms).

  Both cases otherwise leave records holding a key no definition declares, and
  such a key is on borrowed time. `Changes.ApplyCustomFields` folds the stored
  map out of the *definitions*, so the value dies on whatever write touches
  that record next — which is normally an edit to something else entirely. An
  editor retitles a page and three paragraphs of prose go with it, months after
  the admin action that actually doomed them, with nothing connecting the two.

  Renaming is the worse of the two, because nothing about it asks for data to
  be lost: the field disappears from the editor the moment it is renamed and
  the values are dropped, one record at a time, in the background. Moving them
  is what a rename obviously meant.

  A destroy genuinely does mean "these values go" — #710 settled that a deleted
  definition must stop publishing what was stored under it, and `custom_fields`
  is `public? true`, so keeping them is not on the table. What changes is *when*:
  the moment the admin asked, rather than whenever each record is next written.

  ## How

  One statement per definition over the type's own table, scoped to the
  definition's org (epic #336), touching only rows that actually carry the key.
  Deliberately not through Ash:

    * it is **schema maintenance**, not an authored edit — it must not mint a
      version per record, re-fire, bump `updated_at`, or notify;
    * a type can hold hundreds of thousands of rows, and this is one statement.

  Published artifacts are unaffected either way: firing already projects onto
  the current definitions (`KilnCMS.Firing.CustomFields.resolve/2`), so no live
  surface was serving a retired key by the time this runs.

  ## Link fields

  A link field (`link_of_id`, R3) has no key of its own: its values live in
  the `"link"` map of each connection its reference field holds, and on each
  of that field's edges as `metadata`. Destroying one removes its key from
  both copies, renaming one moves it, in the parent field's table — the same
  two statements, one level down. A connection whose `"link"` map empties
  loses the key, as a write that sets no link value stores none.

  ## Group sub-fields

  A group sub-field (`group_of_id`) has no key of its own either: its values
  are one key of the object a group holds, or of each object in its list.
  Destroying one removes that key from every row, renaming one moves it —
  the link-field statements again, over the rows themselves instead of their
  `"link"` maps. A row left with no keys is dropped, as a write drops a
  blank row; flipping a group's `multiple` reshapes it as it does a gallery.

  ## Flexible content

  An **item type** (`flex_of_id`, #2282) and a **sub-field of one** have no key
  of their own either: their values live inside the items of a flexible field,
  which may sit inside the items of another (down to
  `FieldDefinition.max_flexible_depth/0` levels). Renaming a sub-field renames
  its key inside every item of that type, destroying one purges it (an item it
  empties is dropped, as a write drops a blank item), renaming an item type
  rewrites each item's `_type`, destroying one removes its items.
  `KilnCMS.CMS.FlexiblePath` finds the path from the owning type's top-level
  flexible field and builds the statement, qualified by every step: item type
  names are unique only within one flexible field, so none is matched by name
  alone.

  Destroying an item type removes its items only because
  `Validations.ItemTypeInUse` let the destroy through (no items, or
  `purge_items?: true`); with `purge_items?: true` the items are removed in the
  destroy's own transaction (an `after_action`), so the type and its items go
  together or not at all. Destroying a whole flexible field, or a nested one, is
  the group's behavior: the key is purged here. The database cascades from the
  field to its item types and their sub-fields **without** passing through this
  module, which is safe because the values went with the key.

  It runs `after_transaction` on success only — a write that rolls back syncs
  nothing — and a failure is logged rather than raised: the definition write
  itself has committed, and `ApplyCustomFields` still drops a stray key (with a
  warning) as a backstop.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.FlexiblePath

  require Logger

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> Ash.Changeset.after_action(&rewrite_conditions(&1, &2, context))
    |> Ash.Changeset.after_action(&purge_items(&1, &2))
    |> Ash.Changeset.after_transaction(&sync(&1, &2))
  end

  # A rename moves the field every conditional rule (#2277) of its siblings
  # reads, so those rules follow it — in the rename's own transaction, so no
  # reader sees a rule naming a field that no longer exists.
  defp rewrite_conditions(%{action_type: :update} = changeset, definition, context) do
    from = changeset.data.name

    if from == definition.name do
      {:ok, definition}
    else
      # Inside the rename's own transaction, on purpose (see above).
      opts =
        context
        |> Ash.Context.to_opts()
        |> Keyword.put(:tenant, changeset.to_tenant)
        # A dependent of a type this release does not know (#2605) has its
        # rule rewritten too: `KnownFieldType` admits this one write to it.
        |> Keyword.put(:context, %{
          warn_on_transaction_hooks?: false,
          kiln_condition_rename: true
        })

      definition
      |> Map.put(:name, from)
      |> KilnCMS.CMS.Validations.FieldCondition.dependents(changeset.to_tenant)
      |> Enum.reduce_while({:ok, definition}, &rewrite_dependent(&1, &2, from, opts))
    end
  end

  defp rewrite_conditions(_changeset, definition, _context), do: {:ok, definition}

  # Destroying an item type with `purge_items?: true` removes its items in the
  # destroy's own transaction (#2282): the type and its items go together or
  # not at all, and no write that commits between the guard and the purge can
  # outlive the type with the purge still pending. A concurrent save that
  # lands after this statement but before the commit can still add an item of
  # the type (the window ADR 0065 accepts); `ApplyCustomFields` refuses it on
  # the next write that names the field. A failure here rolls the destroy
  # back, rather than being logged as the post-commit statements are.
  defp purge_items(
         %{action_type: :destroy} = changeset,
         %{flex_of_id: flex_id, name: name} = definition
       )
       when not is_nil(flex_id) do
    if purge_requested?(changeset) do
      previous = %{definition | name: name}

      case FlexiblePath.item_path_detailed(previous, definition.org_id) do
        {:ok, top, steps} -> purge_type_items(top, steps, definition)
        # The flexible field went first and took every value with it.
        {:error, :gone} -> {:ok, definition}
        {:error, reason} -> {:error, "could not purge the items of #{name}: #{reason}"}
      end
    else
      {:ok, definition}
    end
  end

  defp purge_items(_changeset, definition), do: {:ok, definition}

  defp purge_requested?(changeset),
    do: Ash.Changeset.get_argument(changeset, :purge_items?) == true

  # `sobelow_skip`: the statement comes from `FlexiblePath.update_sql/4`, whose
  # only interpolations are the table name and `$n` placeholders; every name
  # and value is a bound parameter.
  # sobelow_skip ["SQL.Query"]
  defp purge_type_items(top, steps, definition) do
    with false <- KilnCMS.CMS.FieldDefinition.orphaned?(top),
         {:ok, table, filter, params} <- target(top) do
      {sql, bound} = FlexiblePath.update_sql(table, steps, :purge_type, {filter, params})

      case KilnCMS.Repo.query(sql, bound) do
        {:ok, _result} -> {:ok, definition}
        {:error, error} -> {:error, error}
      end
    else
      # An orphaned owner governs no table; an unresolvable one is the same
      # case `run/3` logs after the commit.
      true -> {:ok, definition}
      :error -> {:ok, definition}
    end
  end

  defp rewrite_dependent(dependent, {:ok, definition} = acc, from, opts) do
    rewritten = %{
      visible_when: rename_rule(dependent.visible_when, from, definition.name),
      required_when: rename_rule(dependent.required_when, from, definition.name)
    }

    case KilnCMS.CMS.update_field_definition(dependent, rewritten, opts) do
      {:ok, _dependent} -> {:cont, acc}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp rename_rule(nil, _from, _to), do: nil
  defp rename_rule(rule, from, to), do: KilnCMS.CMS.Conditions.rename(rule, from, to)

  defp sync(changeset, {:ok, %{link_of_id: parent_id} = definition} = result)
       when not is_nil(parent_id) do
    case parent(parent_id, definition.org_id) do
      nil ->
        # The parent went first (its destroy cascades to this row) and took
        # every value with it.
        result

      parent ->
        changeset
        |> link_operations(parent, definition)
        |> Enum.reduce(result, &run(&1, parent, &2))
    end
  end

  defp sync(changeset, {:ok, %{group_of_id: parent_id} = definition} = result)
       when not is_nil(parent_id) do
    case parent(parent_id, definition.org_id) do
      nil ->
        result

      %{flex_of_id: flex_id} = item_type when not is_nil(flex_id) ->
        sync_item(changeset, item_type, definition, result)

      parent ->
        changeset
        |> group_operations(parent, definition)
        |> Enum.reduce(result, &run(&1, parent, &2))
    end
  end

  # An item type: its items are reached through the path to it, under the
  # name they still carry (the old one, on a rename).
  defp sync(changeset, {:ok, %{flex_of_id: flex_id} = definition} = result)
       when not is_nil(flex_id) do
    previous = %{definition | name: changeset.data.name}

    case FlexiblePath.item_path(previous, definition.org_id) do
      {:ok, top, steps} ->
        changeset
        |> item_type_operations(steps, definition)
        |> Enum.reduce(result, &run(&1, top, &2))

      :error ->
        # The flexible field went first (its destroy cascades to this row) and
        # took every value with it.
        result
    end
  end

  defp sync(changeset, {:ok, definition} = result) do
    changeset
    |> operations(definition)
    |> Enum.reduce(result, &run(&1, definition, &2))
  end

  defp sync(_changeset, other), do: other

  # A destroy purges; an update purges nothing. It moves the key if `name`
  # moved, and reshapes the values (under the key they now live at) if a media
  # or reference field's `multiple` flipped. Every other definition edit (label, help text,
  # position, even the field *type*) leaves the stored values where they are.
  defp operations(%{action_type: :destroy}, definition), do: [{:purge, definition.name}]

  defp operations(%{action_type: :update} = changeset, definition) do
    previous = changeset.data

    rename =
      if previous.name == definition.name,
        do: [],
        else: [{:rename, previous.name, definition.name}]

    # A list field is any `ClearMultiple.list_types/0` field with `multiple`; retyping
    # one to another type narrows it too (ClearMultiple drops the flag), so it
    # keeps its first item like any other narrowing rather than leaving lists
    # under a key that cannot hold one.
    #
    # A held list (`FieldDefinition.held_list?/1`, #2680) counts as a list on
    # both sides: it stays one through every update (`ClearMultiple`), and the
    # fields admin's narrowing save keeps each record's first item.
    was_list? = list_or_held?(previous)
    list? = list_or_held?(definition)

    reshape =
      cond do
        was_list? == list? ->
          []

        # Retyping a field *into* a scalar list (a `:text` holding JSON
        # strings made a multiple select, a `:string` made a list of dates) is
        # not a flip of the same values: wrapping each string in a list would
        # store `["[\"a\",\"b\"]"]`, or a phrase as a date. The values stay as
        # they are — the next write of each reports them — and
        # `mix kiln.fields.convert` is the tool that moves them.
        list? and definition.field_type in KilnCMS.CMS.ScalarLists.types() and
            previous.field_type != definition.field_type ->
          []

        list? ->
          [{:reshape, definition.name, :to_list}]

        true ->
          [{:reshape, definition.name, :to_single}]
      end

    rename ++ reshape
  end

  defp operations(_changeset, _definition), do: []

  defp link_operations(%{action_type: :destroy}, parent, definition),
    do: [{:purge_link, parent.name, definition.name}]

  defp link_operations(%{action_type: :update} = changeset, parent, definition) do
    if changeset.data.name == definition.name,
      do: [],
      else: [{:rename_link, parent.name, changeset.data.name, definition.name}]
  end

  defp link_operations(_changeset, _parent, _definition), do: []

  defp group_operations(%{action_type: :destroy}, parent, definition),
    do: [{:purge_sub_field, parent.name, definition.name}]

  defp group_operations(%{action_type: :update} = changeset, parent, definition) do
    if changeset.data.name == definition.name,
      do: [],
      else: [{:rename_sub_field, parent.name, changeset.data.name, definition.name}]
  end

  defp group_operations(_changeset, _parent, _definition), do: []

  # A sub-field of an item type: the path ends at that item type.
  defp sync_item(changeset, item_type, definition, result) do
    case FlexiblePath.item_path(item_type, definition.org_id) do
      {:ok, top, steps} ->
        changeset
        |> item_field_operations(steps, definition)
        |> Enum.reduce(result, &run(&1, top, &2))

      :error ->
        result
    end
  end

  defp item_field_operations(%{action_type: :destroy}, steps, definition),
    do: [{:item, steps, {:purge_field, definition.name, definition.item_setting}}]

  defp item_field_operations(%{action_type: :update} = changeset, steps, definition) do
    if changeset.data.name == definition.name,
      do: [],
      else: [
        {:item, steps,
         {:rename_field, changeset.data.name, definition.name, definition.item_setting}}
      ]
  end

  defp item_field_operations(_changeset, _steps, _definition), do: []

  # `steps` end in the item type under its old name.
  # Already removed in the destroy's own transaction when `purge_items?` asked
  # for it (`purge_items/2`).
  defp item_type_operations(%{action_type: :destroy} = changeset, steps, _definition),
    do:
      if(purge_requested?(changeset),
        do: [{:item_links, steps}],
        else: [{:item, steps, :purge_type}]
      )

  defp item_type_operations(%{action_type: :update} = changeset, steps, definition) do
    if changeset.data.name == definition.name,
      do: [],
      else: [{:item, steps, {:rename_type, definition.name}}]
  end

  defp item_type_operations(_changeset, _steps, _definition), do: []

  defp parent(id, org_id) do
    case KilnCMS.CMS.get_field_definition(id,
           actor: KilnCMS.CMS.Housekeeping.system(:cms_registry),
           tenant: org_id
         ) do
      {:ok, parent} -> parent
      _missing -> nil
    end
  end

  defp list_or_held?(definition), do: list?(definition) or FieldDefinition.held_list?(definition)

  defp list?(%{field_type: type, multiple: multiple}),
    do: multiple == true and type in KilnCMS.CMS.Changes.ClearMultiple.list_types()

  # An orphaned definition (#1770) governs no table: its content type is gone,
  # so there is no record of it left to purge, and nothing to warn about when
  # an admin clears it away.
  defp run(op, definition, result) do
    if KilnCMS.CMS.FieldDefinition.orphaned?(definition) do
      result
    else
      run_on_target(op, definition, result)
    end
  end

  defp run_on_target(op, definition, result) do
    case target(definition) do
      {:ok, table, filter, params} ->
        execute(op, table, filter, params)
        execute_links(op, table, filter, params)

      :error ->
        Logger.warning(
          "custom_fields: could not resolve the table for field " <>
            "#{inspect(definition.name)}; its stored values are now out of step with the registry"
        )
    end

    result
  end

  # `$1` is the key being retired, `$2` the key it becomes (rename only), so the
  # org/type params start after it.
  #
  # `sobelow_skip`: the only interpolations are the table name and the `$n`
  # placeholder tail. The table comes from the resource's own `postgres do
  # table` — a compile-time DSL setting, never a request value — and the
  # placeholders are digits this module generates. Every actual *value* (the
  # field names, the org, the type id) is a bound parameter, which is what
  # Sobelow cannot see from a `Repo.query/2` handed a variable.
  # sobelow_skip ["SQL.Query"]
  defp execute({:purge, name}, table, filter, params) do
    """
    UPDATE #{table}
       SET custom_fields = custom_fields - $1
     WHERE custom_fields ? $1#{filter.(1)}
    """
    |> query([name | params], "purged #{inspect(name)} from")
  end

  # sobelow_skip ["SQL.Query"]
  defp execute({:rename, from, to}, table, filter, params) do
    """
    UPDATE #{table}
       SET custom_fields = (custom_fields - $1) || jsonb_build_object($2::text, custom_fields -> $1)
     WHERE custom_fields ? $1#{filter.(2)}
    """
    |> query([from, to | params], "moved #{inspect(from)} to #{inspect(to)} on")
  end

  # Single → list wraps each stored snapshot (or select term, phrase, number,
  # date, …) in a one-item list — lossless.
  # List → single keeps each list's first snapshot and clears an empty one;
  # the rest of a list has nowhere to go, which the fields admin says before
  # the admin saves. Only values already in the other shape are touched.
  # sobelow_skip ["SQL.Query"]
  defp execute({:reshape, name, :to_list}, table, filter, params) do
    """
    UPDATE #{table}
       SET custom_fields = jsonb_set(custom_fields, ARRAY[$1::text],
                                     jsonb_build_array(custom_fields -> $1::text))
     WHERE jsonb_typeof(custom_fields -> $1::text) IN ('object', 'string', 'number')#{filter.(1)}
    """
    |> query([name | params], "made #{inspect(name)} a list on")
  end

  # sobelow_skip ["SQL.Query"]
  defp execute({:reshape, name, :to_single}, table, filter, params) do
    """
    UPDATE #{table}
       SET custom_fields =
             CASE WHEN jsonb_array_length(custom_fields -> $1::text) = 0
                  THEN custom_fields - $1::text
                  ELSE jsonb_set(custom_fields, ARRAY[$1::text], custom_fields -> $1::text -> 0)
             END
     WHERE jsonb_typeof(custom_fields -> $1::text) = 'array'#{filter.(1)}
    """
    |> query([name | params], "made #{inspect(name)} a single item on")
  end

  # A link field's key, removed from (or moved within) the `"link"` map of
  # every connection the parent field holds — one snapshot or a list of them.
  # `$1` is the parent field, `$2` the link key, `$3` its new name (rename).
  # Only rows where some connection carries the key are touched: the
  # jsonpath's lax mode looks into a list's items and a lone snapshot alike.
  # sobelow_skip ["SQL.Query"]
  defp execute({:purge_link, field, name}, table, filter, params) do
    item = """
    CASE WHEN jsonb_typeof(e -> 'link') = 'object' AND (e -> 'link') ? $2::text
         THEN CASE WHEN ((e -> 'link') - $2::text) = '{}'::jsonb THEN e - 'link'
                   ELSE jsonb_set(e, '{link}', (e -> 'link') - $2::text) END
         ELSE e END
    """

    field
    |> link_statement(item, table, filter.(2))
    |> query(
      [field, name | params],
      "purged link value #{inspect(name)} of #{inspect(field)} from"
    )
  end

  # sobelow_skip ["SQL.Query"]
  defp execute({:rename_link, field, from, to}, table, filter, params) do
    item = """
    CASE WHEN jsonb_typeof(e -> 'link') = 'object' AND (e -> 'link') ? $2::text
         THEN jsonb_set(e, '{link}',
                        ((e -> 'link') - $2::text) || jsonb_build_object($3::text, (e -> 'link') -> $2::text))
         ELSE e END
    """

    field
    |> link_statement(item, table, filter.(3))
    |> query(
      [field, from, to | params],
      "moved link value #{inspect(from)} of #{inspect(field)} to #{inspect(to)} on"
    )
  end

  # A group sub-field's key, removed from (or moved within) every row the
  # group holds — one object or a list of them. `$1` is the group, `$2` the
  # sub-field, `$3` its new name (rename). A purge that empties a row drops
  # it from a list, and drops the group's key when it held one object.
  # sobelow_skip ["SQL.Query"]
  defp execute({:purge_sub_field, field, name}, table, filter, params) do
    """
    UPDATE #{table}
       SET custom_fields =
             CASE jsonb_typeof(custom_fields -> $1::text)
               WHEN 'array' THEN
                 jsonb_set(custom_fields, ARRAY[$1::text],
                   (SELECT COALESCE(jsonb_agg(r ORDER BY ord), '[]'::jsonb)
                      FROM (SELECT CASE WHEN jsonb_typeof(e) = 'object' THEN e - $2::text ELSE e END AS r, ord
                              FROM jsonb_array_elements(custom_fields -> $1::text)
                                   WITH ORDINALITY AS x(e, ord)) AS kept
                     WHERE r <> '{}'::jsonb))
               WHEN 'object' THEN
                 CASE WHEN ((custom_fields -> $1::text) - $2::text) = '{}'::jsonb
                      THEN custom_fields - $1::text
                      ELSE jsonb_set(custom_fields, ARRAY[$1::text], (custom_fields -> $1::text) - $2::text)
                 END
               ELSE custom_fields
             END
     WHERE jsonb_path_exists(custom_fields -> $1::text,
                             'lax $[*].keyvalue() ? (@.key == $k)',
                             jsonb_build_object('k', $2::text))#{filter.(2)}
    """
    |> query(
      [field, name | params],
      "purged sub-field #{inspect(name)} of #{inspect(field)} from"
    )
  end

  # sobelow_skip ["SQL.Query"]
  defp execute({:rename_sub_field, field, from, to}, table, filter, params) do
    item = """
    CASE WHEN jsonb_typeof(e) = 'object' AND e ? $2::text
         THEN (e - $2::text) || jsonb_build_object($3::text, e -> $2::text)
         ELSE e END
    """

    """
    UPDATE #{table}
       SET custom_fields = jsonb_set(custom_fields, ARRAY[$1::text],
             CASE jsonb_typeof(custom_fields -> $1::text)
               WHEN 'array' THEN
                 (SELECT COALESCE(jsonb_agg((#{item}) ORDER BY ord), '[]'::jsonb)
                    FROM jsonb_array_elements(custom_fields -> $1::text) WITH ORDINALITY AS x(e, ord))
               ELSE (SELECT (#{item}) FROM (SELECT custom_fields -> $1::text AS e) AS one)
             END)
     WHERE jsonb_path_exists(custom_fields -> $1::text,
                             'lax $[*].keyvalue() ? (@.key == $k)',
                             jsonb_build_object('k', $2::text))#{filter.(3)}
    """
    |> query(
      [field, from, to | params],
      "moved sub-field #{inspect(from)} of #{inspect(field)} to #{inspect(to)} on"
    )
  end

  # An item tree's values (`KilnCMS.CMS.FlexiblePath`): one statement, qualified
  # by every step of the path.
  # sobelow_skip ["SQL.Query"]
  defp execute({:item, steps, op}, table, filter, params) do
    {sql, bound} = FlexiblePath.update_sql(table, steps, op, {filter, params})
    query(sql, bound, "rewrote the #{inspect(op_name(op))} items of #{inspect(steps)} in")
  end

  # Only the edges (`execute_links/4`) of an item type destroyed with its items.
  defp execute({:item_links, _steps}, _table, _filter, _params), do: :ok

  defp op_name(op) when is_atom(op), do: op
  defp op_name(op), do: elem(op, 0)

  # `item` rewrites one connection `e`; a list is rebuilt item by item, in
  # its order.
  defp link_statement(_field, item, table, filter_sql) do
    """
    UPDATE #{table}
       SET custom_fields = jsonb_set(custom_fields, ARRAY[$1::text],
             CASE jsonb_typeof(custom_fields -> $1::text)
               WHEN 'array' THEN
                 (SELECT COALESCE(jsonb_agg((#{item}) ORDER BY ord), '[]'::jsonb)
                    FROM jsonb_array_elements(custom_fields -> $1::text) WITH ORDINALITY AS x(e, ord))
               ELSE (SELECT (#{item}) FROM (SELECT custom_fields -> $1::text AS e) AS one)
             END)
     WHERE jsonb_path_exists(custom_fields -> $1::text,
                             'lax $.link.keyvalue() ? (@.key == $k)',
                             jsonb_build_object('k', $2::text))#{filter_sql}
    """
  end

  # The field's reference edges (#1594) follow its values: a purge deletes
  # them, a rename moves them to the new key. Scoped by the same table, org
  # and type as the value statement, through the edge's source. Edges of any
  # other field type match nothing (`kind = 'reference'`).
  #
  # An edge of a reference inside a group row or an item (#2282) is keyed by
  # its dotted definition path (`KilnCMS.CMS.ContentLinks.desired/2`:
  # `sections.hero.cta`), so a field's edges are the ones at its own name and
  # everything under `name.`: a purge or a rename of a group, a flexible field,
  # a sub-field or an item type acts on that whole prefix. Field names hold
  # no dot, so a prefix never matches a sibling (`sections` vs `sections2`);
  # `LIKE`'s own wildcards (`_` is common in names) are escaped.
  # sobelow_skip ["SQL.Query"]
  defp execute_links({:purge, name}, table, filter, params) do
    """
    DELETE FROM content_links
     WHERE kind = 'reference' AND (field = $1::text OR field LIKE $2::text)
       AND source_id IN (SELECT id FROM #{table} WHERE TRUE#{filter.(2)})
    """
    |> query(
      [name, under(name) | params],
      "deleted the #{inspect(name)} reference links of"
    )
  end

  # sobelow_skip ["SQL.Query"]
  defp execute_links({:rename, from, to}, table, filter, params) do
    """
    UPDATE content_links
       SET field = $2::text || substr(field, char_length($1::text) + 1)
     WHERE kind = 'reference' AND (field = $1::text OR field LIKE $3::text)
       AND source_id IN (SELECT id FROM #{table} WHERE TRUE#{filter.(3)})
    """
    |> query(
      [from, to, under(from) | params],
      "moved the #{inspect(from)} reference links to #{inspect(to)} on"
    )
  end

  # A list → single narrowing keeps each record's first reference, so its
  # edge (position 0) stays and every later one goes with the value it
  # mirrored. Single → list keeps the one edge at position 0 as it is. A media
  # field has no reference edges, so this matches nothing for a gallery.
  # sobelow_skip ["SQL.Query"]
  defp execute_links({:reshape, name, :to_single}, table, filter, params) do
    """
    DELETE FROM content_links
     WHERE kind = 'reference' AND field = $1 AND position > 0
       AND source_id IN (SELECT id FROM #{table} WHERE TRUE#{filter.(1)})
    """
    |> query([name | params], "deleted the narrowed #{inspect(name)} reference links of")
  end

  defp execute_links({:reshape, _name, :to_list}, _table, _filter, _params), do: :ok

  # An item tree's edges follow their values: the path of the sub-field or
  # item type the operation names, as `ContentLinks.desired/2` keys them.
  defp execute_links({:item, steps, op}, table, filter, params) do
    prefix = edge_path(steps)

    case op do
      {:rename_field, from, to, _setting?} ->
        execute_links(
          {:rename, prefix <> "." <> from, prefix <> "." <> to},
          table,
          filter,
          params
        )

      {:purge_field, name, _setting?} ->
        execute_links({:purge, prefix <> "." <> name}, table, filter, params)

      # `steps` end in the item type under its old name.
      {:rename_type, to} ->
        renamed = edge_path(Enum.drop(steps, -1) ++ [{elem(List.last(steps), 0), to}])
        execute_links({:rename, prefix, renamed}, table, filter, params)

      :purge_type ->
        execute_links({:purge, prefix}, table, filter, params)
    end
  end

  # An item type destroyed with `purge_items?` already lost its items in the
  # destroy's own transaction; its edges go here, with the rest of the sync.
  defp execute_links({:item_links, steps}, table, filter, params),
    do: execute_links({:purge, edge_path(steps)}, table, filter, params)

  # A group's sub-field edges are `group.sub`.
  defp execute_links({:purge_sub_field, field, name}, table, filter, params),
    do: execute_links({:purge, field <> "." <> name}, table, filter, params)

  defp execute_links({:rename_sub_field, field, from, to}, table, filter, params),
    do: execute_links({:rename, field <> "." <> from, field <> "." <> to}, table, filter, params)

  # A link field's copy on the parent field's edges (R3): the edge's
  # `metadata` is the connection's `"link"` map.
  # sobelow_skip ["SQL.Query"]
  defp execute_links({:purge_link, field, name}, table, filter, params) do
    """
    UPDATE content_links
       SET metadata = metadata - $2::text
     WHERE kind = 'reference' AND field = $1 AND metadata ? $2::text
       AND source_id IN (SELECT id FROM #{table} WHERE TRUE#{filter.(2)})
    """
    |> query([field, name | params], "purged link value #{inspect(name)} from the links of")
  end

  # sobelow_skip ["SQL.Query"]
  defp execute_links({:rename_link, field, from, to}, table, filter, params) do
    """
    UPDATE content_links
       SET metadata = (metadata - $2::text) || jsonb_build_object($3::text, metadata -> $2::text)
     WHERE kind = 'reference' AND field = $1 AND metadata ? $2::text
       AND source_id IN (SELECT id FROM #{table} WHERE TRUE#{filter.(3)})
    """
    |> query(
      [field, from, to | params],
      "moved link value #{inspect(from)} to #{inspect(to)} on the links of"
    )
  end

  # `{flexible field, item type}` steps as the dotted prefix of their edges.
  defp edge_path(steps),
    do: Enum.map_join(steps, ".", fn {field, type} -> field <> "." <> type end)

  # `LIKE` pattern for "everything under `path.`", wildcards in names escaped.
  defp under(path) do
    escaped = String.replace(path, ["\\", "%", "_"], &("\\" <> &1))
    escaped <> ".%"
  end

  # sobelow_skip ["SQL.Query"]
  defp query(sql, params, what) do
    case KilnCMS.Repo.query(sql, params) do
      {:ok, %{num_rows: 0}} ->
        :ok

      {:ok, %{num_rows: rows}} ->
        Logger.info("custom_fields: #{what} #{rows} record(s)")

      {:error, error} ->
        Logger.warning("custom_fields: could not sync (#{what}): #{Exception.message(error)}")
    end
  end

  @doc """
  The table holding the records `definition` governs, a function building the
  `WHERE` tail (` AND …`) whose placeholders start after the `n` parameters a
  statement bound first, and that tail's parameters — or `:error` when the
  owner no longer resolves. A dynamic type's fields all live on the shared
  `entries` table (D17), so that one narrows by type as well as by org.
  Shared with `KilnCMS.CMS.SelectTerms`, which reads the same rows.
  """
  @spec target(KilnCMS.CMS.FieldDefinition.t()) ::
          {:ok, String.t(), (non_neg_integer() -> String.t()), list()} | :error
  def target(%{type_definition_id: id} = definition) when not is_nil(id) do
    {:ok, table(KilnCMS.CMS.Entry),
     fn n -> " AND org_id = $#{n + 1} AND type_definition_id = $#{n + 2}" end,
     [uuid(definition.org_id), uuid(id)]}
  end

  def target(%{content_type: type} = definition) when not is_nil(type) do
    case KilnCMS.CMS.ContentTypes.get(type, definition.org_id) do
      %{resource: resource} ->
        {:ok, table(resource), fn n -> " AND org_id = $#{n + 1}" end, [uuid(definition.org_id)]}

      _other ->
        :error
    end
  end

  def target(_definition), do: :error

  defp table(resource), do: AshPostgres.DataLayer.Info.table(resource)

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, dumped} -> dumped
      :error -> value
    end
  end

  defp uuid(value), do: value
end
