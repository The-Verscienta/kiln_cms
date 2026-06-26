defmodule KilnCMS.History do
  @moduledoc """
  The event-log domain + fold engine (Kiln v2 — decision D14).

  `record/5` appends a block-level event; `replay/3` folds events into the block
  tree at a point in time (full history / time-travel); `preview_at/3` renders a
  past state for a read-only time-travel preview.
  """
  use Ash.Domain

  resources do
    resource KilnCMS.History.DocumentEvent do
      define :list_events, action: :read
      define :events_for, action: :for_document, args: [:document_type, :document_id]
      define :append_event, action: :append
    end
  end

  alias KilnCMS.Blocks
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.History.DocumentEvent

  @doc "Append an event, assigning the next per-document sequence number."
  @spec record(atom(), term(), atom(), map(), keyword()) ::
          {:ok, DocumentEvent.t()} | {:error, term()}
  def record(document_type, document_id, kind, payload, opts \\ []) do
    append_event(
      %{
        document_type: document_type,
        document_id: document_id,
        seq: next_seq(document_type, document_id),
        kind: kind,
        payload: payload,
        actor_id: opts[:actor_id]
      },
      authorize?: false
    )
  end

  @doc """
  Reconstruct a document's block list by folding its events. `opts`:
  `:upto_seq` (inclusive) or `:upto` (a `DateTime`, inclusive) for time-travel.
  """
  @spec replay(atom(), term(), keyword()) :: [map()]
  def replay(document_type, document_id, opts \\ []) do
    {:ok, events} = events_for(document_type, document_id, authorize?: false)

    events
    |> filter_upto(opts)
    |> Enum.reduce([], &fold/2)
  end

  @doc "Render a past state for time-travel preview (reuses the typed serializers)."
  @spec preview_at(atom(), term(), keyword()) :: {:ok, %{blocks: [map()], web: map()}}
  def preview_at(document_type, document_id, opts \\ []) do
    blocks = replay(document_type, document_id, opts)

    html =
      blocks
      |> TypedBlocks.to_typed()
      |> Enum.map(&Blocks.render(&1, :web))
      |> IO.iodata_to_binary()

    {:ok, %{blocks: blocks, web: %{"html" => html}}}
  end

  defp next_seq(document_type, document_id) do
    {:ok, events} = events_for(document_type, document_id, authorize?: false)

    case List.last(events) do
      nil -> 1
      event -> event.seq + 1
    end
  end

  defp filter_upto(events, opts) do
    cond do
      seq = opts[:upto_seq] -> Enum.filter(events, &(&1.seq <= seq))
      at = opts[:upto] -> Enum.filter(events, &(DateTime.compare(&1.inserted_at, at) != :gt))
      true -> events
    end
  end

  # ── fold: events → block list ──────────────────────────────────────────────

  defp fold(%{kind: :snapshot, payload: %{"blocks" => blocks}}, _acc), do: blocks

  defp fold(%{kind: :block_added, payload: %{"block" => block} = p}, acc),
    do: List.insert_at(acc, p["index"] || length(acc), block)

  defp fold(%{kind: :block_removed, payload: %{"block_id" => id}}, acc),
    do: Enum.reject(acc, &(block_id(&1) == id))

  defp fold(%{kind: :block_updated, payload: %{"block_id" => id, "block" => block}}, acc),
    do: Enum.map(acc, fn b -> if block_id(b) == id, do: block, else: b end)

  defp fold(%{kind: :blocks_reordered, payload: %{"order" => order}}, acc),
    do:
      Enum.sort_by(acc, fn b -> Enum.find_index(order, &(&1 == block_id(b))) || length(order) end)

  defp fold(_event, acc), do: acc

  defp block_id(block), do: Map.get(block, "id") || Map.get(block, :id)
end
