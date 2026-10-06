defmodule KilnCMS.Organize.Tagging do
  @moduledoc """
  Bulk tag review (#1596): propose **existing** tags across a filtered set of
  documents, and let the editor confirm per row.

  `KilnCMS.Search.Related.suggest_tags/2` already ranks only the site's
  existing tags — that constraint is the whole point (§6 of the plan) — and
  `apply/4` only ever attaches ids that were proposed for that row. Nothing is
  applied without a click, and on a published document the tags go to its
  working copy, so readers see nothing until *Publish changes*.

  ## The bound (scope item 6)

  This is the one path in `KilnCMS.Organize` that can reach model inference:
  `suggest_tags/2` computes an unpublished document's centroid on demand, one
  inference per uncached block, charged to `KilnCMS.LLM.Budget`'s
  `"search_embedding"` feature (#1076). A bulk run multiplies that by the
  selection, and `docs/automation.md` records a bulk move draining the
  embedding reserve. So the bound is designed in, in four layers:

    1. **Selection** — at most `KilnCMS.Organize.bound(:bulk_limit)` (20)
       documents per run.
    2. **Cost known before the call** — `cost/3` counts exactly the units the
       call would charge: 0 for a document with stored vectors (any published,
       indexed one), else its uncached embedding inputs (the count `Related`
       charges, from the same `VectorCache` keys); plus, on the first document
       that reaches the model, the run's uncached tag names. Nothing is
       charged speculatively.
    3. **Per-run cap** — `run_cap/0`, the per-user embedding window's count
       (default 60). A document whose cost alone exceeds what a run could ever
       spend (`max_doc_cost/0`) is marked `:too_large` and skipped — never
       retried, so *Continue* cannot loop on it. Otherwise the run stops
       *before* a document that would take it past the cap, or past the room
       left in the budget (`KilnCMS.Search.embedding_remaining/3`), so it never
       makes a charge the budget would refuse — a refused Hammer charge is
       still counted, and would spend the editor's window on failing.
    4. **The budget itself, as an unattended caller** — every call passes the
       editor's `user_id` *and* `unattended?: true`. The editor is waiting,
       but a bulk run is the multiplied caller the reserve (#943) exists for:
       held to `embedding_unattended_share` of the org window, it can never
       eat the half another editor's per-document panel relies on. The first
       `{:error, _}` stops the run (never "try the next one anyway": each
       refused charge still counts).

  Worst case per click: `run_cap/0` units (60 of the default 600/hour org
  window). Because the reserve check is `spent >= ceiling` rather than
  `spent + units`, a run started just under the ceiling can carry the org at
  most one document's cost past it — and layer 3 already sizes each document
  to the room left, so in practice not at all.

  A published library costs nothing: its documents have stored vectors, and
  the tag index is filled ahead of time in window-sized chunks
  (`KilnCMS.Organize.Terms.index_tag_vectors/3`) — which is why the console
  asks for that first.
  """
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Organize
  alias KilnCMS.Organize.Candidates
  alias KilnCMS.Organize.Clusters
  alias KilnCMS.Organize.Terms
  alias KilnCMS.Search
  alias KilnCMS.Search.BlockIndexer
  alias KilnCMS.Search.Related
  alias KilnCMS.Search.VectorCache

  @typedoc "One document's row in a run."
  @type row :: %{
          id: Ash.UUID.t(),
          type: String.t(),
          title: String.t() | nil,
          state: atom(),
          status: :proposed | :nothing | :too_large | :unavailable,
          suggestions: [%{term: Terms.t(), distance: float()}],
          cost: non_neg_integer()
        }

  @typedoc "Why a run stopped before its last document."
  @type stop ::
          :run_cap
          | {:rate_limited, non_neg_integer()}
          | :unattended_disabled

  @typedoc "A run: finished rows, where it stopped, and what is still queued."
  @type run :: %{
          rows: [row()],
          stopped: stop() | nil,
          pending: [Candidates.t()],
          spent: non_neg_integer()
        }

  @doc """
  The documents a run would cover: up to `bound(:bulk_limit)` candidates of
  `:type` (a public type name, or `nil` for all) in `:state` (`:any` default),
  optionally `untagged?: true`. Empty when semantic search is off.
  """
  @spec selection(term(), term(), keyword()) :: [Candidates.t()]
  def selection(org, actor, opts \\ []) do
    if Organize.enabled?() do
      filter = if Keyword.get(opts, :untagged?, false), do: Terms.untagged_filter()

      Candidates.list(org, actor,
        limit: Organize.bound(:bulk_limit),
        type: opts[:type],
        state: Keyword.get(opts, :state, :any),
        filter: filter
      )
    else
      []
    end
  end

  @doc "The most units one run may spend — the per-user embedding window's count."
  @spec run_cap() :: pos_integer()
  def run_cap do
    {count, _window} = Search.embedding_per_user_limit()
    count
  end

  @doc """
  The largest cost one document may have and still be proposed in bulk: the
  run cap, and never more than the unattended ceiling of the org window — a
  document above either could never be charged, by any run.
  """
  @spec max_doc_cost() :: non_neg_integer()
  def max_doc_cost do
    ceiling =
      KilnCMS.LLM.Budget.unattended_ceiling(
        Search.embedding_per_org_limit(),
        Search.embedding_unattended_share()
      )

    min(run_cap(), ceiling)
  end

  @doc """
  Proposes tags for each of `docs` (candidate rows) as `actor`, in order,
  under the bound in the moduledoc. Returns the finished rows, the stop
  reason (`nil` if it ran to the end) and the still-queued candidates —
  hand those back to `propose/3` to continue.

  Semantic search off ⇒ `%{rows: [], stopped: nil, pending: [], spent: 0}`
  without a read.
  """
  @spec propose(term(), term(), [Candidates.t()]) :: run()
  def propose(org, actor, docs) do
    if Organize.enabled?() and docs != [],
      do: run(org, actor, docs),
      else: %{rows: [], stopped: nil, pending: [], spent: 0}
  end

  defp run(org, actor, docs) do
    org_id = KilnCMS.Accounts.org_id(org)

    ctx = %{
      org: org,
      org_id: org_id,
      actor: actor,
      user_id: actor && actor.id,
      stored: Map.new(Clusters.centroids(org, Enum.map(docs, & &1.id)), &{elem(&1, 0), true}),
      tag_cost: tag_cost(org_id, org, actor)
    }

    step(docs, ctx, %{rows: [], stopped: nil, pending: [], spent: 0})
  end

  defp step([], _ctx, acc), do: finish(acc)

  defp step([doc | rest], ctx, acc) do
    case load(doc, ctx) do
      nil ->
        step(rest, ctx, add_row(acc, row(doc, :unavailable, [], 0)))

      record ->
        decide(record, doc, cost(record, ctx.stored, ctx.tag_cost), rest, ctx, acc)
    end
  end

  # A document that costs nothing (stored vectors, a fully cached tag index)
  # never touches the budget, so it runs whatever the budget says — a
  # published library is reviewable even with unattended embedding off.
  defp decide(record, doc, 0, rest, ctx, acc), do: call(record, doc, 0, rest, ctx, acc)

  defp decide(record, doc, cost, rest, ctx, acc) do
    cond do
      # A standing setting, not an overload: say so rather than "try later".
      unattended_off?() ->
        finish(%{acc | stopped: :unattended_disabled, pending: [doc | rest]})

      cost > max_doc_cost() ->
        step(rest, ctx, add_row(acc, row(doc, :too_large, [], cost)))

      acc.spent + cost > run_cap() ->
        finish(%{acc | stopped: :run_cap, pending: [doc | rest]})

      not room?(cost, ctx) ->
        {_count, window_ms} = Search.embedding_per_user_limit()
        finish(%{acc | stopped: {:rate_limited, window_ms}, pending: [doc | rest]})

      true ->
        call(record, doc, cost, rest, ctx, acc)
    end
  end

  defp unattended_off? do
    KilnCMS.LLM.Budget.unattended_ceiling(
      Search.embedding_per_org_limit(),
      Search.embedding_unattended_share()
    ) == 0
  end

  defp call(record, doc, cost, rest, ctx, acc) do
    case Terms.suggest(record,
           actor: ctx.actor,
           user_id: ctx.user_id,
           unattended?: true
         ) do
      {:error, reason} ->
        finish(%{acc | stopped: stop_reason(reason), pending: [doc | rest]})

      [] ->
        step(
          rest,
          after_charge(ctx, cost),
          charged(add_row(acc, row(doc, :nothing, [], cost)), cost)
        )

      suggestions ->
        step(
          rest,
          after_charge(ctx, cost),
          charged(add_row(acc, row(doc, :proposed, suggestions, cost)), cost)
        )
    end
  end

  # The run's uncached tag names are charged once, by whichever document first
  # reaches `suggest_tags/2` with a cost — after that they are stored.
  defp after_charge(ctx, 0), do: ctx
  defp after_charge(ctx, _cost), do: %{ctx | tag_cost: 0}

  defp charged(acc, cost), do: %{acc | spent: acc.spent + cost}

  defp stop_reason(:unattended_disabled), do: :unattended_disabled
  defp stop_reason({:rate_limited, ms}), do: {:rate_limited, ms}

  defp room?(cost, ctx) do
    case Search.embedding_remaining(ctx.org_id, ctx.user_id, true) do
      :infinity -> true
      room -> cost <= room
    end
  end

  defp add_row(acc, row), do: %{acc | rows: [row | acc.rows]}

  defp finish(acc), do: %{acc | rows: Enum.reverse(acc.rows)}

  defp load(doc, ctx) do
    case ContentTypes.get_record(doc.type, doc.id,
           actor: ctx.actor,
           tenant: ctx.org,
           load: Terms.term_load()
         ) do
      {:ok, record} -> record
      _gone_or_forbidden -> nil
    end
  end

  @doc """
  The budget units `Related.suggest_tags/2` would charge for `record`: 0 when
  it has stored vectors (`stored`, a set of document ids) or is published (a
  published document is never computed on demand — see `Related`'s centroid
  guard), else its uncached embedding inputs, keyed exactly as `Related`
  checks them; plus `tag_cost`, the run's uncached tag names, whenever the
  document reaches the model at all.
  """
  @spec cost(struct(), %{Ash.UUID.t() => true}, non_neg_integer()) :: non_neg_integer()
  def cost(record, stored, tag_cost) do
    cond do
      # Stored vectors: the centroid is free, the tag ranking is not.
      Map.has_key?(stored, record.id) ->
        tag_cost

      # Never computed on demand, so `suggest_tags/2` stops at the centroid.
      record.state == :published ->
        0

      true ->
        case BlockIndexer.embedding_inputs(record) do
          # Nothing to embed: no centroid, so it stops there too.
          [] -> 0
          inputs -> Enum.count(inputs, &(not VectorCache.raw_cached?(&1))) + tag_cost
        end
    end
  end

  defp tag_cost(org_id, org, actor) do
    org_id
    |> Related.missing_tag_vectors(Terms.tags(org, actor))
    |> Enum.count(&(not VectorCache.cached?(&1.name)))
  end

  defp row(doc, status, suggestions, cost) do
    %{
      id: doc.id,
      type: doc.type,
      title: doc.title,
      state: doc.state,
      status: status,
      suggestions: suggestions,
      cost: cost
    }
  end

  @doc """
  Applies the ticked subset of a row's proposal to its document, as `actor`.
  Ids that were not proposed for this row are dropped — a replayed or forged
  event can only ever attach a tag the review offered. Returns
  `{:ok, :saved}` (a draft), `{:ok, :working_copy}` (a published document —
  pending until *Publish changes*), `{:error, :nothing_ticked}`, or the
  write's own `{:error, _}`.
  """
  @spec apply(term(), term(), row(), [String.t()]) ::
          {:ok, :saved | :working_copy} | {:error, term()}
  def apply(org, actor, row, ticked) do
    offered = MapSet.new(row.suggestions, &to_string(&1.term.id))

    ids =
      ticked |> Enum.map(&to_string/1) |> Enum.filter(&MapSet.member?(offered, &1)) |> Enum.uniq()

    with [_ | _] <- ids,
         {:ok, record} <- ContentTypes.get_record(row.type, row.id, actor: actor, tenant: org),
         {:ok, _} <- Terms.apply_tags(row.type, record, ids, actor) do
      {:ok, if(record.state == :published, do: :working_copy, else: :saved)}
    else
      [] -> {:error, :nothing_ticked}
      {:error, reason} -> {:error, reason}
    end
  end
end
