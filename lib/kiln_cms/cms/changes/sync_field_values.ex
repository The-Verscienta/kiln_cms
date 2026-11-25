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

  ## Working copies

  A live record's pending working copy (`KilnCMS.CMS.WorkingCopy`) holds its
  own `custom_fields` map in `working_fields`, and publishing it replaces the
  live map. So every rewrite above reaches the held map too (#2744): a rename
  left only on the live side would publish the old key, which no definition
  declares any more, and lose the draft's value.

    * **Same row, same statement.** Each operation is one SQL expression
      (`rewrite/2`) applied to both maps of a row in a single `UPDATE`, which
      reads the row as it was for both, so the copies cannot tear. A key only
      the draft holds is rewritten too.
    * **Re-base.** The copy's lost-update base (`working_base`) is the
      fingerprint of the live map it was saved against. It moves with the
      rewrite (`WorkingCopy.rebase/5`): a base that matched the held map now
      matches the rewritten held map, one that matched the live map the
      rewritten live map, and any other base — a real conflict — stays as it
      is, so a rename never makes "Publish changes", a release or an
      unpublish see a conflict nobody made, nor hides one somebody did. A copy
      the rewrite leaves equal to the live map stops holding `custom_fields`;
      `working_copy_at` stays, so the record still reads as pending until it
      is published or discarded.
    * **`lock_version`.** Every rewritten row's lock version moves, unlike
      the other background writers (oEmbed resolves, media re-snapshots,
      `mix kiln.fields.convert`, the event sweep): this write changes the set
      of keys a form read earlier would write back, so a stale editor's save
      or publish is refused as changed elsewhere rather than restoring the
      old key. An API client holding an ETag gets one 412, and a release
      go-live that read its records before the rename fails as stale and is
      retried. `updated_at`, versions, firing and notifications are left
      alone, as before.
    * **Locks.** The statement locks the rows it rewrites, in id order. A
      transaction advisory lock per table, org and governing field (the field
      itself, or the top-level field a sub-field, link field or item lives
      under) makes two syncs of the same field take turns; syncs of different
      fields touch disjoint keys and edges and run side by side.

  Versions are not rewritten (they are hash-chained, #671): a version saved
  before a rename still names the old key, and restoring it does not bring
  that value back.

  ## When, and what a failure does

  The value sync runs `after_transaction` on success only — a write that rolls
  back syncs nothing. On its own, the definition has committed by then: the
  rewrite of both copies, its edges and the re-base run in one transaction,
  and if that fails it is logged and the live values (and edges) are moved
  alone, as they were before working copies were rewritten, leaving the
  copies in their old shape. `ApplyCustomFields` still drops a stray key (with
  a warning) as a backstop.

  The rewrite is one statement over every row of the type, so a single
  malformed held value (one no write produces, such as a held map that is not
  an object) fails it for all of them, and that operation falls back to the
  live values alone for the whole type. A known limit: it is logged, and the
  copies it leaves behind still report their conflict when published.

  Inside a transaction the caller opened (`KilnCMS.CMS.JoinGraduation.retire/2`,
  a `KilnCMS.CMS.FieldSync` import, an item type's own destroy with
  `purge_items?`), the rewrite joins that transaction and a failure is
  returned as the action's error, so the caller rolls back whole.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.FlexiblePath
  alias KilnCMS.CMS.WorkingCopy

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

  # Already inside the destroy's transaction (an `after_action`), so a
  # failure is returned and rolls the destroy back. The held items go with the
  # live ones (`rewrite_held/4`); the edges go after the commit, with the rest
  # of the sync (`{:item_links, steps}`).
  defp purge_type_items(top, steps, definition) do
    with false <- KilnCMS.CMS.FieldDefinition.orphaned?(top),
         {:ok, table, filter, params} <- target(top) do
      case rewrite_held({:item, steps, :purge_type}, top, {table, filter, params}, false) do
        :ok -> {:ok, definition}
        {:error, :unresolved} -> {:ok, definition}
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
  # an admin clears it away. An operation after one that failed inside an
  # outer transaction would only fail again (Postgres refuses every statement
  # of an aborted transaction), so the failure is passed on as it is.
  defp run(_op, _definition, {:error, _reason} = failed), do: failed

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
        case rewrite_values(op, definition, {table, filter, params}) do
          :ok -> result
          {:error, reason} -> {:error, reason}
        end

      :error ->
        Logger.warning(
          "custom_fields: could not resolve the table for field " <>
            "#{inspect(definition.name)}; its stored values are now out of step with the registry"
        )

        result
    end
  end

  # See "Working copies" in the moduledoc for what is atomic with what.
  #
  # Inside a transaction someone else opened (`JoinGraduation.retire/2`, a
  # `FieldSync` import; `purge_items/2` calls `rewrite_held/4` itself) the
  # rewrite joins it, and a failure is returned for the caller's own error
  # path: a nested `Repo.rollback/1` would doom the outer transaction without
  # saying why, and a failed statement has aborted it anyway.
  #
  # Otherwise the definition has already committed. The rewrite runs in its
  # own transaction; if it fails, the live values still move as they did
  # before working copies were rewritten, so a malformed copy cannot strand
  # every record of the type under a key no definition declares.
  defp rewrite_values(op, definition, target) do
    if KilnCMS.Repo.in_transaction?(),
      do: rewrite_nested(op, definition, target),
      else: rewrite_alone(op, definition, target)
  end

  defp rewrite_nested(op, definition, target) do
    case rewrite_held(op, definition, target, true) do
      :ok -> :ok
      {:error, error} -> {:error, "could not sync (#{describe(op)} records): #{message(error)}"}
    end
  end

  defp rewrite_alone(op, definition, target) do
    case transaction_alone(op, definition, target) do
      {:ok, :ok} ->
        :ok

      {:error, error} ->
        Logger.error(
          "custom_fields: could not rewrite pending working copies (#{describe(op)} records): " <>
            "#{message(error)}; moving the live values only, so those copies still hold the old shape"
        )

        live_only(op, target)
    end
  end

  # The definition has committed and this runs after it, so a raise here
  # (a held value the re-base cannot read, a dropped connection) would only
  # crash the caller's already-successful write and strand the live values.
  # It is rescued at this one boundary and takes the logged live-only path.
  # The nested path does not rescue: there the caller's transaction owns the
  # failure.
  defp transaction_alone(op, definition, target) do
    KilnCMS.Repo.transaction(fn ->
      with {:error, error} <- rewrite_held(op, definition, target, true),
           do: KilnCMS.Repo.rollback(error)
    end)
  rescue
    error -> {:error, error}
  end

  defp message(:unresolved), do: "the content type no longer resolves"
  defp message(error) when is_exception(error), do: Exception.message(error)
  defp message(error), do: inspect(error)

  # What this module did before #2744: the live column and the edges, each
  # statement on its own, a failure logged.
  # `sobelow_skip`: the statements are `execute/4`'s and `link_statements/4`'s.
  # sobelow_skip ["SQL.Query"]
  defp live_only(op, {table, filter, params}) do
    execute(op, table, filter, params)

    op
    |> link_statements(table, filter, params)
    |> Enum.each(fn {sql, bound, what} -> query(sql, bound, what) end)
  end

  @held "(working_fields -> 'custom_fields')"

  @doc false
  # The advisory lock's key, for the test that checks which syncs share one.
  @spec lock_key(String.t(), FieldDefinition.t()) :: String.t()
  def lock_key(table, definition),
    do: "kiln:field_sync:#{table}:#{definition.org_id}:#{definition.id}"

  # The live map and the held one in one statement, then the edges, then the
  # re-base of every copy the statement rewrote. Must run in a transaction.
  defp rewrite_held(op, definition, {table, filter, params}, links?) do
    statements = if links?, do: link_statements(op, table, filter, params), else: []

    with {:ok, resource} <- resolve_resource(definition),
         :ok <- lock(table, definition),
         {:ok, rows} <- rewrite_both(op, table, filter, params),
         :ok <- run_all(statements) do
      rebase(rows, resource, table)
    end
  end

  defp resolve_resource(definition) do
    case target_resource(definition) do
      {:ok, resource} -> {:ok, resource}
      :error -> {:error, :unresolved}
    end
  end

  # Two syncs of the same field take turns. `definition` is the governing
  # one (the field itself, or the top-level field its values live under, for
  # a sub-field, a link field or an item), keyed by id so a rename racing a
  # rename of the same field still meets it. Syncs of other fields rewrite
  # other keys and edges, lock rows in id order, and are not held up: a lock
  # per table would serialize every field sync of a type, and a transaction
  # lock lasts until the caller's outer transaction ends.
  defp lock(table, definition) do
    case KilnCMS.Repo.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
           lock_key(table, definition)
         ]) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  # `rewrite/2` over both maps of each row that carries what `op` changes in
  # either: the live column, and the held copy when there is one. Every SET
  # reads the row as it was, so the two copies are rewritten from the same
  # pre-image, and `c` locks exactly the rows rewritten (`FOR UPDATE`; under
  # READ COMMITTED a row a concurrent save changed is re-read and re-tested).
  # `lock_version` moves on each: a form read before this statement must not
  # write its pre-rewrite map back (see the moduledoc).
  #
  # Returns the pre- and post-images of the rows that hold a copy; the rest
  # come back as bare ids, counted for the log.
  defp rewrite_both({:item_links, _steps}, _table, _filter, _params), do: {:ok, []}

  # sobelow_skip ["SQL.Query"]
  defp rewrite_both(op, table, filter, params) do
    {new_live, carries_live, bound} = rewrite(op, "custom_fields")
    {new_held, carries_held, ^bound} = rewrite(op, @held)
    holds = "working_fields ? 'custom_fields' AND #{carries_held}"

    sql = """
    WITH c AS (
      SELECT id AS c_id, custom_fields AS l0, #{@held} AS h0, working_base AS b0
        FROM #{table}
       WHERE (#{carries_live} OR (#{holds}))#{filter.(length(bound))}
       ORDER BY id
         FOR UPDATE
    ), u AS (
      UPDATE #{table} AS t
         SET custom_fields = CASE WHEN #{carries_live} THEN #{new_live} ELSE custom_fields END,
             working_fields =
               CASE WHEN #{holds}
                    THEN jsonb_set(working_fields, '{custom_fields}', #{new_held})
                    ELSE working_fields END,
             lock_version = lock_version + 1
        FROM c
       WHERE t.id = c.c_id
      RETURNING t.id, c.l0, c.h0, c.b0, t.custom_fields AS l1, t.working_fields -> 'custom_fields' AS h1
    )
    SELECT id, h0 IS NOT NULL,
           CASE WHEN h0 IS NOT NULL THEN l0 END, h0, CASE WHEN h0 IS NOT NULL THEN b0 END,
           CASE WHEN h0 IS NOT NULL THEN l1 END, h1
      FROM u
    """

    case KilnCMS.Repo.query(sql, bound ++ params) do
      {:ok, %{num_rows: 0}} ->
        {:ok, []}

      {:ok, %{num_rows: count, rows: rows}} ->
        Logger.info("custom_fields: #{describe(op)} #{count} record(s)")
        {:ok, for([id, true | images] <- rows, do: [id | images])}

      {:error, error} ->
        {:error, error}
    end
  end

  # sobelow_skip ["SQL.Query"]
  defp run_all(statements) do
    Enum.reduce_while(statements, :ok, fn {sql, bound, what}, :ok ->
      case KilnCMS.Repo.query(sql, bound) do
        {:ok, result} ->
          log_rows(result, what)
          {:cont, :ok}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp log_rows(%{num_rows: 0}, _what), do: :ok

  defp log_rows(%{num_rows: rows}, what),
    do: Logger.info("custom_fields: #{what} #{rows} record(s)")

  # Each rewritten copy's lost-update base follows the rewrite
  # (`WorkingCopy.rebase/5`), and a copy left equal to the live map stops
  # holding `custom_fields` at all — a copy holds only what differs. One
  # statement for all of them.
  # sobelow_skip ["SQL.Query"]
  defp rebase(rows, resource, table) do
    changes =
      for [id, l0, h0, b0, l1, h1] <- rows,
          change = rebased(resource, id, {l0, h0, b0}, {l1, h1}),
          change != nil,
          do: change

    if changes == [] do
      :ok
    else
      {ids, bases, drops} = unzip3(changes)

      """
      UPDATE #{table} AS t
         SET working_fields =
               CASE WHEN u.drop_held THEN t.working_fields - 'custom_fields'
                    ELSE t.working_fields END,
             working_base = u.new_base
        FROM unnest($1::uuid[], $2::jsonb[], $3::boolean[]) AS u(id, new_base, drop_held)
       WHERE t.id = u.id
      """
      |> KilnCMS.Repo.query([ids, bases, drops])
      |> case do
        {:ok, _result} -> :ok
        {:error, error} -> {:error, error}
      end
    end
  end

  defp rebased(resource, id, {l0, h0, base}, {l1, h1}) do
    rebased = WorkingCopy.rebase(resource, base, "custom_fields", {l0, h0}, {l1, h1})
    drop? = fingerprint(resource, l1) == fingerprint(resource, h1)
    rebased = if drop?, do: Map.delete(rebased, "custom_fields"), else: rebased

    if drop? or rebased != base, do: {id, rebased, drop?}
  end

  defp fingerprint(resource, stored) do
    WorkingCopy.fingerprint(
      resource,
      "custom_fields",
      WorkingCopy.cast(resource, :custom_fields, stored)
    )
  end

  defp unzip3(triples) do
    triples
    |> Enum.reduce({[], [], []}, fn {a, b, c}, {as, bs, cs} -> {[a | as], [b | bs], [c | cs]} end)
    |> then(fn {as, bs, cs} -> {Enum.reverse(as), Enum.reverse(bs), Enum.reverse(cs)} end)
  end

  # One statement over the rows that carry what `op` rewrites: the rewrite
  # itself is `rewrite/2` over the `custom_fields` column.
  #
  # `sobelow_skip`: the only interpolations are the table name, the fragments
  # `rewrite/2` builds and the `$n` placeholder tail. The table comes from the
  # resource's own `postgres do table` — a compile-time DSL setting, never a
  # request value — and the fragments and placeholders are SQL this module
  # generates. Every actual *value* (the field names, the org, the type id) is
  # a bound parameter, which is what Sobelow cannot see from a `Repo.query/2`
  # handed a variable.
  defp execute({:item_links, _steps}, _table, _filter, _params), do: :ok

  # sobelow_skip ["SQL.Query"]
  defp execute(op, table, filter, params) do
    {new, carries, bound} = rewrite(op, "custom_fields")

    """
    UPDATE #{table}
       SET custom_fields = #{new}
     WHERE #{carries}#{filter.(length(bound))}
    """
    |> query(bound ++ params, describe(op))
  end

  defp describe({:purge, name}), do: "purged #{inspect(name)} from"
  defp describe({:rename, from, to}), do: "moved #{inspect(from)} to #{inspect(to)} on"
  defp describe({:reshape, name, :to_list}), do: "made #{inspect(name)} a list on"
  defp describe({:reshape, name, :to_single}), do: "made #{inspect(name)} a single item on"

  defp describe({:purge_link, field, name}),
    do: "purged link value #{inspect(name)} of #{inspect(field)} from"

  defp describe({:rename_link, field, from, to}),
    do: "moved link value #{inspect(from)} of #{inspect(field)} to #{inspect(to)} on"

  defp describe({:purge_sub_field, field, name}),
    do: "purged sub-field #{inspect(name)} of #{inspect(field)} from"

  defp describe({:rename_sub_field, field, from, to}),
    do: "moved sub-field #{inspect(from)} of #{inspect(field)} to #{inspect(to)} on"

  defp describe({:item_links, steps}), do: "removed the item links of #{inspect(steps)} in"

  defp describe({:item, steps, op}),
    do: "rewrote the #{inspect(op_name(op))} items of #{inspect(steps)} in"

  # A value rewrite as SQL over the map expression `m` — the `custom_fields`
  # column, or a working copy's held map (`(working_fields -> 'custom_fields')`):
  # `{new, carries, params}`. `new` is the rewritten map, `carries` the
  # predicate saying `m` holds something `op` changes (`new` is only
  # evaluated where it does), and `params` are bound to `$1…$n`, so any
  # further parameters (the org/type filter) follow them. `m` may appear many
  # times and is only read.
  #
  # `$1` is the key being retired, `$2` the key it becomes (rename only).
  defp rewrite({:purge, name}, m), do: {"(#{m} - $1::text)", "#{m} ? $1::text", [name]}

  defp rewrite({:rename, from, to}, m) do
    {"((#{m} - $1::text) || jsonb_build_object($2::text, #{m} -> $1::text))", "#{m} ? $1::text",
     [from, to]}
  end

  # Single → list wraps each stored snapshot (or select term, phrase, number,
  # date, …) in a one-item list — lossless.
  # List → single keeps each list's first snapshot and clears an empty one;
  # the rest of a list has nowhere to go, which the fields admin says before
  # the admin saves. Only values already in the other shape are touched.
  defp rewrite({:reshape, name, :to_list}, m) do
    {"jsonb_set(#{m}, ARRAY[$1::text], jsonb_build_array(#{m} -> $1::text))",
     "jsonb_typeof(#{m} -> $1::text) IN ('object', 'string', 'number')", [name]}
  end

  defp rewrite({:reshape, name, :to_single}, m) do
    new = """
    CASE WHEN jsonb_array_length(#{m} -> $1::text) = 0
         THEN #{m} - $1::text
         ELSE jsonb_set(#{m}, ARRAY[$1::text], #{m} -> $1::text -> 0)
    END
    """

    {new, "jsonb_typeof(#{m} -> $1::text) = 'array'", [name]}
  end

  # A link field's key, removed from (or moved within) the `"link"` map of
  # every connection the parent field holds — one snapshot or a list of them.
  # `$1` is the parent field, `$2` the link key, `$3` its new name (rename).
  # Only maps where some connection carries the key are touched: the
  # jsonpath's lax mode looks into a list's items and a lone snapshot alike.
  defp rewrite({:purge_link, field, name}, m) do
    item = """
    CASE WHEN jsonb_typeof(e -> 'link') = 'object' AND (e -> 'link') ? $2::text
         THEN CASE WHEN ((e -> 'link') - $2::text) = '{}'::jsonb THEN e - 'link'
                   ELSE jsonb_set(e, '{link}', (e -> 'link') - $2::text) END
         ELSE e END
    """

    {each_connection(item, m), link_carries(m), [field, name]}
  end

  defp rewrite({:rename_link, field, from, to}, m) do
    item = """
    CASE WHEN jsonb_typeof(e -> 'link') = 'object' AND (e -> 'link') ? $2::text
         THEN jsonb_set(e, '{link}',
                        ((e -> 'link') - $2::text) || jsonb_build_object($3::text, (e -> 'link') -> $2::text))
         ELSE e END
    """

    {each_connection(item, m), link_carries(m), [field, from, to]}
  end

  # A group sub-field's key, removed from (or moved within) every row the
  # group holds — one object or a list of them. `$1` is the group, `$2` the
  # sub-field, `$3` its new name (rename). A purge that empties a row drops
  # it from a list, and drops the group's key when it held one object.
  defp rewrite({:purge_sub_field, field, name}, m) do
    new = """
    CASE jsonb_typeof(#{m} -> $1::text)
      WHEN 'array' THEN
        jsonb_set(#{m}, ARRAY[$1::text],
          (SELECT COALESCE(jsonb_agg(r ORDER BY ord), '[]'::jsonb)
             FROM (SELECT CASE WHEN jsonb_typeof(e) = 'object' THEN e - $2::text ELSE e END AS r, ord
                     FROM jsonb_array_elements(#{m} -> $1::text)
                          WITH ORDINALITY AS x(e, ord)) AS kept
            WHERE r <> '{}'::jsonb))
      WHEN 'object' THEN
        CASE WHEN ((#{m} -> $1::text) - $2::text) = '{}'::jsonb
             THEN #{m} - $1::text
             ELSE jsonb_set(#{m}, ARRAY[$1::text], (#{m} -> $1::text) - $2::text)
        END
      ELSE #{m}
    END
    """

    {new, sub_field_carries(m), [field, name]}
  end

  defp rewrite({:rename_sub_field, field, from, to}, m) do
    item = """
    CASE WHEN jsonb_typeof(e) = 'object' AND e ? $2::text
         THEN (e - $2::text) || jsonb_build_object($3::text, e -> $2::text)
         ELSE e END
    """

    {each_connection(item, m), sub_field_carries(m), [field, from, to]}
  end

  # An item tree's values (`KilnCMS.CMS.FlexiblePath`), qualified by every
  # step of the path.
  defp rewrite({:item, steps, op}, m), do: FlexiblePath.map_sql(steps, op, m)

  defp op_name(op) when is_atom(op), do: op
  defp op_name(op), do: elem(op, 0)

  # `item` rewrites one element `e` of the value under `$1` (a connection, a
  # group row); a list is rebuilt item by item, in its order.
  defp each_connection(item, m) do
    """
    jsonb_set(#{m}, ARRAY[$1::text],
      CASE jsonb_typeof(#{m} -> $1::text)
        WHEN 'array' THEN
          (SELECT COALESCE(jsonb_agg((#{item}) ORDER BY ord), '[]'::jsonb)
             FROM jsonb_array_elements(#{m} -> $1::text) WITH ORDINALITY AS x(e, ord))
        ELSE (SELECT (#{item}) FROM (SELECT #{m} -> $1::text AS e) AS one)
      END)
    """
  end

  defp link_carries(m) do
    "jsonb_path_exists(#{m} -> $1::text, 'lax $.link.keyvalue() ? (@.key == $k)', " <>
      "jsonb_build_object('k', $2::text))"
  end

  defp sub_field_carries(m) do
    "jsonb_path_exists(#{m} -> $1::text, 'lax $[*].keyvalue() ? (@.key == $k)', " <>
      "jsonb_build_object('k', $2::text))"
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
  #
  # Each statement is `{sql, params, what}`; the only interpolations are the
  # table name and the `$n` tail, as in `execute/4`.
  defp link_statements({:purge, name}, table, filter, params) do
    [
      {
        """
        DELETE FROM content_links
         WHERE kind = 'reference' AND (field = $1::text OR field LIKE $2::text)
           AND source_id IN (SELECT id FROM #{table} WHERE TRUE#{filter.(2)})
        """,
        [name, under(name) | params],
        "deleted the #{inspect(name)} reference links of"
      }
    ]
  end

  defp link_statements({:rename, from, to}, table, filter, params) do
    [
      {
        """
        UPDATE content_links
           SET field = $2::text || substr(field, char_length($1::text) + 1)
         WHERE kind = 'reference' AND (field = $1::text OR field LIKE $3::text)
           AND source_id IN (SELECT id FROM #{table} WHERE TRUE#{filter.(3)})
        """,
        [from, to, under(from) | params],
        "moved the #{inspect(from)} reference links to #{inspect(to)} on"
      }
    ]
  end

  # A list → single narrowing keeps each record's first reference, so its
  # edge (position 0) stays and every later one goes with the value it
  # mirrored. Single → list keeps the one edge at position 0 as it is. A media
  # field has no reference edges, so this matches nothing for a gallery.
  defp link_statements({:reshape, name, :to_single}, table, filter, params) do
    [
      {
        """
        DELETE FROM content_links
         WHERE kind = 'reference' AND field = $1 AND position > 0
           AND source_id IN (SELECT id FROM #{table} WHERE TRUE#{filter.(1)})
        """,
        [name | params],
        "deleted the narrowed #{inspect(name)} reference links of"
      }
    ]
  end

  defp link_statements({:reshape, _name, :to_list}, _table, _filter, _params), do: []

  # An item tree's edges follow their values: the path of the sub-field or
  # item type the operation names, as `ContentLinks.desired/2` keys them.
  defp link_statements({:item, steps, op}, table, filter, params) do
    prefix = edge_path(steps)

    case op do
      {:rename_field, from, to, _setting?} ->
        link_statements(
          {:rename, prefix <> "." <> from, prefix <> "." <> to},
          table,
          filter,
          params
        )

      {:purge_field, name, _setting?} ->
        link_statements({:purge, prefix <> "." <> name}, table, filter, params)

      # `steps` end in the item type under its old name.
      {:rename_type, to} ->
        renamed = edge_path(Enum.drop(steps, -1) ++ [{elem(List.last(steps), 0), to}])
        link_statements({:rename, prefix, renamed}, table, filter, params)

      :purge_type ->
        link_statements({:purge, prefix}, table, filter, params)
    end
  end

  # An item type destroyed with `purge_items?` already lost its items in the
  # destroy's own transaction; its edges go here, with the rest of the sync.
  defp link_statements({:item_links, steps}, table, filter, params),
    do: link_statements({:purge, edge_path(steps)}, table, filter, params)

  # A group's sub-field edges are `group.sub`.
  defp link_statements({:purge_sub_field, field, name}, table, filter, params),
    do: link_statements({:purge, field <> "." <> name}, table, filter, params)

  defp link_statements({:rename_sub_field, field, from, to}, table, filter, params),
    do:
      link_statements({:rename, field <> "." <> from, field <> "." <> to}, table, filter, params)

  # A link field's copy on the parent field's edges (R3): the edge's
  # `metadata` is the connection's `"link"` map.
  defp link_statements({:purge_link, field, name}, table, filter, params) do
    [
      {
        """
        UPDATE content_links
           SET metadata = metadata - $2::text
         WHERE kind = 'reference' AND field = $1 AND metadata ? $2::text
           AND source_id IN (SELECT id FROM #{table} WHERE TRUE#{filter.(2)})
        """,
        [field, name | params],
        "purged link value #{inspect(name)} from the links of"
      }
    ]
  end

  defp link_statements({:rename_link, field, from, to}, table, filter, params) do
    [
      {
        """
        UPDATE content_links
           SET metadata = (metadata - $2::text) || jsonb_build_object($3::text, metadata -> $2::text)
         WHERE kind = 'reference' AND field = $1 AND metadata ? $2::text
           AND source_id IN (SELECT id FROM #{table} WHERE TRUE#{filter.(3)})
        """,
        [field, from, to | params],
        "moved link value #{inspect(from)} to #{inspect(to)} on the links of"
      }
    ]
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

  def target(definition) do
    case target_resource(definition) do
      {:ok, resource} ->
        {:ok, table(resource), fn n -> " AND org_id = $#{n + 1}" end, [uuid(definition.org_id)]}

      :error ->
        :error
    end
  end

  @doc """
  The resource whose table `target/1` names: `KilnCMS.CMS.Entry` for a
  dynamic type's field, the content type's own resource otherwise, `:error`
  when the owner no longer resolves.
  """
  @spec target_resource(KilnCMS.CMS.FieldDefinition.t()) :: {:ok, module()} | :error
  def target_resource(%{type_definition_id: id}) when not is_nil(id), do: {:ok, KilnCMS.CMS.Entry}

  def target_resource(%{content_type: type} = definition) when not is_nil(type) do
    case KilnCMS.CMS.ContentTypes.get(type, definition.org_id) do
      %{resource: resource} -> {:ok, resource}
      _other -> :error
    end
  end

  def target_resource(_definition), do: :error

  defp table(resource), do: AshPostgres.DataLayer.Info.table(resource)

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, dumped} -> dumped
      :error -> value
    end
  end

  defp uuid(value), do: value
end
