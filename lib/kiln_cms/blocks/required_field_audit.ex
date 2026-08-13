defmodule KilnCMS.Blocks.RequiredFieldAudit do
  @moduledoc """
  Read-only scan for legacy rows holding `nil` in a block field now declared
  `required: true` (code-review finding #2 on PR #1250, following #935).

  #935 closed the *write-side* gap: a nested child now runs through the same
  Ash cast a top-level block does, so `allow_nil?: false` is enforced on every
  new write. It did nothing for rows written **before** that fix — the read
  path (`KilnCMS.CMS.BlockUnion.cast_stored`/`to_union_stored`) only does
  per-attribute type coercion, never `allow_nil?` enforcement (that's how the
  #935 gap existed at all), so a pre-#935 row with a `nil` in a required field
  keeps violating the schema `Kiln.Block.JsonSchema` now narrows to
  non-nullable for that field — forever, with nothing flagging it.

  This audit reports affected rows; it does **not** repair them. There is no
  universally safe value to backfill a missing *required* field with: an empty
  string, a placeholder, unpublishing the row, or asking an editor to fill it
  in are all defensible answers depending on the block and field, and picking
  wrong would silently rewrite published content. That is an editorial
  decision, not a mechanical one this task can make correctly — see
  `Mix.Tasks.Kiln.Blocks.AuditRequired` for the CLI entry point.
  """

  alias Kiln.Block.Info
  alias KilnCMS.Blocks

  @type violation :: %{
          org_id: Ash.UUID.t(),
          type: atom(),
          record_id: Ash.UUID.t(),
          path: String.t(),
          block_type: String.t(),
          field: atom()
        }

  @doc """
  Scan every content type across every org (or just `org_id`, when given via
  `opts`) for a `required: true` block field holding `nil`, top-level or
  nested at any depth inside `columns`.
  """
  @spec run(keyword()) :: [violation()]
  def run(opts \\ []) do
    org_ids =
      case Keyword.get(opts, :org_id) do
        nil -> KilnCMS.Accounts.list_org_ids()
        org_id -> [org_id]
      end

    for {type, resource} <- resources(),
        org_id <- org_ids,
        record <- stream_records(resource, org_id),
        violation <- scan_record(type, record) do
      violation
    end
  end

  # Every compiled content type plus the generic Entry tier (dynamic types) —
  # the same set `KilnCMS.Firing.Sweep.resources/0` iterates, since both need
  # "every resource carrying `blocks`".
  defp resources do
    compiled = Enum.map(KilnCMS.CMS.ContentTypes.all(), &{&1.type, &1.resource})
    Enum.uniq(compiled ++ [entry: KilnCMS.CMS.Entry])
  end

  defp stream_records(resource, org_id) do
    resource
    |> Ash.Query.select([:id, :org_id, :blocks])
    |> Ash.stream!(authorize?: false, tenant: org_id, stream_with: :full_read)
  end

  defp scan_record(type, record) do
    record.blocks
    |> scan_blocks()
    |> Enum.map(&Map.merge(&1, %{org_id: record.org_id, type: type, record_id: record.id}))
  end

  @doc """
  Walk one record's already-loaded `blocks` (whatever `cast_stored` produced —
  a list of `%Ash.Union{}` with raw nested-child maps inside any `columns`)
  and return the `required: true` fields holding `nil`, without the
  org/type/record-id metadata `run/1` merges in. Exposed separately so the
  pure tree-walk is unit-testable without a database.
  """
  @spec scan_blocks([term()]) :: [%{path: String.t(), block_type: String.t(), field: atom()}]
  def scan_blocks(blocks) do
    blocks
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.flat_map(fn {block, index} -> scan_block(block, "blocks[#{index}]") end)
  end

  # A top-level block: cast_stored has already turned it into `%Ash.Union{value:
  # %mod{}}`, atom-keyed.
  defp scan_block(%Ash.Union{value: %mod{} = struct}, path), do: scan(mod, struct, path)

  # A nested child: never went through `cast_stored` (the recursive-type
  # compile cycle `columns.columns` avoids by staying an untyped
  # `{:array, :map}` — see `KilnCMS.Blocks.Columns`), so it is still the raw,
  # string-keyed map it was written as.
  defp scan_block(%{} = map, path) do
    case block_module(map) do
      nil -> []
      mod -> scan(mod, map, path)
    end
  end

  defp scan_block(_other, _path), do: []

  defp scan(mod, carrier, path) do
    required_violations(mod, carrier, path) ++ nested_violations(mod, carrier, path)
  end

  defp required_violations(mod, carrier, path) do
    for field <- Info.fields(mod), field.required, is_nil(field_value(carrier, field.name)) do
      %{path: path, block_type: to_string(Info.name(mod)), field: field.name}
    end
  end

  defp field_value(%_{} = struct, name), do: Map.get(struct, name)
  defp field_value(%{} = map, name), do: Map.get(map, to_string(name), Map.get(map, name))

  # Only `columns` nests further, and only through its own `columns` field —
  # the one recursive slot in the registry (see the module doc on
  # `KilnCMS.Blocks.Columns`) — so it is the one block module whose children
  # need walking.
  defp nested_violations(KilnCMS.Blocks.Columns, carrier, path) do
    carrier
    |> field_value(:columns)
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.flat_map(fn {col, ci} -> scan_column(col, "#{path}.columns[#{ci}]") end)
  end

  defp nested_violations(_mod, _carrier, _path), do: []

  defp scan_column(%{} = col, path) do
    col
    |> field_value(:blocks)
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.flat_map(fn {child, bi} -> scan_block(child, "#{path}.blocks[#{bi}]") end)
  end

  defp scan_column(_other, _path), do: []

  defp block_module(%{} = map) do
    with type when not is_nil(type) <- Map.get(map, "_type") || Map.get(map, :_type),
         type_atom when not is_nil(type_atom) <- safe_atom(type),
         {:ok, mod} <- Blocks.fetch(type_atom) do
      mod
    else
      _ -> nil
    end
  end

  defp safe_atom(type) when is_atom(type), do: type

  defp safe_atom(type) when is_binary(type) do
    String.to_existing_atom(type)
  rescue
    ArgumentError -> nil
  end
end
