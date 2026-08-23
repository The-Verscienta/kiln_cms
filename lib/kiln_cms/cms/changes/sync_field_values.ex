defmodule KilnCMS.CMS.Changes.SyncFieldValues do
  @moduledoc """
  Keeps the `custom_fields` keys stored on content in step with the
  `FieldDefinition` rows that govern them: **destroying** a definition purges
  its key, **renaming** one moves the values to the new key.

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

  defp sync(changeset, {:ok, definition} = result) do
    case operation(changeset, definition) do
      nil -> result
      op -> run(op, definition, result)
    end
  end

  defp sync(_changeset, other), do: other

  # A destroy purges; an update purges nothing unless `name` moved. Every other
  # definition edit (label, help text, position, even the field *type*) leaves
  # the key alone, so the stored values stay where they are.
  defp operation(%{action_type: :destroy}, definition), do: {:purge, definition.name}

  defp operation(%{action_type: :update} = changeset, definition) do
    previous = changeset.data.name

    if previous == definition.name, do: nil, else: {:rename, previous, definition.name}
  end

  defp operation(_changeset, _definition), do: nil

  defp run(op, definition, result) do
    case target(definition) do
      {:ok, table, filter, params} ->
        execute(op, table, filter, params)

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
