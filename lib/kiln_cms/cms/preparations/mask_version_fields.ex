defmodule KilnCMS.CMS.Preparations.MaskVersionFields do
  @moduledoc """
  Leaves the private custom fields an editor's read restriction hides
  (`field_read_grants`, #2281) out of a version's `changes` snapshot.

  A version row carries the dumped attributes one write changed, so history
  would hand a restricted editor the very values the document's own read
  withholds (`Preparations.MaskPrivateFields`) — in `custom_fields` and in the
  held working copy's `"custom_fields"`. This masks them, so the version list,
  the compare modal, the restore preview and a revision download all agree
  with the document: both sides of a diff are missing the same keys.

  Mixed into every version resource by `KilnCMS.CMS.VersionPolicies`. Skipped
  for `authorize?: false` reads (the governance chain, point-in-time, workers),
  a system actor and admins. Non-editors cannot read versions at all.

  A read that is going to be WRITTEN BACK carries
  `context: %{kiln_raw_versions: true}` and is returned whole
  (`Changes.CoalesceAutosaveVersions` merges and rewrites the rows it reads: a
  masked read would erase the hidden values from history for good). The flag is
  set by Elixir callers only; no API can send query context.

  The type of a version's document is not on the row (history is changes-only),
  so it comes from the source: the version module's parent resource, and for
  the shared entry tier the source row's `type_definition_id`.
  """
  use Ash.Resource.Preparation

  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.HiddenFields

  require Ash.Query

  @impl true
  def prepare(query, _opts, context) do
    case mode(query, context) do
      {:editor, actor} ->
        query
        |> Ash.Query.ensure_selected([:org_id, :version_source_id, :changes])
        |> Ash.Query.after_action(fn query, versions ->
          {:ok, mask(versions, actor, query.resource)}
        end)

      :skip ->
        query
    end
  end

  # authorize?: false — a match on the read's own flag, not a bypass: such a
  # read is internal plumbing.
  defp mode(_query, %{authorize?: false}), do: :skip
  defp mode(_query, %{actor: %KilnCMS.SystemActor{}}), do: :skip

  defp mode(query, %{actor: actor}) do
    cond do
      query.context[:kiln_raw_versions] == true -> :skip
      Scoping.effective_tier(actor, query) == :editor -> {:editor, actor}
      true -> :skip
    end
  end

  defp mask([], _actor, _version_module), do: []

  defp mask(versions, actor, version_module) do
    source = source_resource(version_module)
    scopes = scopes(versions, source)

    {masked, _memo} =
      Enum.map_reduce(versions, %{}, fn version, memo ->
        {scope, type} = Map.fetch!(scopes, version.version_source_id)
        key = {version.org_id, scope, type}

        {hidden, memo} =
          case memo do
            %{^key => hidden} ->
              {hidden, memo}

            _ ->
              hidden = HiddenFields.names_for_scope(actor, version.org_id, scope, type)
              {hidden, Map.put(memo, key, hidden)}
          end

        {%{version | changes: HiddenFields.drop_changes(version.changes, hidden)}, memo}
      end)

    masked
  end

  defp source_resource(version_module) do
    version_module |> Module.split() |> Enum.drop(-1) |> Module.concat()
  end

  # `{private-field scope, grant key}` per source document. A compiled type is
  # one scope for every version; an entry's depends on its type definition,
  # which only the source row knows.
  defp scopes(versions, source) do
    if function_exported?(source, :__kiln_dynamic_entry__, 0) do
      entry_scopes(versions, source)
    else
      fixed = {ContentTypes.type_atom(source), ContentTypes.type_name(source)}
      Map.new(versions, &{&1.version_source_id, fixed})
    end
  end

  defp entry_scopes(versions, source) do
    org_id = versions |> List.first() |> Map.get(:org_id)
    ids = versions |> Enum.map(& &1.version_source_id) |> Enum.uniq()

    # authorize?: false — a lookup of which type each document is, selecting
    # two columns; the rows never leave this function. The reader was already
    # authorized to read these documents' history.
    definition_ids =
      source
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.select([:id, :type_definition_id])
      |> Ash.read!(authorize?: false, tenant: org_id)
      |> Map.new(&{&1.id, &1.type_definition_id})

    Map.new(ids, fn id ->
      definition_id = Map.get(definition_ids, id)

      type =
        ContentTypes.type_name_for(
          struct(source, type_definition_id: definition_id, org_id: org_id)
        )

      {id, {definition_id || ContentTypes.type_atom(source), type}}
    end)
  end
end
