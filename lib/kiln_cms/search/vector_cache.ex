defmodule KilnCMS.Search.VectorCache do
  @moduledoc """
  Memoizes embedding vectors for text that has already been embedded (#964).

  `KilnCMS.Search.BlockIndexer.block_vectors/1` embeds a document's blocks
  without storing them, so near-duplicate detection can run on a draft that has
  never been published (#852). That is one model inference **per block**, and
  the anchor is by definition being edited — so without memoization, changing
  one paragraph of a twenty-block draft re-embeds all twenty, on every panel
  open and on every `:flag_duplicates` job.

  ## Why its own Cachex instance

  The obvious home was `KilnCMS.Cache`, and that is the thing to avoid. That
  cache is bounded at 10,000 entries with an evented LRW policy, and the entries
  it would evict to make room are the `published:record:*` ones that
  `KilnCMS.Firing.Delivery` serves from when the database is unavailable. A bulk
  editing session would then trade a real availability guarantee for a saved
  inference. Two workloads, two instances, no competition.

  ## Why the key is the whole embedding configuration, not just the text

  Entries are **content-addressed**: the key is a digest of the exact string
  that was embedded, plus everything that decides what that string embeds *to*.
  The same input under the same configuration is always the same vector, so an
  entry cannot go stale and two documents containing the same paragraph share
  one entry.

  `model` alone is not that configuration. It is a compile-time constant in
  practice — nothing overrides `"BAAI/bge-small-en-v1.5"` — while `embedder`
  and `dim` genuinely change the vector. Keying on `model` alone means swapping
  the adapter serves the previous adapter's vectors for anything already
  cached, which is silent: the numbers are well-formed, just from a different
  space.

  SHA-256 rather than `:erlang.phash2/1`: the latter is 32-bit, and at this
  cache's size a birthday collision is around one in a few hundred — which would
  hand a block another block's vector and quietly corrupt every distance
  computed from it. Hashing is free next to an inference.
  """
  import Cachex.Spec, only: [hook: 1]

  alias KilnCMS.Search

  @cache :kiln_cms_vector_cache

  # ~12 KB per entry, not the 3 KB the raw f64 array suggests: a 384-element
  # list of floats is 1,536 words on the BEAM (768 of cons cells, 768 of boxed
  # floats). Measured, 2,000 entries is ~25 MB of ETS — so this cap is about
  # 25 MB, and raising it is a memory decision rather than a free one. Editing
  # sessions are bursty and localized; the cap exists to stop an import or a
  # scripted crawl growing the table without bound, not to hold a corpus.
  @max_entries 2_000

  # Long, because a content-addressed entry cannot be wrong — only unused.
  #
  # Passed as `expire:`, NOT `ttl:`. Cachex silently ignores unknown options, so
  # `ttl:` compiles, runs, and leaves the entry immortal — the same trap
  # `KilnCMS.Firing.Cache` documents. The only reclamation would then be the
  # entry cap.
  @ttl :timer.hours(24)

  @doc "The Cachex instance name (started in the application supervision tree)."
  def cache_name, do: @cache

  @doc "Supervisor child spec, bounded by an evented least-recently-written policy."
  def child_spec(_arg) do
    Supervisor.child_spec(
      {Cachex,
       name: @cache,
       hooks: [hook(module: Cachex.Limit.Evented, args: {@max_entries, [reclaim: 0.1]})]},
      id: __MODULE__
    )
  end

  @doc """
  The embedding for `text`, computed once per `{model, text}`.

  Answers `nil` when the embedder fails, and does **not** memoize that — an
  outage is transient, and caching it for a day would outlive the outage.
  """
  @spec embed(String.t()) :: [float()] | nil
  def embed(text) when is_binary(text) do
    case Cachex.fetch(@cache, key(text), fn _key -> commit(text) end) do
      {:ok, vector} ->
        vector

      {:commit, vector} ->
        vector

      {:ignore, vector} ->
        vector

      # The instance genuinely is not running — a cache that is down must not
      # take embedding down with it.
      {:error, :no_cache} ->
        embed_now(text)

      # Anything else already ran the fallback: Cachex's Courier rescues an
      # exception raised inside it and reports it here. Re-embedding would pay
      # a second inference for the same failure, which on a down
      # `Nx.Serving` means two batch timeouts per block rather than one.
      {:error, _ran_and_failed} ->
        nil
    end
  end

  # `:ignore` rather than committing the `nil`, and the difference is subtler
  # than it looks: `Cachex.fetch/3` re-runs its fallback when the stored value
  # is `nil`, so a committed failure would never be *served* — but it would
  # still occupy an entry, and this instance is capped. A run of failures during
  # an outage would evict real vectors to hold placeholders that can only ever
  # produce a miss.
  defp commit(text) do
    case embed_now(text) do
      nil -> {:ignore, nil}
      vector -> {:commit, vector, expire: @ttl}
    end
  end

  defp embed_now(text) do
    case Search.embed(text) do
      {:ok, vector} -> vector
      _error -> nil
    end
  end

  @doc """
  As `embed/1`, applying `KilnCMS.Search.document_prefix/0` first.

  Prefixing here rather than calling `Search.embed_document/1` keeps the key
  honest: it is a digest of the string that actually reached the adapter, so
  changing the prefix invalidates the entries it affects instead of serving
  vectors from the old instruction.
  """
  @spec embed_document(String.t()) :: [float()] | nil
  def embed_document(text) when is_binary(text), do: embed(Search.document_prefix() <> text)

  @doc """
  Whether `text` already has a cached vector — i.e. whether `embed_document/1`
  would answer from ETS rather than reaching the model.

  `KilnCMS.Search.Related.suggest_tags/2` checks this before spending a
  `KilnCMS.LLM.Budget` unit on a tag (#1076): a name this cache (or any earlier
  caller's) has already embedded costs nothing to embed again, and charging
  for it anyway would size the budget to the taxonomy's word list rather than
  to genuine inference volume.

  Racy against a concurrent `embed_document/1` committing the same key, same
  as everywhere else this cache is read — the worst case is one avoidable
  charge, not a wrong vector.
  """
  @spec cached?(String.t()) :: boolean()
  def cached?(text) when is_binary(text) do
    match?({:ok, true}, Cachex.exists?(@cache, key(Search.document_prefix() <> text)))
  end

  @doc false
  # Exported so a test can assert on an entry's presence and expiry without
  # restating the key shape — a second spelling would drift and quietly test
  # nothing.
  def key(text), do: {Search.embedder(), Search.model(), Search.dim(), sha256(text)}

  defp sha256(text), do: :crypto.hash(:sha256, text)
end
