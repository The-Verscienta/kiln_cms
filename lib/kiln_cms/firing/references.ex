defmodule KilnCMS.Firing.References do
  @moduledoc """
  Reference extraction + the re-fire wave (Kiln v2 — decision D13).

  References resolve/embed at fire time (decision A3), so a referrer's artifact
  goes stale when its target re-fires. This module:

    * `extract/1` / `references/1` — pull reference edges out of a typed block tree
    * `rebuild/3` — replace a document's outgoing edges (called on every fire)
    * `invalidate/3` — enqueue cycle-safe re-fire jobs for a changed doc's referrers

  References live either in a block's DSL `:reference` field(s) or, for legacy
  content bridged to `Custom`, in `data["ref"]` / `data["refs"]`
  (`%{"type" => "page"|"post", "id" => uuid}`).
  """
  alias KilnCMS.Blocks.{Columns, Custom}
  alias KilnCMS.CMS
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.Firing
  alias KilnCMS.Firing.{Engine, RefireWorker}

  require Ash.Query

  # `"entry"` is the generic tier holding every admin-defined dynamic type
  # (D17) — one storage key, the dynamic name is recoverable from the row.
  @types %{"page" => :page, "post" => :post, "entry" => :entry}

  @doc "Reference edges out of a document: `[%{from: {type,id}, to: {type,id}}]`."
  @spec references(struct()) :: [%{from: {atom(), term()}, to: {atom(), term()}}]
  def references(document) do
    from = {Engine.document_type(document), document.id}

    document
    |> Map.get(:blocks)
    |> TypedBlocks.to_typed()
    |> extract()
    |> Enum.map(&%{from: from, to: &1})
  end

  @doc "Distinct `{to_type, to_id}` targets referenced by a typed block list."
  @spec extract([struct()]) :: [{atom(), term()}]
  def extract(typed_blocks) do
    typed_blocks
    |> List.wrap()
    |> Enum.flat_map(&block_refs/1)
    |> Enum.uniq()
  end

  @doc "Replace a document's outgoing edges to match its current block tree."
  @spec rebuild(atom(), term(), [struct()]) :: :ok
  def rebuild(from_type, from_id, typed_blocks) do
    Firing.ReferenceEdge
    |> Ash.Query.filter(from_type == ^from_type and from_id == ^from_id)
    |> Ash.bulk_destroy!(:destroy, %{}, authorize?: false)

    typed_blocks
    |> extract()
    |> Enum.map(fn {to_type, to_id} ->
      %{from_type: from_type, from_id: from_id, to_type: to_type, to_id: to_id}
    end)
    |> Ash.bulk_create!(Firing.ReferenceEdge, :upsert,
      authorize?: false,
      return_errors?: true,
      stop_on_error?: true,
      # The :edge identity spans every attribute, so a conflicting row is
      # already identical — bulk upsert just needs *some* field to "update".
      upsert_fields: [:to_id]
    )

    :ok
  end

  @doc """
  Enqueue re-fire jobs for everything that references `{to_type, to_id}`, skipping
  any node already in `visited` (cycle-safe). The originating doc's key should be
  in `visited` so it is not re-fired by its own wave.
  """
  @spec invalidate(atom(), term(), [String.t()]) :: :ok
  def invalidate(to_type, to_id, visited) do
    {:ok, edges} = Firing.edges_to(to_type, to_id, authorize?: false)

    edges
    |> Enum.map(&{&1.from_type, &1.from_id})
    |> Enum.uniq()
    |> Enum.reject(fn {ft, fid} -> key(ft, fid) in visited end)
    |> Enum.each(fn {ft, fid} ->
      %{"type" => to_string(ft), "id" => fid, "visited" => visited}
      |> RefireWorker.new()
      |> Oban.insert()
    end)

    :ok
  end

  @doc "Stable wave key for a node."
  @spec key(atom(), term()) :: String.t()
  def key(type, id), do: "#{type}:#{id}"

  @doc "Map a stored type string to its atom (whitelisted; avoids dynamic atoms)."
  @spec type_atom(atom() | String.t()) :: atom() | nil
  def type_atom(type) when is_atom(type), do: type
  def type_atom(type) when is_binary(type), do: Map.get(@types, type)

  @doc "Load a document by type+id only if it is currently published."
  @spec load_published(atom(), term()) :: {:ok, struct()} | :error
  def load_published(:page, id), do: published(CMS.get_page(id, authorize?: false))
  def load_published(:post, id), do: published(CMS.get_post(id, authorize?: false))
  def load_published(:entry, id), do: published(CMS.get_entry(id, authorize?: false))
  def load_published(_type, _id), do: :error

  defp published({:ok, %{state: :published} = doc}), do: {:ok, doc}
  defp published(_), do: :error

  # A `columns` container has no refs of its own, but its nested children may —
  # recurse so a reference inside a column is tracked like a top-level one.
  defp block_refs(%Columns{} = block),
    do: block |> Columns.child_blocks_flat() |> Enum.flat_map(&block_refs/1)

  defp block_refs(%mod{} = block), do: dsl_refs(mod, block) ++ custom_refs(block)

  defp dsl_refs(mod, block) do
    mod
    |> Kiln.Block.Info.fields()
    |> Enum.filter(&reference_field?/1)
    |> Enum.flat_map(fn field -> block |> Map.get(field.name) |> normalize_refs() end)
  end

  defp reference_field?(%{type: :reference}), do: true
  defp reference_field?(%{type: {:array, :reference}}), do: true
  defp reference_field?(_), do: false

  defp custom_refs(%Custom{data: data}) when is_map(data) do
    normalize_refs(List.wrap(Map.get(data, "ref")) ++ (Map.get(data, "refs") || []))
  end

  defp custom_refs(_), do: []

  defp normalize_refs(nil), do: []
  defp normalize_refs(list) when is_list(list), do: Enum.flat_map(list, &normalize_refs/1)

  defp normalize_refs(%{"type" => type, "id" => id}) do
    case type_atom(type) do
      nil -> []
      atom -> [{atom, id}]
    end
  end

  defp normalize_refs(_), do: []
end
