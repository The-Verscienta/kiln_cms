defmodule KilnCMS.History do
  @moduledoc """
  The event-log domain + fold engine (Kiln v2 — decision D14).

  `record/5` appends a block-level event; `replay/3` folds events into the block
  tree at a point in time (full history / time-travel); `preview_at/3` renders a
  past state for a read-only time-travel preview.

  ## Who the event log is read and written as (#1659)

  Every read and write here runs as `system/0`, a `KilnCMS.SystemActor` that
  `KilnCMS.History.DocumentEvent` admits by action name: `append`,
  `anonymize_actor`, the per-document `for_document` read and the erasure
  sweep's `by_actor` read. The plain `read` is not admitted, since nothing here
  lists the whole log. See `docs/policy-matrix.md`, "The system actor".

  Each call **fails closed** (`authorize_with: :error`, or
  `authorize_query_with: :error` on the erasure sweep). A refused read filters
  to "no events", and here that answer is never harmless: `next_seq/2` would
  hand out sequence number 1 again, `replay/3` would fold an empty document,
  and the GDPR erasure sweep would update nothing and report success.
  """
  use Ash.Domain

  require Ash.Query

  resources do
    resource KilnCMS.History.DocumentEvent do
      define :list_events, action: :read
      define :events_for, action: :for_document, args: [:document_type, :document_id]
      define :events_by_actor, action: :by_actor, args: [:actor_id]
      define :append_event, action: :append
    end
  end

  alias KilnCMS.Blocks
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.History.DocumentEvent

  # See `with_actor/2`.
  @actor_override {__MODULE__, :actor_override}

  @doc """
  The actor the History API reads and writes the event log as (#1659).

  A `KilnCMS.SystemActor`, admitted by name on `KilnCMS.History.DocumentEvent`
  (`append`, `anonymize_actor`, `for_document`, `by_actor`), rather than
  `authorize?: false`, which would skip every policy on it.
  """
  @spec system() :: KilnCMS.SystemActor.t() | nil
  def system do
    case Process.get(@actor_override, :unset) do
      :unset -> KilnCMS.SystemActor.new(:history)
      actor -> actor
    end
  end

  @doc false
  # Test seam (#1659): run `fun` with `system/0` answering `actor` in this
  # process. It exists so a test can take the grant away and prove that every
  # event-log read and write fails CLOSED (raises) rather than filtering to
  # "no events". Process-local, and nothing on a request path calls it; code
  # that could call it could equally pass any actor it liked.
  @spec with_actor(term(), (-> result)) :: result when result: term()
  def with_actor(actor, fun) do
    previous = Process.get(@actor_override, :unset)
    Process.put(@actor_override, actor)

    try do
      fun.()
    after
      if previous == :unset,
        do: Process.delete(@actor_override),
        else: Process.put(@actor_override, previous)
    end
  end

  @doc """
  Null the `actor_id` on every event a now-erased user produced, retaining the
  events themselves (#212/#219). Runs as `system/0`.

  **Fails closed.** A bulk update authorizes its query as a filter by default,
  so a lost grant would match no rows, update nothing and return success: an
  erasure that erased nothing. `authorize_query_with: :error` turns that into a
  raise, which the per-org rescue below records as a failed org, so the caller
  sees the erasure as incomplete and retries it.
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
          |> Ash.Query.for_read(:by_actor, %{actor_id: actor_id},
            actor: system(),
            tenant: org_id
          )
          |> Ash.bulk_update!(:anonymize_actor, %{},
            actor: system(),
            authorize_query_with: :error,
            authorize_changeset_with: :error,
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
    # (epic #336). The sequence read runs under the same tenant as the write:
    # the `:doc_seq` identity is per org, and strict tenancy (#419) refuses a
    # tenant-less read outright. Without `:org_id` the fail-open build reads
    # across orgs and the write defaults to the sole org, as before.
    result =
      append_event(
        %{
          document_type: document_type,
          document_id: document_id,
          seq: next_seq(document_type, document_id, opts[:org_id]),
          kind: kind,
          payload: payload,
          actor_id: opts[:actor_id]
        },
        actor: system(),
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
  `:upto_seq` (inclusive) or `:upto` (a `DateTime`, inclusive) for time-travel,
  and `:org_id`, the document's site, which strict tenancy requires.
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
  #
  # Both reads fail closed: a refused snapshot probe would restart the fold at
  # seq 1, and a refused event read would fold to an empty document.
  defp events_since_snapshot(document_type, document_id, opts) do
    base =
      document_type
      |> for_document(document_id, opts[:org_id])
      |> upto_query(opts)

    from_seq =
      base
      |> Ash.Query.filter(kind == :snapshot)
      |> Ash.Query.sort([seq: :desc], prepend?: true)
      |> Ash.Query.limit(1)
      |> Ash.Query.select([:seq])
      |> Ash.read_one!(authorize_with: :error)
      |> case do
        nil -> 1
        snapshot -> snapshot.seq
      end

    base
    |> Ash.Query.filter(seq >= ^from_seq)
    |> Ash.read!(authorize_with: :error)
  end

  # One document's events, oldest first, as `system/0`: the `for_document`
  # read is the only one the system actor is admitted to.
  defp for_document(document_type, document_id, org_id) do
    Ash.Query.for_read(
      DocumentEvent,
      :for_document,
      %{document_type: document_type, document_id: document_id},
      actor: system(),
      tenant: org_id
    )
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

  # A uniqueness decision, so it fails CLOSED. A refused read filters to "no
  # events", which would answer 1 for a document that already has a seq 1. The
  # `:doc_seq` identity would still reject the duplicate, but only as a
  # conflict that `do_record/6` retries into the same wrong answer, and a
  # conflict is not what happened. `authorize_with: :error` raises instead.
  defp next_seq(document_type, document_id, org_id) do
    last =
      document_type
      |> for_document(document_id, org_id)
      |> Ash.Query.sort([seq: :desc], prepend?: true)
      |> Ash.Query.limit(1)
      |> Ash.Query.select([:seq])
      |> Ash.read_one!(authorize_with: :error)

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
