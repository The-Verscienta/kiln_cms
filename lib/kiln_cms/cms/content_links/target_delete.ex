defmodule KilnCMS.CMS.ContentLinks.TargetDelete do
  @moduledoc """
  What purging a record does to the `:reference` fields that connect to it —
  each field's `on_target_delete` rule (R5 in `docs/relationships-plan.md`).

    * `:keep` (the default, and what every field did before R5) leaves the
      connection in the referrer's value and on the edge table, where the
      backlinks panel and `KilnCMS.CMS.ContentLinks.broken/2` report it as a
      broken reference until someone edits the referrer.
    * `:restrict` refuses the purge while any record connects through the
      field (`KilnCMS.CMS.Errors.TargetStillConnected`). Trash is still
      allowed, so an editor can take a record off the site without first
      unpicking every connection to it.
    * `:clear` removes the purged record from every referrer's value, as one
      write per referrer through the content resource's internal
      `:clear_reference_target` action, run as `KilnCMS.CMS.Bookkeeping` —
      the purge's consequence, not the purging admin's own edit of each
      referrer. Being an ordinary content write, it rewrites the referrer's
      edges (and the R3 link data on them) from the new value, records a
      version, and re-fires a published referrer, so its artifact and its
      re-fire edges (R0) stop naming the purged record.

  Purge only. Trash keeps both the record and the edges pointing at it, so
  a restore brings everything back and needs nothing from here.

  Both run inside the purge's transaction (`Changes.ApplyTargetDeleteRules`):
  a referrer that cannot be cleared fails the purge rather than leaving a
  value pointing at a record that is gone. A trashed referrer is cleared too,
  so restoring it later does not bring the dangling value back.
  """

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Bookkeeping
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Errors.TargetStillConnected
  alias KilnCMS.CMS.JoinGraduation

  @doc """
  `:ok`, or the error refusing the purge of `record` because a `:restrict`
  field still connects records to it — the first such field, by source type
  and name. A field graduated to a join resource with that rule
  (`KilnCMS.CMS.JoinGraduation.check_restrict/1`) refuses it the same way.
  """
  @spec check_restrict(struct()) :: :ok | {:error, Exception.t()}
  def check_restrict(record) do
    record
    |> inbound_by_rule(:restrict)
    |> Enum.sort_by(fn {{source_type, _field}, {definition, _links}} ->
      {source_type, definition.name}
    end)
    |> case do
      [] ->
        JoinGraduation.check_restrict(record)

      [{_key, {definition, links}} | _rest] ->
        count = links |> Enum.map(& &1.source_id) |> Enum.uniq() |> length()
        {:error, TargetStillConnected.exception(field_label: definition.label, count: count)}
    end
  end

  @doc """
  Remove the purged `record` from the value of every referrer whose field is
  `:clear`. `:ok`, or the first referrer write's error.
  """
  @spec clear_referrers(struct()) :: :ok | {:error, term()}
  def clear_referrers(record) do
    record
    |> inbound_by_rule(:clear)
    |> Enum.flat_map(fn {{source_type, field}, {_definition, links}} ->
      Enum.map(links, &{{source_type, &1.source_id}, field})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn {{source_type, source_id}, fields}, :ok ->
      case clear_one(source_type, source_id, Enum.uniq(fields), record) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @doc """
  `custom_fields` with `target_id` taken out of each of `fields`: a single
  reference to it is removed, and a list keeps its other items in order (and
  is removed once empty, as a blank optional field is). Every other field —
  and the link data on the items that stay — is left exactly as it was.
  """
  @spec drop_target(map() | nil, [String.t()], Ash.UUID.t()) :: map() | nil
  def drop_target(custom_fields, fields, target_id) when is_map(custom_fields) do
    Enum.reduce(fields, custom_fields, fn field, acc ->
      case without(Map.get(acc, field), target_id) do
        :unchanged -> acc
        nil -> Map.delete(acc, field)
        kept -> Map.put(acc, field, kept)
      end
    end)
  end

  def drop_target(custom_fields, _fields, _target_id), do: custom_fields

  # A value without the target: `nil` once nothing is left, `:unchanged`
  # when it never held it.
  defp without(%{"id" => target_id}, target_id), do: nil

  defp without(items, target_id) when is_list(items) do
    case Enum.reject(items, &match?(%{"id" => ^target_id}, &1)) do
      ^items -> :unchanged
      [] -> nil
      kept -> kept
    end
  end

  defp without(_absent_or_other, _target_id), do: :unchanged

  # Inbound reference edges (other records' only — a self-reference goes with
  # the record's own outgoing edges), grouped by the field they come through,
  # keeping the fields whose rule is `rule`.
  defp inbound_by_rule(record, rule) do
    links =
      record.id
      |> CMS.list_references_to!(%{}, bookkeeping(record.org_id))
      |> Enum.reject(&(&1.source_id == record.id))

    definitions =
      links
      |> Enum.map(& &1.source_type)
      |> Enum.uniq()
      |> Map.new(&{&1, definitions_for(&1, record.org_id)})

    links
    |> Enum.group_by(&{&1.source_type, &1.field})
    |> Enum.flat_map(fn {{source_type, field} = key, field_links} ->
      definitions
      |> Map.get(source_type, [])
      |> Enum.find(&(&1.name == field))
      |> case do
        %{on_target_delete: ^rule} = definition -> [{key, {definition, field_links}}]
        _other_rule_or_gone -> []
      end
    end)
  end

  # A type deleted since the edge was written has no definitions: its edges
  # follow the default, `:keep`.
  defp definitions_for(source_type, org_id) when is_binary(source_type) do
    opts = bookkeeping(org_id)

    case ContentTypes.get(source_type, org_id) do
      nil ->
        []

      %{source: :dynamic, definition: definition} ->
        CMS.field_definitions_for_definition!(definition.id, opts)

      %{type: type} ->
        CMS.field_definitions_for!(type, opts)
    end
    |> Enum.filter(&(&1.field_type == :reference))
  end

  defp definitions_for(_untyped, _org_id), do: []

  # The referrer is read live or trashed (see `referrer/3`); the write is the
  # bookkeeping's.
  defp clear_one(source_type, source_id, fields, target) do
    case referrer(source_type, source_id, target.org_id) do
      nil ->
        :ok

      source ->
        source
        |> Ash.Changeset.for_update(:clear_reference_target, %{},
          context: %{cleared_reference: %{target_id: target.id, fields: fields}},
          actor: Bookkeeping.system(),
          tenant: target.org_id
        )
        |> Ash.update()
        |> case do
          {:ok, _source} -> :ok
          {:error, error} -> {:error, error}
        end
    end
  end

  defp referrer(source_type, source_id, org_id) do
    # authorize?: false — the purge this follows is already authorized, and
    # the system actor reads only published content, so a draft referrer
    # would look absent and keep pointing at the purged record.
    opts = [authorize?: false, tenant: org_id]

    case ContentTypes.get_record(source_type, source_id, opts) do
      {:ok, source} ->
        source

      {:error, _not_live} ->
        source_type
        |> ContentTypes.list_trashed!(Keyword.put(opts, :query, filter: [id: source_id]))
        |> List.first()
    end
  end

  defp bookkeeping(org_id),
    do: [actor: Bookkeeping.system(), authorize_with: :error, tenant: org_id]
end
