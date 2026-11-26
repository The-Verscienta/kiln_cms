defmodule KilnCMS.Cache.FillGuard do
  @moduledoc """
  Keeps a cache fill that read before a write's commit from storing its value
  after that write's bust (#2972).

  A read-through cache fills in two steps: read the source, then put the
  answer. A write commits and then busts the key. When the commit and the bust
  both land between a fill's read and its put, the bust deletes nothing (the
  entry is not there yet), the put lands afterwards, and the value the write
  replaced stays cached until its TTL. For `KilnCMS.Security.IpBlocklist` that
  was a new block rule not enforced, or a removed one still enforced, for up to
  a minute on that node; for `KilnCMS.Cache.Hosts` a new custom domain cached
  as unresolvable, or an old one still resolving.

  ## How

  A fill takes `begin/0` **before** it reads, and stores through `put/5`
  instead of `Cachex.put/4`. A bust goes through `bust/2` (or `clear/1`)
  instead of `Cachex.del/2`.

    * `bust/2` records a mark, the monotonic time of the bust, for each key,
      then deletes the keys, both inside one `Cachex.transaction/3` on the
      target cache.
    * `put/5` reads the key's mark (and the cache's whole-cache mark) inside a
      transaction on the same key of the same cache, and stores only when no
      mark is at or after the fill's `began`. Otherwise the value is
      **discarded**: still returned to the caller, never stored.
    * `clear/1` records a whole-cache mark and clears, in one transaction.

  The marks live in `KilnCMS.Cache.generation_cache_name/0`, under tuple keys
  that nothing else reads or routes, with a TTL of twice `window/0`.

  ## Why that is enough

  Every transaction on one Cachex instance runs, one at a time, in that
  instance's lock queue process, so a bust's mark-and-delete and a fill's
  check-and-put on the same cache are ordered one before the other. A bust
  runs after its write committed. For a fill whose read began before that
  commit:

    * check-and-put first: the value is stored, and the bust's delete, which
      comes after, removes it;
    * mark-and-delete first: the mark is at or after the fill's `began` (the
      fill began before the commit, the bust ran after it), so the fill
      discards. Equal times discard too.

  And a fill that began after the mark read after the commit, so its value is
  current and is stored. A fill older than `window/0` is discarded whatever
  the marks say: marks expire after twice the window, so a fill that slow could
  otherwise miss the mark that should have stopped it.

  A remote node applies the same `bust/2` when the cluster message reaches it
  (`KilnCMS.Cache.ClusterBust`), so the argument holds there from the moment
  the message lands. A node that never gets the message waits out the TTL, as
  before.

  ## What it does not do

  The request whose fill straddled the bust is still answered with the value
  it read. So can be any request that read the old value concurrently: it is
  served once, and not stored. The next miss reads the committed data.

  ## It fails open

  Every function here is total. When the lock queue or the mark store is down
  or restarting, `put/5` stores nothing and returns `:not_stored` (the caller
  still has its value), and `bust/2` and `clear/1` still delete. A cache
  outage makes a fill uncached, never an error.

  ## Rules for callers

    * The cache must be started with `transactions: true`. `Cachex.transaction/3`
      would turn it on anyway, silently; the child spec says so instead.
    * Never call this from inside another cache's transaction (or a
      `Cachex.get_and_update/3` callback): a process already in a transaction
      skips the lock queue, so the ordering above no longer holds.
    * Every put and every delete of a guarded key goes through here.
      `KilnCMS.Cache.FillGuardSourceTest` scans `lib/` for a raw
      `Cachex.put/del/clear` on a guarded cache.

  Cost: a cache hit is unchanged. A miss and a bust are each one call to the
  cache's lock queue.

  A discarded fill emits `[:kiln_cms, :cache, :fill_discarded]` with
  `%{count: 1}` and `%{cache: name, reason: :busted | :too_old}`.
  """

  require Logger

  @window :timer.minutes(5)
  @mark_ttl 2 * @window

  @doc """
  How long a fill may run and still be stored, in milliseconds. A fill whose
  `begin/0` is older than this is discarded.
  """
  @spec window() :: pos_integer()
  def window, do: @window

  @doc "The token a fill takes before it reads. Pass it to `put/5`."
  @spec begin() :: integer()
  def begin, do: System.monotonic_time()

  @doc """
  Store `value` under `key` in `cache` (with `Cachex.put/4`'s `opts`) unless a
  bust of `key`, or a clear of `cache`, ran at or after `began`.

  Returns `:stored`, `:discarded` (busted, or older than `window/0`), or
  `:not_stored` (the cache or its mark store could not be reached). Never
  raises or exits.
  """
  @spec put(atom(), term(), term(), keyword(), integer()) :: :stored | :discarded | :not_stored
  def put(cache, key, value, opts, began) when is_atom(cache) and is_integer(began) do
    check_and_put = fn -> check_and_put(cache, key, value, opts, began) end

    case guarded(fn -> Cachex.transaction(cache, [key], check_and_put) end) do
      {:ok, :stored} ->
        :stored

      {:ok, {:discarded, reason}} ->
        :telemetry.execute([:kiln_cms, :cache, :fill_discarded], %{count: 1}, %{
          cache: cache,
          reason: reason
        })

        :discarded

      _not_stored ->
        :not_stored
    end
  end

  @doc """
  Forget `keys` in `cache` on this node, and stop any fill already in flight
  for one of them from storing what it read.

  Always deletes, even when the marks cannot be written. Returns `:ok`.
  """
  @spec bust(atom(), [term()]) :: :ok
  def bust(cache, keys) when is_atom(cache) and is_list(keys) do
    marked =
      guarded(fn ->
        Cachex.transaction(cache, keys, fn ->
          now = System.monotonic_time()
          Enum.each(keys, &Cachex.put(marks(), mark_key(cache, &1), now, expire: @mark_ttl))
          Enum.each(keys, &Cachex.del(cache, &1))
          :deleted
        end)
      end)

    if marked != {:ok, :deleted}, do: Enum.each(keys, &guarded(fn -> Cachex.del(cache, &1) end))

    :ok
  end

  @doc """
  Empty `cache` on this node, and stop every fill already in flight for it
  from storing what it read.

  Always clears, even when the mark cannot be written. Returns `:ok`.
  """
  @spec clear(atom()) :: :ok
  def clear(cache) when is_atom(cache) do
    cleared =
      guarded(fn ->
        Cachex.transaction(cache, [], fn ->
          Cachex.put(marks(), all_key(cache), System.monotonic_time(), expire: @mark_ttl)
          Cachex.clear(cache)
          :cleared
        end)
      end)

    if cleared != {:ok, :cleared}, do: delete_each(cache)

    :ok
  end

  # `Cachex.clear/1` runs as a transaction itself, so without the lock queue
  # the fallback deletes key by key, which needs no queue for a key no
  # transaction holds.
  defp delete_each(cache) do
    case guarded(fn -> Cachex.keys(cache) end) do
      {:ok, keys} -> Enum.each(keys, &guarded(fn -> Cachex.del(cache, &1) end))
      _cache_down -> :ok
    end
  end

  # Runs in the cache's lock queue process: Cachex calls only, nothing that
  # can throw or exit (the queue rescues an exception, but an exit or a throw
  # would take it down).
  defp check_and_put(cache, key, value, opts, began) do
    case verdict(cache, key, began) do
      :fresh -> store(cache, key, value, opts)
      {:discarded, _reason} = discarded -> discarded
      :unknown -> :not_stored
    end
  end

  defp store(cache, key, value, opts) do
    case Cachex.put(cache, key, value, opts) do
      {:ok, true} -> :stored
      _error -> :not_stored
    end
  end

  defp verdict(cache, key, began) do
    if System.monotonic_time() - began > System.convert_time_unit(@window, :millisecond, :native),
      do: {:discarded, :too_old},
      else: marked_verdict(cache, key, began)
  end

  # A mark store that cannot be read proves nothing either way: `:unknown`.
  defp marked_verdict(cache, key, began) do
    with {:ok, mark} <- Cachex.get(marks(), mark_key(cache, key)),
         {:ok, all} <- Cachex.get(marks(), all_key(cache)) do
      if busted_since?(mark, began) or busted_since?(all, began),
        do: {:discarded, :busted},
        else: :fresh
    else
      _mark_store_down -> :unknown
    end
  end

  defp busted_since?(nil, _began), do: false
  defp busted_since?(at, began), do: at >= began

  defp marks, do: KilnCMS.Cache.generation_cache_name()

  defp mark_key(cache, key), do: {:fill_mark, cache, key}
  defp all_key(cache), do: {:fill_mark_all, cache}

  # The boundary with Cachex's processes. A lock queue that is down or
  # restarting exits the caller (its call has no timeout to fall back on), and
  # a cache that is not running returns an error; either way the fill is left
  # uncached and the bust falls back to a plain delete, rather than a cache
  # outage failing the request that asked.
  defp guarded(fun) do
    fun.()
  rescue
    error ->
      # The exception's type only: its message can carry a cache key.
      Logger.warning("FillGuard: a cache call raised #{inspect(error.__struct__)}")
      {:error, :raised}
  catch
    :exit, _reason -> {:error, :exited}
  end
end
