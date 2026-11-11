defmodule KilnCMS.Security.IpBlocklist do
  @moduledoc """
  Is this address blocked for this site? (#2242) — the matcher behind
  `KilnCMSWeb.Plugs.IpBlock` and the socket checks.

  ## The hot path

  `blocked?/2` runs on every dynamic request, so it is built to cost nothing when
  nothing is blocked:

    * loopback is answered `false` before anything else (and never matched);
    * a site's rules are read once and kept, parsed, in a cache of their own
      (`#{inspect(__MODULE__)}`, the shape of `KilnCMS.Cache.Hosts`, so a content
      bust cannot empty it and a flood of tenants cannot evict published pages),
      for a short named TTL (`ttl/0`);
    * a site with no rules caches an empty list and short-circuits on it;
    * expiry is judged at match time against the cached `expires_at`, so a rule
      stops matching on the second it lapses, not on the next refill.

  A rule written or removed through the resource busts the entry on every node
  (`bust/1`, via `KilnCMS.AfterCommit` and `KilnCMS.Cache.ClusterBust`). A row
  removed by hand in SQL (the documented recovery path) is picked up when the TTL
  runs out, which is why the TTL is a minute and not five.

  ## It fails open

  The list is read as `KilnCMS.SystemActor.new(:ip_block)` with
  `authorize_with: :error`: a refused read would otherwise come back as `{:ok,
  []}` and be cached as "no rules". Any failed read — database down, grant lost —
  lets the request through, logs a warning that carries no address, and is **never
  cached**, so the next request tries again. A block list that took the site down
  with the database would be worse than the abuse it answers.

  Callers are request edges, never a transaction: the fill is a plain read.
  """

  import Cachex.Spec, only: [hook: 1]

  alias KilnCMS.Cache.ClusterBust
  alias KilnCMS.CMS
  alias KilnCMS.Security.Cidr

  require Logger

  @cache :kiln_cms_ip_blocklist_cache
  @max_entries 5_000
  @ttl :timer.minutes(1)

  @doc "The cache's registered name, for tests and observability."
  def cache_name, do: @cache

  @doc "How long a site's compiled rules are trusted without a bust, in milliseconds."
  def ttl, do: @ttl

  @doc false
  def child_spec(_arg) do
    Supervisor.child_spec(
      {Cachex,
       name: @cache,
       hooks: [hook(module: Cachex.Limit.Evented, args: {@max_entries, [reclaim: 0.1]})]},
      id: __MODULE__
    )
  end

  @doc """
  Is `ip` (an address tuple) blocked for `org` (an organization or its id)?

  `false` for anything that is not an address, for loopback, and whenever the
  rules cannot be read.
  """
  @spec blocked?(struct() | Ash.UUID.t() | nil, term()) :: boolean()
  def blocked?(%{id: org_id}, ip), do: blocked?(org_id, ip)
  def blocked?(nil, _ip), do: false

  def blocked?(org_id, ip) when is_binary(org_id) and is_tuple(ip) do
    if Cidr.loopback?(ip) do
      false
    else
      case rules(org_id) do
        [] -> false
        rules -> any_match?(rules, ip, DateTime.utc_now())
      end
    end
  end

  def blocked?(_org, _ip), do: false

  defp any_match?(rules, ip, now) do
    Enum.any?(rules, fn {cidr, expires_at} ->
      (is_nil(expires_at) or DateTime.compare(expires_at, now) == :gt) and
        Cidr.contains?(cidr, ip)
    end)
  end

  @doc """
  Would a rule for `cidr` (text) block `client_ip`? The self-lockout check.

  `true` when `client_ip` is `nil`: an unknown address cannot be shown to be
  outside the rule. An unparseable `cidr` blocks nothing (the write is refused on
  its own account).
  """
  @spec would_block?(term(), :inet.ip_address() | nil) :: boolean()
  def would_block?(cidr, client_ip) do
    case Cidr.parse(cidr) do
      {:ok, parsed} -> is_nil(client_ip) or Cidr.contains?(parsed, client_ip)
      _invalid -> false
    end
  end

  @doc "Forget a site's cached rules, on this node and every other."
  @spec bust(Ash.UUID.t()) :: :ok
  def bust(org_id), do: ClusterBust.broadcast_in(@cache, [key(org_id)])

  @doc "Drop every cached entry on this node. For tests."
  @spec clear() :: :ok
  def clear do
    Cachex.clear(@cache)
    :ok
  end

  defp key(org_id), do: "rules:#{org_id}"

  # The parsed, still-unexpired-or-not rules for a site. `[]` on a failed read,
  # which is not stored.
  defp rules(org_id) do
    if enabled?() do
      case Cachex.get(@cache, key(org_id)) do
        {:ok, rules} when is_list(rules) -> rules
        _miss_or_cache_down -> fill(org_id)
      end
    else
      load(org_id) |> elem(1)
    end
  end

  defp fill(org_id) do
    case load(org_id) do
      {:ok, rules} ->
        Cachex.put(@cache, key(org_id), rules, expire: @ttl)
        rules

      {:error, rules} ->
        rules
    end
  end

  defp load(org_id) do
    actor = KilnCMS.SystemActor.resolve(:ip_block)

    case CMS.list_ip_block_rules(actor: actor, tenant: org_id, authorize_with: :error) do
      {:ok, records} ->
        {:ok, compile(records)}

      {:error, _error} ->
        # No address, no org, no error body: the log carries the fact only.
        Logger.warning("IpBlocklist: could not read the block rules; failing open")
        {:error, []}
    end
  end

  defp compile(records) do
    for %{cidr: text, expires_at: expires_at} <- records,
        {:ok, parsed} <- [Cidr.parse(text)],
        do: {parsed, expires_at}
  end

  defp enabled? do
    :kiln_cms |> Application.get_env(KilnCMS.Cache, []) |> Keyword.get(:enabled, true)
  end
end
