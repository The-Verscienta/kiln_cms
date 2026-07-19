defmodule KilnCMSWeb.InlineEditing do
  @moduledoc """
  Shared inline block-editing engine for the front-end editing surfaces:
  `KilnCMSWeb.InContextEditLive` (Kiln's own rendered page, #354) and
  `KilnCMSWeb.PresentationLive` (an external front end in an iframe, #355).

  Both hold the document's **full** block list as `BlockUnion` input maps
  (`block_inputs/1`) so a single-field edit rewrites only that field of one block
  and every sibling round-trips byte-for-byte — a partial form-params merge would
  drop blocks. `write/4` persists that working set through the same Ash actions
  (`:update` explicit save / `:autosave` debounced draft), so policies (#332) and
  PaperTrail versioning are native, and optimistic-lock conflicts surface as
  `:conflict` rather than clobbering a concurrent edit.
  """

  alias KilnCMS.CMS.TypedBlocks

  # The block types with a single inline-editable field, mapped to `{field,
  # mode}` (mode drives the client editor: plain text vs rich text).
  @inline_fields %{
    "heading" => {"text", :text},
    "quote" => {"text", :text},
    "rich_text" => {"legacy_html", :html}
  }

  @doc "The inline-editable block types → `{field, mode}`."
  @spec inline_fields() :: %{String.t() => {String.t(), :text | :html}}
  def inline_fields, do: @inline_fields

  @doc "The document's typed blocks as `BlockUnion` input maps (the save working set)."
  @spec block_inputs([struct()]) :: [map()]
  def block_inputs(typed), do: Enum.map(typed, &TypedBlocks.input_map/1)

  @doc """
  Flatten typed blocks to render descriptors `%{id, index, type, field, mode,
  value, struct}`, keeping each block's absolute position. `field`/`mode` are nil
  for read-only block types.
  """
  @spec editable_blocks([struct()]) :: [map()]
  def editable_blocks(typed) do
    typed
    |> Enum.with_index()
    |> Enum.map(fn {block, index} ->
      type = to_string(block._type)
      {field, mode} = Map.get(@inline_fields, type, {nil, nil})

      %{
        id: block.id,
        index: index,
        type: type,
        field: field,
        mode: mode,
        value: inline_value(block, field),
        struct: block
      }
    end)
  end

  @doc "The current text/HTML for an inline field; `\"\"` when unset, nil for read-only."
  @spec inline_value(struct(), String.t() | nil) :: String.t() | nil
  def inline_value(_block, nil), do: nil
  def inline_value(block, field), do: Map.get(block, String.to_existing_atom(field)) || ""

  @doc "Set `field` of the block at `index` in the working set."
  @spec put_block_field([map()], non_neg_integer(), String.t(), term()) :: [map()]
  def put_block_field(block_inputs, index, field, value) do
    List.update_at(block_inputs, index, &Map.put(&1, field, value))
  end

  @doc "Stable-id region element id, keyed by `version` so a save remounts it."
  @spec region_id(map(), non_neg_integer()) :: String.t()
  def region_id(block, version), do: "region-#{block.id}-v#{version}"

  @doc """
  Persist `block_inputs` through the `action` (`:update` / `:autosave`) as `actor`.
  Returns `{:ok, record}`, `:conflict` (optimistic-lock/StaleRecord — reload
  before saving), or `{:error, error}`.
  """
  @spec write(struct(), :update | :autosave, [map()], term()) ::
          {:ok, struct()} | :conflict | {:error, term()}
  def write(record, action, block_inputs, actor) do
    record
    # Scope the update to the record's own org (epic #336); `org_id` is
    # writable? false, so the tenant is the only way to keep the write in the
    # right site. Covers both the in-context editor and the Presentation console.
    |> Ash.Changeset.for_update(action, %{blocks: block_inputs},
      actor: actor,
      tenant: record.org_id
    )
    |> Ash.update()
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, error} -> if stale_conflict?(error), do: :conflict, else: {:error, error}
    end
  end

  @doc "True when a failed update was rejected by the optimistic lock (not validation)."
  @spec stale_conflict?(term()) :: boolean()
  def stale_conflict?(%Ash.Error.Changes.StaleRecord{}), do: true

  def stale_conflict?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &stale_conflict?/1)

  def stale_conflict?(_other), do: false
end
