defmodule KilnCMS.Accounts.ThrottleStore do
  @moduledoc """
  The shared store behind every budget that bounds credential guessing (#1619).

  `KilnCMS.Accounts.AccountThrottle` and the credential buckets of
  `KilnCMSWeb.RateLimit` (`:auth`, `:register`, `:unlock`) charge through here.
  A budget is a fixed-window counter in `KilnCMS.Accounts.ThrottleCounter`'s
  Postgres table, so it holds across every node and across a restart. Until
  this, each node counted in its own ETS table: N nodes gave an attacker N
  budgets, and a deploy forgave every attempt.

  ## One statement, and why it is raw SQL

  `hit/5` is a single upsert:

      INSERT ... ON CONFLICT (bucket, key_hash, window_index)
        DO UPDATE SET count = c.count + EXCLUDED.count
      RETURNING count, <ms until the window closes>

  That is the same guarantee Hammer's `:ets.update_counter` gave: the increment
  *is* the check, so a simultaneous burst cannot all read "under budget" (see
  `AccountThrottle`'s moduledoc on check-then-count). Postgres serializes the
  conflicting updates on the row lock.

  It goes through `KilnCMS.Repo.query/3` rather than an Ash action, and the
  table is still an Ash resource. Two reasons, both about this one statement:

    * **The window comes from the database clock.** `window_index` and
      `expires_at` are computed from `clock_timestamp()` inside the statement,
      so two nodes whose clocks disagree still land on the same row. An Ash
      upsert takes its primary key from the application, which would put one
      window's attempts on as many rows as there are clock skews.
    * **It is the sign-in hot path**, and it runs on every attempt. Measured
      locally (Postgres 17, Apple silicon; `docs/threat-model.md`, residual 10):
      p50 0.34 ms / p99 1.1 ms sequential, and 1.1 / 5.4 ms with sixteen
      concurrent writers on one key — against a 208 ms bcrypt verification
      the same attempt pays. One round trip, no changeset.

  `KilnCMS.Collab.Crdt.DocServer` makes the same call for its checkpoint upsert.

  ## Tallies

  `count/3` and `window_count/3` use the same table for a counter that is not
  a budget: the security alerts' failed-sign-in tally per site (#2245). It
  never refuses, returns the window index alongside the count, and keeps its
  row an hour past the window's end (through `expires_at`, so the prune needs
  no special case) for the summary that reads the closed window's total.

  ## Never inside a transaction

  A charge made inside a transaction is **refunded by its rollback** — and a
  failed attempt is exactly what rolls a transaction back. A registration whose
  address is taken, say: the charge would vanish with the insert, and the
  budget would bound nothing. So `hit/5` raises when called inside one. That is
  a programming error, not a runtime condition, and every caller is exercised
  by the suite: charge from `before_transaction`, from a read's
  `before_action`, or before the action runs at all. (`forget/2` has no such
  rule: a forgiveness rolled back with the success it followed is correct.)

  ## When the database cannot answer: count on this node

  A limiter has three choices when its store is unreachable, and this one takes
  the middle:

    * **Fail open** (admit everything) means unbounded guessing for as long as
      the fault lasts. The counter can fail on its own — its table missing
      during a rolling deploy, a lock timeout, a saturated pool — while the
      user lookup behind it still works.
    * **Fail closed** (refuse everything) turns the limiter into a lever: an
      attacker who can make one query slow, or a blip that trips the pool,
      locks every account out of sign-in at once. That is the hard-lockout
      shape `AccountThrottle` was designed to avoid, arriving by another road.
    * **Degrade to the node** — what this does. The budget is charged against
      a node-local ETS counter (`Local`, Hammer's fixed window, the same keys),
      so it still holds, per node. That is exactly the bound Kiln shipped before
      #1619, so a database fault never leaves a budget weaker than it used to
      be, and never refuses anyone the budget would have admitted.

  The fallback is logged at `:error` (at most once a minute per node, so an
  outage is not also a log flood), naming the bound it fell back to. When the
  database answers again, the shared counter takes over; attempts counted
  locally meanwhile are not copied back.

  Deliberately **not** a fallback: an in-transaction call. That raises (above)
  rather than counting locally, because it is a bug that would otherwise pass
  every single-node test.
  """

  require Logger

  alias KilnCMS.Repo

  defmodule Local do
    @moduledoc false
    # The node-local fallback: Hammer's ETS fixed window, keyed
    # `{bucket, key_hash}`. Only ever written while the database cannot answer.
    use Hammer, backend: :ets
  end

  # Short, so a stuck row lock or a saturated pool degrades a sign-in to the
  # node-local bound in two seconds rather than holding it for the Repo's
  # fifteen.
  @timeout 2_000

  # A prune deletes in batches this size, so an attack that left millions of
  # closed windows behind does not become one long DELETE. Capped per run; the
  # next run takes the rest.
  @prune_batch 10_000
  @prune_max_batches 100

  @hit_sql """
  INSERT INTO throttle_counters AS c (bucket, key_hash, window_index, count, expires_at)
  SELECT $1::text, $2::bytea, w.idx, $4::bigint,
         to_timestamp(((w.idx + 1) * $3::bigint)::float8 / 1000) AT TIME ZONE 'UTC'
  FROM (SELECT floor(extract(epoch FROM clock_timestamp()) * 1000 / $3::bigint)::bigint AS idx) AS w
  ON CONFLICT (bucket, key_hash, window_index) DO UPDATE SET count = c.count + EXCLUDED.count
  RETURNING c.count,
            greatest(0, ceil(extract(epoch FROM c.expires_at - (clock_timestamp() AT TIME ZONE 'UTC')) * 1000))::bigint
  """

  @doc """
  Charges `cost` against `key` in `bucket`, a fixed window of `scale` ms that
  admits `limit` per window.

  `{:allow, count}` while the window's count is within `limit`, else
  `{:deny, retry_after_ms}` — the time left in the window. Every call is
  charged, including refused ones, exactly as Hammer's fixed window does.

  Windows are epoch-aligned, by the database's clock: a 15-minute window closes
  on the quarter hour, not fifteen minutes after the first attempt.

  Raises `ArgumentError` inside a transaction — see the moduledoc.
  """
  @spec hit(String.t(), String.t(), pos_integer(), pos_integer(), pos_integer()) ::
          {:allow, pos_integer()} | {:deny, non_neg_integer()}
  def hit(bucket, key, scale, limit, cost \\ 1)
      when is_binary(bucket) and is_binary(key) and is_integer(scale) and is_integer(limit) and
             is_integer(cost) do
    refuse_in_transaction!(bucket)
    hash = key_hash(key)

    case shared_hit(bucket, hash, scale, cost) do
      {:ok, count, retry_after_ms} -> verdict(count, limit, retry_after_ms)
      {:unavailable, reason} -> local_hit(bucket, hash, scale, limit, cost, reason)
    end
  end

  # `hit/5`'s upsert for a counter that is a tally rather than a budget
  # (`count/3`): it also returns the window index, and keeps the row `$4` ms
  # past the window's end so a reader that comes after the window closed (a
  # summary sent a minute later) still finds the total.
  @count_sql """
  INSERT INTO throttle_counters AS c (bucket, key_hash, window_index, count, expires_at)
  SELECT $1::text, $2::bytea, w.idx, 1,
         to_timestamp((((w.idx + 1) * $3::bigint) + $4::bigint)::float8 / 1000) AT TIME ZONE 'UTC'
  FROM (SELECT floor(extract(epoch FROM clock_timestamp()) * 1000 / $3::bigint)::bigint AS idx) AS w
  ON CONFLICT (bucket, key_hash, window_index) DO UPDATE SET count = c.count + 1
  RETURNING c.count, c.window_index
  """

  # How long a `count/3` row outlives its window. The security-alert summary
  # (#2245) reads a closed window's total a minute or so after it closes, and
  # the prune runs every five minutes: without the grace a window could be
  # deleted between closing and being summarized.
  @count_grace :timer.hours(1)

  @doc """
  Adds one to `key`'s **current** window in `bucket` (a fixed window of
  `scale` ms, by the database clock, as `hit/5`) and returns
  `{count, window_index}`: the window's total so far, and which window it is.

  A tally, not a gate: it never refuses, so it has no limit. The caller
  decides what a count means — the failed-sign-in alert (#2245) fires once,
  on the call that brings the total to its threshold, and reads the window's
  final total later with `window_count/3`. So the row is kept an hour past
  the window's end rather than pruned the moment the window closes.

  Raises `ArgumentError` inside a transaction, as `hit/5` does: a rollback
  would refund the count. When the database cannot answer, it counts on this
  node's fallback (the index then comes from this node's clock).
  """
  @spec count(String.t(), String.t(), pos_integer()) :: {pos_integer(), integer()}
  def count(bucket, key, scale)
      when is_binary(bucket) and is_binary(key) and is_integer(scale) and scale > 0 do
    refuse_in_transaction!(bucket)
    hash = key_hash(key)

    case shared(fn ->
           Repo.query!(@count_sql, [bucket, hash, scale, @count_grace], timeout: @timeout)
         end) do
      {:ok, %{rows: [[count, window_index]]}} ->
        {count, window_index}

      {:unavailable, reason} ->
        log_fallback(bucket, reason)
        # A limit no tally reaches: the fallback is only counting.
        {:allow, count} = Local.hit({bucket, hash}, scale, 1_000_000_000)
        {count, div(System.system_time(:millisecond), scale)}
    end
  end

  @window_count_sql """
  SELECT c.count FROM throttle_counters AS c
  WHERE c.bucket = $1 AND c.key_hash = $2 AND c.window_index = $3
  """

  @doc """
  The total `count/3` reached in window `window_index` of `key` in `bucket`,
  current or closed. `nil` when there is no such row (pruned, or never
  counted on the shared store) or the database cannot answer: the caller
  cannot tell those apart from "nothing happened", so it must not read `nil`
  as zero.
  """
  @spec window_count(String.t(), String.t(), integer()) :: non_neg_integer() | nil
  def window_count(bucket, key, window_index)
      when is_binary(bucket) and is_binary(key) and is_integer(window_index) do
    hash = key_hash(key)

    case shared(fn ->
           Repo.query!(@window_count_sql, [bucket, hash, window_index], timeout: @timeout)
         end) do
      {:ok, %{rows: [[count]]}} -> count
      {:ok, %{rows: []}} -> nil
      {:unavailable, _reason} -> nil
    end
  end

  @peek_sql """
  SELECT c.count FROM throttle_counters AS c
  WHERE c.bucket = $1 AND c.key_hash = $2
    AND c.window_index = floor(extract(epoch FROM clock_timestamp()) * 1000 / $3::bigint)::bigint
  """

  @doc """
  How much of `key`'s budget in `bucket` the **current** window has spent,
  charging nothing (#2249).

  For a decision that must not cost the thing it is deciding about: the
  human-verification gate (`KilnCMS.Challenge.Gate`) asks whether an address's
  sign-in attempts have reached the point where a challenge is required, and
  answering that with `hit/5` would spend a unit of the very budget a refused
  attempt must not spend.

  It is a read, so it is not a gate: a burst can all read the same count. That
  is acceptable for what it is used for, which is choosing whether to *ask* for
  a challenge, never whether to admit — `hit/5` stays the only gate, and every
  attempt the challenge admits still pays it.

  The window is computed from the database clock with the same arithmetic
  `hit/5` uses, so the two agree on which row is current. When the database
  cannot answer, the node-local fallback is read instead (the bound `hit/5`
  would be counting against meanwhile); when that has nothing either, `0` —
  which leans toward *not* asking for a challenge, the direction that cannot
  lock anyone out. Allowed inside a transaction: a read refunds nothing.
  """
  @spec peek(String.t(), String.t(), pos_integer()) :: non_neg_integer()
  def peek(bucket, key, scale)
      when is_binary(bucket) and is_binary(key) and is_integer(scale) and scale > 0 do
    hash = key_hash(key)

    case shared(fn -> Repo.query!(@peek_sql, [bucket, hash, scale], timeout: @timeout) end) do
      {:ok, %{rows: [[count]]}} -> count
      {:ok, %{rows: []}} -> 0
      {:unavailable, _reason} -> local_peek(bucket, hash, scale)
    end
  end

  @refund_sql """
  UPDATE throttle_counters AS c SET count = greatest(c.count - 1, 0)
  WHERE c.bucket = $1 AND c.key_hash = $2
    AND c.window_index = floor(extract(epoch FROM clock_timestamp()) * 1000 / $3::bigint)::bigint
  """

  @doc """
  Hands one unit of `key`'s **current** window in `bucket` back, never below
  zero (#2249).

  For a counter whose units are reserved up front by `hit/5` and released when
  the thing they were reserved for turns out not to count — the
  human-verification gate reserves a "free" sign-in per client address before
  the password is checked, and a sign-in that succeeds gives it back, so an
  office behind one address is not challenged for its own successful sign-ins.
  A window that has rolled since is left alone: there is nothing in it to give
  back. Best-effort on the node-local fallback, which has no decrement.
  """
  @spec refund(String.t(), String.t(), pos_integer()) :: :ok
  def refund(bucket, key, scale)
      when is_binary(bucket) and is_binary(key) and is_integer(scale) and scale > 0 do
    hash = key_hash(key)
    shared(fn -> Repo.query!(@refund_sql, [bucket, hash, scale], timeout: @timeout) end)
    :ok
  end

  defp local_peek(bucket, hash, scale) do
    Local.get({bucket, hash}, scale)
  rescue
    # The fallback table does not exist until `Local` has started.
    ArgumentError -> 0
  end

  @doc """
  Clears every window of `key` in `bucket` — on this node's fallback too.

  Allowed inside a transaction: a forgiveness that rolls back with the success
  it followed is the right outcome.
  """
  @spec forget(String.t(), String.t()) :: :ok
  def forget(bucket, key) when is_binary(bucket) and is_binary(key) do
    hash = key_hash(key)

    shared(fn ->
      Repo.query!(
        "DELETE FROM throttle_counters WHERE bucket = $1 AND key_hash = $2",
        [bucket, hash],
        timeout: @timeout
      )
    end)

    :ets.match_delete(Local, {{{bucket, hash}, :_}, :_, :_})
    :ok
  rescue
    # The fallback table does not exist until `Local` has started.
    ArgumentError -> :ok
  end

  @doc """
  Clears every counter in `buckets`, shared and local. For a demo reset
  (`KilnCMS.Demo`), where one shared account means one shared budget any
  visitor can spend on purpose.
  """
  @spec forget_buckets([String.t()]) :: :ok
  def forget_buckets(buckets) when is_list(buckets) do
    shared(fn ->
      Repo.query!("DELETE FROM throttle_counters WHERE bucket = ANY($1)", [buckets],
        timeout: @timeout
      )
    end)

    Enum.each(buckets, &:ets.match_delete(Local, {{{&1, :_}, :_}, :_, :_}))
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Deletes every row past its `expires_at`: the window's end, or for a
  `count/3` tally an hour after it. Returns how many went.

  Run by `KilnCMS.Accounts.ThrottleCounter`'s scheduled `:prune` action; the
  node-local fallback is swept by Hammer's own cleaner.
  """
  @spec prune() :: non_neg_integer()
  def prune, do: prune(0, 0)

  defp prune(deleted, batches) when batches >= @prune_max_batches, do: deleted

  defp prune(deleted, batches) do
    %{num_rows: n} =
      Repo.query!(
        """
        DELETE FROM throttle_counters WHERE ctid = ANY(ARRAY(
          SELECT ctid FROM throttle_counters WHERE expires_at < (clock_timestamp() AT TIME ZONE 'UTC') LIMIT $1
        ))
        """,
        [@prune_batch]
      )

    if n < @prune_batch, do: deleted + n, else: prune(deleted + n, batches + 1)
  end

  @doc false
  # Test seam: how much of `key`'s budget has been charged in `bucket`, summed
  # over every window still in the table. Nothing in production reads a count —
  # `hit/5` is the only gate.
  @spec spent(String.t(), String.t()) :: non_neg_integer()
  def spent(bucket, key) do
    %{rows: [[sum]]} =
      Repo.query!(
        "SELECT coalesce(sum(count), 0)::bigint FROM throttle_counters WHERE bucket = $1 AND key_hash = $2",
        [bucket, key_hash(key)]
      )

    sum
  end

  @doc false
  # The digest a key is stored under. Exported for the tests that assert no
  # submitted string reaches the table in the clear.
  @spec key_hash(String.t()) :: <<_::256>>
  def key_hash(key), do: :crypto.hash(:sha256, key)

  defp refuse_in_transaction!(bucket) do
    if Repo.in_transaction?() do
      raise ArgumentError,
            "#{inspect(__MODULE__)}.hit/5 called inside a transaction (bucket #{inspect(bucket)}). " <>
              "A rollback would refund the charge, and a failed attempt is what rolls back. " <>
              "Charge from before_transaction, or before the action runs."
    end
  end

  defp shared_hit(bucket, hash, scale, cost) do
    case shared(fn -> Repo.query!(@hit_sql, [bucket, hash, scale, cost], timeout: @timeout) end) do
      {:ok, %{rows: [[count, retry_after_ms]]}} -> {:ok, count, retry_after_ms}
      {:unavailable, _reason} = unavailable -> unavailable
    end
  end

  # The only exceptions that mean "the store cannot answer": no connection, no
  # sandbox owner (tests), or Postgres refusing the statement — which includes
  # the table not existing yet during a rolling deploy.
  defp shared(fun) do
    {:ok, fun.()}
  rescue
    error in [DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error] ->
      {:unavailable, error}
  end

  defp local_hit(bucket, hash, scale, limit, cost, reason) do
    log_fallback(bucket, reason)

    case Local.hit({bucket, hash}, scale, limit, cost) do
      {:allow, count} -> {:allow, count}
      {:deny, retry_after_ms} -> {:deny, retry_after_ms}
    end
  end

  defp verdict(count, limit, _retry_after_ms) when count <= limit, do: {:allow, count}
  defp verdict(_count, _limit, retry_after_ms), do: {:deny, retry_after_ms}

  # Once a minute per node. The fallback's own table is the clock, so this needs
  # no process of its own.
  defp log_fallback(bucket, reason) do
    case Local.hit(:fallback_logged, :timer.minutes(1), 1) do
      {:allow, _count} ->
        Logger.error(
          "Auth throttle store unavailable (#{Exception.message(reason)}); " <>
            "counting #{inspect(bucket)} and every other shared budget on this node only " <>
            "until it answers, so each budget holds per node rather than across the cluster."
        )

      {:deny, _retry_after} ->
        :ok
    end
  end
end
