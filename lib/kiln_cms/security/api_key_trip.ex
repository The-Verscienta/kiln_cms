defmodule KilnCMS.Security.ApiKeyTrip do
  @moduledoc """
  A verified API key over a rate limit, as an audit event and the platform's
  `api_key_rate_limited` alert (#2245). Called from the refusal branch of
  `KilnCMSWeb.Plugs.RateLimit` and `KilnCMSWeb.Plugs.GraphqlBatchLimit` for the
  buckets an API key reaches: `:api` (JSON:API, `/api/*`, `/api/feed`,
  `/mcp`), `:gql` (`/gql`, batches included), `:media_upload`,
  `:media_transform` and `:plugin_endpoint`. Every other bucket is ignored.

  ## Only a key this node has verified

  The rate limit runs before the key is authenticated, so at a refusal the
  bearer is only a string someone sent. Verifying it there would put a
  database read behind every refused request, and gating on it would let an
  attacker who changes the string every time read and write without bound. So
  nothing here reads, gates or samples on the presented string.

  Instead this module keeps a node-local cache of **a key used successfully on
  this node within the TTL** (5 minutes): `KilnCMSWeb.Plugs.ApiKeyAuth` and the
  `/mcp` pipeline (`KilnCMSWeb.Plugs.RememberApiKey`) call `remember/2` with
  the exact token the key strategy verified, and the actor it authenticated.
  An entry is the SHA-256 of that token and the key's id, and is written only
  when it verifies against the key the actor carries. A per-address, per-node
  limit can only trip after that many requests from the address were allowed
  on this node, so a real key that trips it has been seen here.

  At a refusal (`note/2`):

    1. The key is the actor's when one is already authenticated
       (`:media_upload` runs after `:api`), else the cache's entry for the
       presented token: one hash and one ETS read. A miss (a forged, unknown,
       revoked, expired or never-used key, or a JWT) emits `result:
       :unverified` and does nothing else: no database read, no write.
    2. One alert per **verified key id** and bucket per alert window, per
       node, in memory (`KilnCMSWeb.RateLimit`). A forged key from the same
       address uses up nothing, so it cannot silence the real key's alert.
    3. What passes is recorded off the request path. The key is reloaded
       first and must still be valid: a key revoked within the TTL records
       nothing. The event, `:api_key_rate_limited`, is sampled once per key
       and bucket per window across the cluster (`Recorder.record_sampled/2`),
       and raises the platform alert.

  The event is recorded in the key owner's site when the owner has exactly
  one active membership, otherwise in the default org (`owner_org_id/1`, the
  rule `KilnCMS.Accounts.ApiKeyReuse` uses), never in the site the request's
  Host names. It has no actor (the presenter is not known to be the owner);
  its target is the key.

  A false positive to know about: the limits are per address, so a legitimate
  key behind a NAT that someone else floods is refused, and alerts, too.

  `/ws/gql` cannot carry an API key (`KilnCMSWeb.BearerAuth` accepts only a
  JWT), so a trip there is never a verified-key trip.

  ## Telemetry

  `[:kiln_cms, :security, :api_key_trip]`, measurement `count: 1`, metadata
  `result: :unverified | :debounced | :noted` and `bucket`. Only a refusal
  that presented a credential emits it. No key, token, user or address is in
  the event.

  ## The cache

  A public named ETS table owned by this process, swept every minute. It
  holds at most 10,000 entries; a full table skips new ones (a node sees
  at most one entry per live key, so it fills only if that many keys are in
  use at once). `remember/2` writes only when the entry is absent or older
  than half the TTL, so an authenticated request costs one hash and one read.
  Nothing here raises into the request, and nothing logs a key or an address.
  """
  use GenServer

  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.ApiKey
  alias KilnCMS.Accounts.ApiKeyReuse
  alias KilnCMS.Security.Alerts
  alias KilnCMS.Security.Recorder
  alias KilnCMSWeb.Plugs.ApiKeyAuth
  alias KilnCMSWeb.RateLimit

  @table :kiln_cms_verified_api_keys
  @ttl_ms :timer.minutes(5)
  @max_entries 10_000
  @sweep_ms :timer.minutes(1)
  @buckets [:api, :gql, :media_upload, :media_transform, :plugin_endpoint]

  @doc "The rate-limit buckets a verified key's refusal is noted for."
  @spec buckets() :: [atom()]
  def buckets, do: @buckets

  @doc "How long a verified key is remembered on this node, in milliseconds."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: @ttl_ms

  @doc false
  def start_link(_arg), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Remember that `plaintext` authenticated `actor` on this node. A no-op unless
  the actor authenticated with an API key (`__metadata__.api_key`) and
  `plaintext` verifies against that key. Always `:ok`.
  """
  @spec remember(String.t() | nil, term()) :: :ok
  def remember(plaintext, %{__metadata__: %{using_api_key?: true, api_key: %ApiKey{} = key}})
      when is_binary(plaintext) do
    hash = :crypto.hash(:sha256, plaintext)
    key_id = key.id
    now = now_ms()

    case :ets.lookup(@table, hash) do
      [{^hash, ^key_id, at}] when now - at < div(@ttl_ms, 2) -> :ok
      _absent_stale_or_another -> if verifies?(plaintext, key), do: put(hash, key_id, now)
    end

    :ok
  rescue
    # The table is gone while its owner restarts: the request still serves.
    ArgumentError -> :ok
  end

  def remember(_plaintext, _actor), do: :ok

  @doc """
  Note a refusal on `bucket` of a request that may carry an API key. Records
  `:api_key_rate_limited` only for a key verified on this node (see the
  moduledoc). Always `:ok`.
  """
  @spec note(Plug.Conn.t(), atom()) :: :ok
  def note(%Plug.Conn{} = conn, bucket) when bucket in @buckets do
    case verified_key(conn) do
      {:ok, key_id} -> gate(conn, key_id, bucket)
      :unverified -> emit(:unverified, bucket)
      :none -> :ok
    end

    :ok
  rescue
    # The alert is secondary to the refusal it reports on, which must still
    # be sent; a failure here is logged without the key or the address.
    _error ->
      Logger.warning("ApiKeyTrip: could not note a rate-limited request; skipped")
      :ok
  end

  def note(_conn, _bucket), do: :ok

  @doc """
  The org an API key's platform event is recorded in: the owner's one active
  site, read as the owner (the self-only read admits it), else the default
  org. Several sites, none, or a read that fails: the default org. `key`
  needs its `:user` loaded. Never the site a request names.
  """
  @spec owner_org_id(ApiKey.t() | map()) :: Ash.UUID.t()
  def owner_org_id(%{user: %Accounts.User{id: user_id} = owner}) do
    case Accounts.list_memberships_for_user(user_id, actor: owner, authorize_with: :error) do
      {:ok, memberships} ->
        case Enum.filter(memberships, &(&1.status == :active)) do
          [only] -> only.organization_id
          _none_or_several -> Accounts.default_org_id()
        end

      {:error, _refused} ->
        Accounts.default_org_id()
    end
  end

  def owner_org_id(_key), do: Accounts.default_org_id()

  @doc false
  # Test seam: forget every key.
  def clear, do: :ets.delete_all_objects(@table) && :ok

  defp verified_key(conn) do
    case Ash.PlugHelpers.get_actor(conn) do
      %{__metadata__: %{using_api_key?: true, api_key: %ApiKey{id: key_id}}} ->
        {:ok, key_id}

      _no_key_actor ->
        presented(conn)
    end
  end

  defp presented(conn) do
    case ApiKeyAuth.presented_key(conn) do
      {:ok, plaintext} -> lookup(plaintext)
      :error -> if credential?(conn), do: :unverified, else: :none
    end
  end

  defp credential?(conn), do: Plug.Conn.get_req_header(conn, "authorization") != []

  defp lookup(plaintext) do
    hash = :crypto.hash(:sha256, plaintext)
    now = now_ms()

    case :ets.lookup(@table, hash) do
      [{^hash, key_id, at}] when now - at < @ttl_ms -> {:ok, key_id}
      _miss_or_expired -> :unverified
    end
  end

  # Keyed on the server-verified key id, never on what was presented.
  defp gate(conn, key_id, bucket) do
    case RateLimit.hit("security_key_trip:#{key_id}:#{bucket}", Alerts.window_ms(), 1) do
      {:allow, _count} ->
        emit(:noted, bucket)
        # Read here, in the request's process: only this map crosses into
        # the task, never the conn.
        dispatch(%{key_id: key_id, bucket: bucket, request: Recorder.request_context(conn)})

      {:deny, _retry_after} ->
        emit(:debounced, bucket)
    end
  end

  defp emit(result, bucket),
    do:
      :telemetry.execute([:kiln_cms, :security, :api_key_trip], %{count: 1}, %{
        result: result,
        bucket: bucket
      })

  # `:async_analytics` is off under test, where a detached task would run
  # outside the SQL sandbox connection. `start_child/2` is a call, so a
  # restarting supervisor exits the caller; this sits on the refusal path.
  defp dispatch(ctx) do
    if Application.get_env(:kiln_cms, :async_analytics, true) do
      Task.Supervisor.start_child(KilnCMS.TaskSupervisor, fn -> record(ctx) end)
    else
      record(ctx)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp record(%{key_id: key_id, bucket: bucket, request: request}) do
    # authorize?: false — no actor exists off the request path; the id is one
    # this node verified (`remember/2`), and only its own name is recorded.
    case Accounts.get_api_key(key_id, authorize?: false, load: [:user, :valid]) do
      {:ok, %ApiKey{valid: true} = key} ->
        Recorder.record_sampled(:api_key_rate_limited,
          tenant: owner_org_id(key),
          user: nil,
          target_type: "api_key",
          target_id: key.id,
          sample_key: "#{key.id}:#{bucket}",
          limit: 1,
          scale: Alerts.window_ms(),
          metadata: %{"name" => key.name, "bucket" => Atom.to_string(bucket)},
          request: request
        )

      _gone_revoked_or_expired ->
        :ok
    end
  end

  defp verifies?(plaintext, %ApiKey{id: key_id, api_key_hash: expected})
       when is_binary(expected) do
    case ApiKeyReuse.decode(plaintext) do
      {:ok, ^key_id, token} -> Plug.Crypto.secure_compare(:crypto.hash(:sha256, token), expected)
      _other -> false
    end
  end

  defp verifies?(_plaintext, _key), do: false

  defp put(hash, key_id, now) do
    if :ets.member(@table, hash) or :ets.info(@table, :size) < @max_entries,
      do: :ets.insert(@table, {hash, key_id, now})
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  @impl true
  def init(:ok) do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = now_ms() - @ttl_ms
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
end
