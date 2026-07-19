defmodule KilnCMS.Collab do
  @moduledoc """
  Collaborative block editing over the one event substrate (Kiln v2 — D5/D14/F).

  Coarse-grained block operations (add/remove/update/reorder) and fine-grained
  prose patches are applied server-side, **persisted as `DocumentEvent`s** (so
  collaboration, history, and audit share one mechanism), and broadcast over
  PubSub to other editors' LiveViews. `KilnCMS.Collab.Locks` guards concurrent
  block edits.

  The editor LiveView subscribes via `subscribe/2` and applies ops via
  `apply_op/4`; the JS prose-sync hook turns TipTap changes into
  `{:update_block, …}` ops carrying Portable Text. (Presence avatars + the client
  hook are the browser-side layer wired with the editor rewrite.)
  """
  alias KilnCMS.History

  @topic_prefix "content"

  @doc "PubSub topic for a document's collaborative session."
  @spec topic(atom(), term()) :: String.t()
  def topic(type, id), do: "#{@topic_prefix}:#{type}:#{id}"

  @doc "Subscribe the calling process to a document's collaborative events."
  @spec subscribe(atom(), term()) :: :ok | {:error, term()}
  def subscribe(type, id), do: Phoenix.PubSub.subscribe(KilnCMS.PubSub, topic(type, id))

  @doc """
  Apply a block operation: persist it as an event and broadcast it.

  Ops: `{:add_block, block_map, index}`, `{:remove_block, block_id}`,
  `{:update_block, block_id, block_map}`, `{:reorder, [block_id]}`.
  """
  @spec apply_op(atom(), term(), tuple(), keyword()) :: {:ok, KilnCMS.History.DocumentEvent.t()}
  def apply_op(type, id, op, opts \\ []) do
    {kind, payload} = to_event(op)

    # `:org_id` (when the caller provides it) stamps the event with the document's
    # site (epic #336); History reads key on the globally-unique document id.
    {:ok, event} =
      History.record(type, id, kind, payload, actor_id: opts[:actor_id], org_id: opts[:org_id])

    Phoenix.PubSub.broadcast(
      KilnCMS.PubSub,
      topic(type, id),
      {:block_op, %{op: op, seq: event.seq, actor_id: opts[:actor_id]}}
    )

    {:ok, event}
  end

  defp to_event({:add_block, block, index}),
    do: {:block_added, %{"block" => block, "index" => index}}

  defp to_event({:remove_block, block_id}), do: {:block_removed, %{"block_id" => block_id}}

  defp to_event({:update_block, block_id, block}),
    do: {:block_updated, %{"block_id" => block_id, "block" => block}}

  defp to_event({:reorder, order}), do: {:blocks_reordered, %{"order" => order}}
end
