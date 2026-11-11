defmodule KilnCMS.CMS.Preparations.MaskPrivateFields do
  @moduledoc """
  Leaves the **private** custom fields (#2044, `KilnCMS.CMS.PrivateFields`)
  out of every content record a read returns to someone below editor.

  `custom_fields` is a public attribute, so JSON:API, GraphQL and MCP serve
  it as read. A private field's value is for the site's editors and admins,
  so for anyone else — an anonymous caller, a viewer, an API key without
  editor rights — the key is simply not there.

  Declared beside `MaskUnreadableReferences` on the resource's top-level
  `preparations`, so it runs on every read action, and skipped by the same
  rule, for the same reason: a value that could feed a write is returned
  whole.

    * `authorize?: false` reads (firing, workers, internal plumbing) — the
      fired artifacts drop private fields themselves
      (`KilnCMS.Firing.CustomFields`);
    * a `KilnCMS.SystemActor`;
    * an editor or admin of the org (`Scoping.effective_tier/2`).

  An **editor** under a read restriction for the record's type
  (`field_read_grants`, #2281) is served the record without the private fields
  that restriction hides (`KilnCMS.CMS.HiddenFields`), in `custom_fields` and in
  the held working copy's `"custom_fields"`. A write built on such a record
  puts them back (`Changes.RestoreHiddenFields`). Admins and the skips above
  still see everything.

  The stored value is never changed. The private names come from the site's
  cached map (`PrivateFields.all/1`), so a read costs no definitions query.
  """
  use Ash.Resource.Preparation

  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS.HiddenFields
  alias KilnCMS.CMS.PrivateFields

  @impl true
  def prepare(query, _opts, context) do
    case mode(query, context) do
      :skip ->
        query

      mode ->
        # The definitions are found by the record's org and (for an entry) its
        # type definition, which a read that names its fields — GraphQL's — may
        # not select: two keys more on such a read.
        query
        |> ensure_keys()
        |> refuse_probe(mode)
        |> Ash.Query.after_action(fn query, records ->
          {:ok, mask(records, mode, query.tenant)}
        end)
    end
  end

  # authorize?: false — a match on the read's own flag, not a bypass: such a
  # read is internal plumbing whose result may be written back.
  defp mode(_query, %{authorize?: false}), do: :skip
  defp mode(_query, %{actor: %KilnCMS.SystemActor{}}), do: :skip

  defp mode(query, %{actor: actor}) do
    case Scoping.effective_tier(actor, query) do
      :admin -> :skip
      :editor -> {:editor, actor}
      _below_editor -> :private
    end
  end

  defp ensure_keys(query) do
    keys =
      Enum.filter(
        [:org_id, :type_definition_id],
        &Ash.Resource.Info.attribute(query.resource, &1)
      )

    Ash.Query.ensure_selected(query, keys)
  end

  # A filter or sort on the whole `custom_fields` map would answer questions
  # about the keys an editor's read restriction hides. Checked once the query
  # is final (the API layers add `filter`/`sort` in their own order).
  defp refuse_probe(query, {:editor, actor}) do
    Ash.Query.before_action(query, fn query ->
      if HiddenFields.probes_hidden?(actor, query, query.tenant) do
        Ash.Query.add_error(query,
          field: :custom_fields,
          message:
            "cannot be filtered or sorted as a whole: some of its fields are hidden from you"
        )
      else
        query
      end
    end)
  end

  defp refuse_probe(query, _mode), do: query

  defp mask(records, :private, tenant), do: Enum.map(records, &mask_private(&1, tenant))

  # What an editor's read restriction hides depends on the record's type, not
  # the record: decided once per `{org, type definition}` in the batch, so a
  # page of rows costs the lookups of one (the grant resolution reads the
  # actor's membership).
  defp mask(records, {:editor, actor}, tenant) do
    {masked, _memo} =
      Enum.map_reduce(records, %{}, fn record, memo ->
        key = {Map.get(record, :org_id), Map.get(record, :type_definition_id)}

        {hidden, memo} =
          case memo do
            %{^key => hidden} ->
              {hidden, memo}

            _ ->
              hidden = HiddenFields.names(actor, record, tenant)
              {hidden, Map.put(memo, key, hidden)}
          end

        {HiddenFields.drop(record, hidden), memo}
      end)

    masked
  end

  defp mask_private(record, tenant) do
    case Map.get(record, :custom_fields) do
      values when is_map(values) and not is_struct(values) and map_size(values) > 0 ->
        %{record | custom_fields: PrivateFields.drop_for(values, record, tenant)}

      _ ->
        record
    end
  end
end
