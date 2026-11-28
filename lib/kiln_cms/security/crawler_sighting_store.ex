defmodule KilnCMS.Security.CrawlerSightingStore do
  @moduledoc """
  The shared store behind `KilnCMS.CrawlerVerification.listing_overdue?/3`
  (#2852): when the instance first saw a search-engine claim from a client
  outside the engine's published list, in
  `KilnCMS.Security.CrawlerSighting`'s Postgres table.

  ## One statement, and why it is raw SQL

  `record/3` is a single upsert that records a sighting and reads it back:

      INSERT ... ON CONFLICT (key_hash, engine)
        DO UPDATE SET expires_at = <now + ttl>
      RETURNING first_seen_at

  A live row keeps its `first_seen_at`, so a later question never moves a
  sighting; a lapsed row the prune has not reached yet starts again, as an
  entry idle past its TTL would. It goes through `KilnCMS.Repo.query/3`, as
  `KilnCMS.Accounts.ThrottleStore` does, for the same two reasons:

    * **The time comes from the database clock** (`clock_timestamp()`), so
      every node records the same first sighting, whatever its own clock.
    * **It is on the request path** of a 404, once per client per cache
      refresh (`CrawlerVerification`'s node-local cache absorbs the rest):
      one round trip, no changeset.

  ## Never inside a transaction

  A sighting recorded inside a transaction would vanish with its rollback, so
  `record/3` answers `{:unavailable, :in_transaction}` there rather than
  write. The caller treats that like any other unavailable store.

  ## When the database cannot answer

  `record/3` answers `{:unavailable, reason}`, and never raises, for no
  connection, no sandbox owner (tests), a timeout or Postgres refusing the
  statement (the table missing during a rolling deploy among them). What
  that means for the guard is the caller's policy, and so are the error log
  (at most once a minute per node), the telemetry event and the retry
  backoff that report and pace it: see `KilnCMS.CrawlerVerification`'s
  "List-only evidence". This module logs nothing itself, so the test seams
  that share `shared/1` stay quiet.
  """

  alias KilnCMS.Repo

  # Short: this runs on a 404's request path, and an unanswered store only
  # leaves a claim exempt.
  @timeout 1_000

  # A prune deletes in batches this size, capped per run; the next run takes
  # the rest.
  @prune_batch 10_000
  @prune_max_batches 100

  @record_sql """
  INSERT INTO crawler_sightings AS s (key_hash, engine, first_seen_at, expires_at)
  SELECT $1::bytea, $2::text, n.at, n.at + $3::bigint * interval '1 millisecond'
  FROM (SELECT clock_timestamp() AT TIME ZONE 'UTC' AS at) AS n
  ON CONFLICT (key_hash, engine) DO UPDATE SET
    first_seen_at = CASE WHEN s.expires_at < EXCLUDED.first_seen_at
                         THEN EXCLUDED.first_seen_at ELSE s.first_seen_at END,
    expires_at = EXCLUDED.expires_at
  RETURNING floor(extract(epoch FROM s.first_seen_at) * 1000)::bigint
  """

  @doc """
  Records that `engine`'s claim from client `key` was seen now, unless a live
  sighting exists, and answers the first sighting as `{:ok, unix_ms}` (wall
  clock, milliseconds). Moves the sighting's expiry to `ttl_ms` from now
  either way.

  `{:unavailable, reason}` when the database cannot answer or inside a
  transaction; never raises.
  """
  @spec record(String.t(), atom(), pos_integer()) :: {:ok, integer()} | {:unavailable, term()}
  def record(key, engine, ttl_ms)
      when is_binary(key) and is_atom(engine) and is_integer(ttl_ms) and ttl_ms > 0 do
    if Repo.in_transaction?(),
      do: {:unavailable, :in_transaction},
      else: shared_record(key_hash(key), Atom.to_string(engine), ttl_ms)
  end

  defp shared_record(hash, engine, ttl_ms) do
    case shared(fn -> Repo.query!(@record_sql, [hash, engine, ttl_ms], timeout: @timeout) end) do
      {:ok, %{rows: [[first_seen_ms]]}} -> {:ok, first_seen_ms}
      {:unavailable, _reason} = unavailable -> unavailable
    end
  end

  @doc """
  Deletes every sighting past its `expires_at`. Returns how many went.

  Run by `KilnCMS.Security.CrawlerSighting`'s scheduled `:prune` action.
  """
  @spec prune() :: non_neg_integer()
  def prune, do: prune(0, 0)

  defp prune(deleted, batches) when batches >= @prune_max_batches, do: deleted

  defp prune(deleted, batches) do
    %{num_rows: n} =
      Repo.query!(
        """
        DELETE FROM crawler_sightings WHERE ctid = ANY(ARRAY(
          SELECT ctid FROM crawler_sightings WHERE expires_at < (clock_timestamp() AT TIME ZONE 'UTC') LIMIT $1
        ))
        """,
        [@prune_batch]
      )

    if n < @prune_batch, do: deleted + n, else: prune(deleted + n, batches + 1)
  end

  @doc false
  # Test seam: date `engine`'s sighting of `key` at `first_seen_ms` (wall
  # clock), lapsing `ttl_ms` from now (a negative one: already lapsed),
  # replacing any sighting there is.
  @spec put(String.t(), atom(), integer(), integer()) :: :ok
  def put(key, engine, first_seen_ms, ttl_ms) do
    Repo.query!(
      """
      INSERT INTO crawler_sightings AS s (key_hash, engine, first_seen_at, expires_at)
      VALUES ($1::bytea, $2::text,
              'epoch'::timestamp + $3::bigint * interval '1 millisecond',
              (clock_timestamp() AT TIME ZONE 'UTC') + $4::bigint * interval '1 millisecond')
      ON CONFLICT (key_hash, engine) DO UPDATE SET
        first_seen_at = EXCLUDED.first_seen_at, expires_at = EXCLUDED.expires_at
      """,
      [key_hash(key), Atom.to_string(engine), first_seen_ms, ttl_ms]
    )

    :ok
  end

  @doc false
  # Test seam: `{first_seen_ms, ms_until_it_lapses}` for `engine`'s sighting
  # of `key`, or nil.
  @spec fetch(String.t(), atom()) :: {integer(), integer()} | nil
  def fetch(key, engine) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT floor(extract(epoch FROM first_seen_at) * 1000)::bigint,
               ceil(extract(epoch FROM expires_at - (clock_timestamp() AT TIME ZONE 'UTC')) * 1000)::bigint
        FROM crawler_sightings WHERE key_hash = $1 AND engine = $2
        """,
        [key_hash(key), Atom.to_string(engine)]
      )

    case rows do
      [[first_seen_ms, ttl_ms]] -> {first_seen_ms, ttl_ms}
      [] -> nil
    end
  end

  @doc false
  # Test seam: forget every engine's sighting of `key`. A no-op when the
  # database cannot answer (an `on_exit` callback has no sandbox owner).
  @spec forget(String.t()) :: :ok
  def forget(key) do
    shared(fn ->
      Repo.query!("DELETE FROM crawler_sightings WHERE key_hash = $1", [key_hash(key)],
        timeout: @timeout
      )
    end)

    :ok
  end

  @doc false
  # The digest a client key is stored under. Exported for the tests that
  # assert no address reaches the table in the clear.
  @spec key_hash(String.t()) :: <<_::256>>
  def key_hash(key), do: :crypto.hash(:sha256, key)

  # The exceptions that mean "the store cannot answer", as `ThrottleStore`'s:
  # no connection, no sandbox owner (tests), or Postgres refusing the
  # statement, which includes the table not existing yet.
  defp shared(fun) do
    {:ok, fun.()}
  rescue
    error in [DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error] ->
      {:unavailable, error}
  end
end
