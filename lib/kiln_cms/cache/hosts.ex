defmodule KilnCMS.Cache.Hosts do
  @moduledoc """
  The host → organization resolution cache (#659), separate from the content
  cache on purpose, and the only cache that remembers a **miss**.

  ## Why it is not the content cache

  Two reasons, and the second is what #659 is about.

  Tenant resolution used to live in `KilnCMS.Cache` alongside published records.
  That cache is cleared wholesale by `KilnCMS.Cache.bust_published/0`, which
  runs whenever anyone saves a media item (`CMS.Changes.BustMediaCache`) — so an
  editor on one site cleared every *other* site's host resolution, and the next
  request for each of them paid a fresh lookup. Tenant hosts change when an
  organization's slug or `custom_domain` changes, which has nothing to do with
  publishing, so they belong on their own eviction schedule.

  It also means unresolvable hosts can be cached at all. In the shared cache
  they could not: a flood of made-up `Host` headers would insert an entry each
  and evict hot published pages, so `nil` was deliberately never committed and
  every unknown host cost a database round trip, for ever, unmetered — the
  refusal path halts in the endpoint above every rate limiter. Here a flood
  evicts only other host entries, which is a bounded, self-repairing cost
  instead of a cross-cutting one.

  ## What a negative entry costs

  An organization created (or given a `custom_domain`) within a minute of
  someone probing that exact host resolves late, by up to that long. That is the same class of staleness the positive
  side already has at five minutes, and an order of magnitude shorter, so the
  negative TTL is deliberately the tighter of the two.

  What it does **not** do is refuse anything the database would have resolved:
  an entry is only ever written from a real lookup that really found nothing.
  That distinguishes it from bounding the work by rate limit, which cannot tell
  a flood from a legitimate request behind the same address and so can refuse
  hosts that do exist.
  """

  # Hosts a deployment serves are few; hosts an attacker can invent are not. Big
  # enough that real traffic never evicts itself, small enough that a flood of
  # negatives is a bounded amount of memory.
  import Cachex.Spec, only: [hook: 1]

  @max_entries 5_000

  # A resolution holds for five minutes, as it did in the content cache: long
  # enough to matter under load, short enough that a slug or custom-domain
  # change takes effect without an operator doing anything.
  @positive_ttl :timer.minutes(5)

  # A miss holds for one, so a newly-configured host starts working promptly.
  @negative_ttl :timer.minutes(1)

  @cache :kiln_cms_host_cache

  # Cachex uses `nil` for "not present", so a cached miss needs a value of its
  # own to be distinguishable from one.
  @miss :unresolved

  @doc "The cache's registered name, for tests and observability."
  def cache_name, do: @cache

  @doc """
  Supervisor child spec, bounded to `#{@max_entries}` entries by the same
  evented least-recently-written policy the content cache uses.
  """
  def child_spec(_arg) do
    Supervisor.child_spec(
      {Cachex,
       name: @cache,
       hooks: [hook(module: Cachex.Limit.Evented, args: {@max_entries, [reclaim: 0.1]})]},
      id: __MODULE__
    )
  end

  @doc """
  The organization for `host`, resolving with `fun` on a miss and caching the
  answer — including a `nil`.

  Falls straight through to `fun` when caching is disabled, so a deployment that
  turns the cache off gets more queries and never a different answer.
  """
  @spec fetch(String.t(), (-> struct() | nil | :error)) :: struct() | nil | :error
  def fetch(host, fun) when is_binary(host) and is_function(fun, 0) do
    if enabled?(), do: fetch_cached(host, fun), else: fun.()
  end

  defp fetch_cached(host, fun) do
    case Cachex.get(@cache, host) do
      {:ok, nil} -> resolve_and_store(host, fun)
      {:ok, @miss} -> nil
      {:ok, org} -> org
      # A cache that is restarting must not take host resolution down with it.
      _error -> fun.()
    end
  end

  defp resolve_and_store(host, fun) do
    case fun.() do
      nil ->
        Cachex.put(@cache, host, @miss, expire: @negative_ttl)
        nil

      :error ->
        :error

      org ->
        Cachex.put(@cache, host, org, expire: @positive_ttl)
        org
    end
  end

  @doc "Drop every cached resolution. For tests, and for an operator's reset."
  @spec clear() :: :ok
  def clear do
    if enabled?(), do: Cachex.clear(@cache)
    :ok
  end

  # Same switch as the content cache, read the same way.
  defp enabled? do
    :kiln_cms |> Application.get_env(KilnCMS.Cache, []) |> Keyword.get(:enabled, true)
  end
end
