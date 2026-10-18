defmodule KilnCMS.CMS.Changes.SyncFieldValues do
  @moduledoc """
  Keeps the `custom_fields` keys stored on content in step with the
  `FieldDefinition` rows that govern them: **destroying** a definition purges
  its key, **renaming** one moves the values to the new key, and flipping a
  media or reference field's `multiple` flag **reshapes** its values between a
  single snapshot and a list (a gallery, a list of references).

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

  It runs `after_transaction` on success only — a write that rolls back syncs
  nothing — and a failure is logged rather than raised: the definition write
  itself has committed, and `ApplyCustomFields` still drops a stray key (with a
  warning) as a backstop.
  """
  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, &sync(&1, &2))
  end

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

    # A list field is a media or reference field with `multiple`; retyping
    # one to another type narrows it too (ClearMultiple drops the flag), so it
    # keeps its first item like any other narrowing rather than leaving lists
    # under a key that cannot hold one.
    was_list? = list?(previous)
    list? = list?(definition)

    reshape =
      cond do
        was_list? == list? -> []
        list? -> [{:reshape, definition.name, :to_list}]
        true -> [{:reshape, definition.name, :to_single}]
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

  defp parent(id, org_id) do
    case KilnCMS.CMS.get_field_definition(id,
           actor: KilnCMS.CMS.Housekeeping.system(:cms_registry),
           tenant: org_id
         ) do
      {:ok, parent} -> parent
      _missing -> nil
    end
  end

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

  # Single → list wraps each stored snapshot in a one-item list — lossless.
  # List → single keeps each list's first snapshot and clears an empty one;
  # the rest of a list has nowhere to go, which the fields admin says before
  # the admin saves. Only values already in the other shape are touched.
  # sobelow_skip ["SQL.Query"]
  defp execute({:reshape, name, :to_list}, table, filter, params) do
    """
    UPDATE #{table}
       SET custom_fields = jsonb_set(custom_fields, ARRAY[$1::text],
                                     jsonb_build_array(custom_fields -> $1::text))
     WHERE jsonb_typeof(custom_fields -> $1::text) = 'object'#{filter.(1)}
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
  # sobelow_skip ["SQL.Query"]
  defp execute_links({:purge, name}, table, filter, params) do
    """
    DELETE FROM content_links
     WHERE kind = 'reference' AND field = $1
       AND source_id IN (SELECT id FROM #{table} WHERE TRUE#{filter.(1)})
    """
    |> query([name | params], "deleted the #{inspect(name)} reference links of")
  end

  # sobelow_skip ["SQL.Query"]
  defp execute_links({:rename, from, to}, table, filter, params) do
    """
    UPDATE content_links
       SET field = $2
     WHERE kind = 'reference' AND field = $1
       AND source_id IN (SELECT id FROM #{table} WHERE TRUE#{filter.(2)})
    """
    |> query(
      [from, to | params],
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

  # The table holding the records this definition governs, and a `WHERE` tail
  # built after however many keys the statement bound first. A dynamic type's
  # fields all live on the shared `entries` table (D17), so that one narrows by
  # type as well as by org.
  defp target(%{type_definition_id: id} = definition) when not is_nil(id) do
    {:ok, table(KilnCMS.CMS.Entry),
     fn n -> " AND org_id = $#{n + 1} AND type_definition_id = $#{n + 2}" end,
     [uuid(definition.org_id), uuid(id)]}
  end

  defp target(%{content_type: type} = definition) when not is_nil(type) do
    case KilnCMS.CMS.ContentTypes.get(type, definition.org_id) do
      %{resource: resource} ->
        {:ok, table(resource), fn n -> " AND org_id = $#{n + 1}" end, [uuid(definition.org_id)]}

      _other ->
        :error
    end
  end

  defp target(_definition), do: :error

  defp table(resource), do: AshPostgres.DataLayer.Info.table(resource)

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, dumped} -> dumped
      :error -> value
    end
  end

  defp uuid(value), do: value
end
