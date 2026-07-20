defmodule KilnCMS.History do
  @moduledoc """
  The event-log domain + fold engine (Kiln v2 — decision D14).

  `record/5` appends a block-level event; `replay/3` folds events into the block
  tree at a point in time (full history / time-travel); `preview_at/3` renders a
  past state for a read-only time-travel preview.
  """
  use Ash.Domain

  require Ash.Query

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

  @doc """
  Null the `actor_id` on every event a now-erased user produced, retaining the
  events themselves (#212/#219). Runs as a trusted system job.
  """
  @spec anonymize_actor(Ecto.UUID.t()) :: :ok
  def anonymize_actor(actor_id) when is_binary(actor_id) do
    # An erased user's events may live in several orgs — iterate them
    # explicitly (#419 strict-tenancy prep) instead of one tenant-less global
    # sweep. Each org is isolated: one org's transient failure must not abort
    # erasure for the rest (a partial GDPR erasure is a compliance gap), so a
    # failure is logged and the sweep continues, then re-raised at the end so
    # the caller can retry (the op is idempotent).
    failures =
      Enum.reduce(KilnCMS.Accounts.list_org_ids(), [], fn org_id, failed ->
        try do
          DocumentEvent
          |> Ash.Query.filter(actor_id == ^actor_id)
          |> Ash.bulk_update!(:anonymize_actor, %{},
            authorize?: false,
            tenant: org_id,
            return_records?: false,
            return_errors?: true
          )

          failed
        rescue
          error ->
            require Logger
            Logger.error("anonymize_actor failed for org #{org_id}: #{inspect(error)}")
            [org_id | failed]
        end
      end)

    unless failures == [] do
      raise "anonymize_actor incomplete for orgs #{inspect(failures)} — retry the erasure"
    end

    :ok
  end

  # Two editors can race next_seq/2; the :doc_seq identity turns the loser into
  # a unique-constraint error, so re-read and retry a bounded number of times.
  @seq_conflict_retries 3

  @doc "Append an event, assigning the next per-document sequence number."
  @spec record(atom(), term(), atom(), map(), keyword()) ::
          {:ok, DocumentEvent.t()} | {:error, term()}
  def record(document_type, document_id, kind, payload, opts \\ []) do
    do_record(document_type, document_id, kind, payload, opts, @seq_conflict_retries)
  end

  defp do_record(document_type, document_id, kind, payload, opts, retries) do
    # Stamp the event with the document's own site when the caller knows it
    # (epic #336); reads/seq computation key on the globally-unique document_id,
    # so they stay org-correct without a tenant. Defaults to the sole org.
    result =
      append_event(
        %{
          document_type: document_type,
          document_id: document_id,
          seq: next_seq(document_type, document_id),
          kind: kind,
          payload: payload,
          actor_id: opts[:actor_id]
        },
        authorize?: false,
        tenant: opts[:org_id]
      )

    case result do
      {:error, error} when retries > 0 ->
        if seq_conflict?(error),
          do: do_record(document_type, document_id, kind, payload, opts, retries - 1),
          else: result

      _ ->
        result
    end
  end

  defp seq_conflict?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, fn
      %Ash.Error.Changes.InvalidAttribute{field: field} ->
        field in [:seq, :document_id, :document_type]

      %{constraint_name: "document_events_doc_seq_index"} ->
        true

      _ ->
        false
    end)
  end

  defp seq_conflict?(_), do: false

  @doc """
  Reconstruct a document's block list by folding its events. `opts`:
  `:upto_seq` (inclusive) or `:upto` (a `DateTime`, inclusive) for time-travel.
  """
  @spec replay(atom(), term(), keyword()) :: [map()]
  def replay(document_type, document_id, opts \\ []) do
    document_type
    |> events_since_snapshot(document_id, opts)
    |> Enum.reduce([], &fold/2)
  end

  # Fetch only the events the fold can actually use: those at or before the
  # cutoff, starting from the latest snapshot at-or-before it (fold/2 resets
  # its accumulator on a :snapshot, so earlier events never affect the result).
  defp events_since_snapshot(document_type, document_id, opts) do
    base =
      DocumentEvent
      |> Ash.Query.filter(document_type == ^document_type and document_id == ^document_id)
      |> upto_query(opts)

    from_seq =
      base
      |> Ash.Query.filter(kind == :snapshot)
      |> Ash.Query.sort(seq: :desc)
      |> Ash.Query.limit(1)
      |> Ash.Query.select([:seq])
      |> Ash.read_one!(authorize?: false)
      |> case do
        nil -> 1
        snapshot -> snapshot.seq
      end

    base
    |> Ash.Query.filter(seq >= ^from_seq)
    |> Ash.Query.sort(seq: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp upto_query(query, opts) do
    cond do
      seq = opts[:upto_seq] -> Ash.Query.filter(query, seq <= ^seq)
      at = opts[:upto] -> Ash.Query.filter(query, inserted_at <= ^at)
      true -> query
    end
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
    last =
      DocumentEvent
      |> Ash.Query.filter(document_type == ^document_type and document_id == ^document_id)
      |> Ash.Query.sort(seq: :desc)
      |> Ash.Query.limit(1)
      |> Ash.Query.select([:seq])
      |> Ash.read_one!(authorize?: false)

    case last do
      nil -> 1
      event -> event.seq + 1
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
