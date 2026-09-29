defmodule KilnCMS.OrgSettings do
  @moduledoc """
  The one cached, layered read for a per-org settings row (#1080).

  `KilnCMS.Branding`, `KilnCMS.CodeInjection` and `KilnCMS.Feeds` each sit on
  the public delivery hot path and each resolves "this site's row, with the
  operator config underneath" through the same shape: `Cache.fetch` on a
  per-org key, a system read of the one row, a `build/1` that folds the config
  in, and two rules that are easy to get wrong and were written three times:

    * **A `nil` is never cached.** `KilnCMS.Cache.fetch/3` declines to store
      one, so `resolve/2` returns `nil` only for an infrastructure failure —
      which then degrades to the caller's fallback for *one request* rather
      than for the whole TTL. "No row" is not `nil`: it is `build.(nil)`, the
      operator config, and that IS cached (most sites have no row, and caching
      the lookup itself would be a database hit per request forever).
    * **A read that raises degrades, it does not 500.** The table may not
      exist yet mid-rolling-deploy, or the pool may time out under load; every
      page renders through these, so the failure is logged and answered with
      the fallback.

  What that fallback *is* stays the caller's decision, and the point of #1077
  was that it is not always the operator config: `Feeds` degrades to
  summaries-only rather than to a config that might turn full-content on,
  because on the disclosure axis "the operator default" is the wrong
  direction to fail. `resolve/2` therefore takes `:fallback` as a function and
  makes no assumption about it — the shared code is the mechanism, not the
  policy.

  ## Usage

      actor = KilnCMS.OrgSettings.system(:branding)

      KilnCMS.OrgSettings.resolve(org_id,
        cache_key: KilnCMS.Cache.branding_key(org_id),
        ttl: @ttl,
        read:
          &KilnCMS.CMS.list_site_branding(
            tenant: &1,
            actor: actor,
            authorize_with: :error
          ),
        build: &build/1,
        fallback: &defaults/0,
        label: "branding"
      )

  `read` is the code-interface list for the resource, called with the org id;
  it returns `{:ok, rows}` or `{:error, _}` (or raises). `build` receives the
  row or `nil`. `label` names the setting in the degrade log line.

  ## Who the row is read as (#1659)

  The page renders for anonymous visitors, so there is no request actor to read
  the row as. Each resolver reads it as `system/1`, a `KilnCMS.SystemActor`
  that the resource admits for `read` (a `:public` row admits everyone; an
  `:admin` or `:editor` one names the system actor through `OrgSettings`'
  `system_actions:` option).

  Take the actor in the caller, before `resolve/2`, and close over it in
  `read`: a cache miss runs `read` on a Cachex courier process, where the
  `with_actor/2` test seam (process-local) does not reach.

  **With `authorize_with: :error`, always.** A refused read filters to "no
  row", and "no row" is `build.(nil)`, the operator config, which is *cached*
  for the whole TTL. For `Feeds` that is exactly the wider disclosure `:fallback`
  exists to avoid. A refusal that raises is an infrastructure failure instead:
  logged, not cached, and answered with the fallback.
  """

  require Logger

  # See `with_actor/2`.
  @actor_override {__MODULE__, :actor_override}

  @doc """
  The actor a per-org settings resolver reads its row as (#1659): a
  `KilnCMS.SystemActor` labelled with the resolver's `subsystem`.
  """
  @spec system(atom()) :: KilnCMS.SystemActor.t() | nil
  def system(subsystem) when is_atom(subsystem) do
    case Process.get(@actor_override, :unset) do
      :unset -> KilnCMS.SystemActor.new(subsystem)
      actor -> actor
    end
  end

  @doc false
  # Test seam (#1659): run `fun` with `system/1` answering `actor` in this
  # process, so a test can take the grant away and prove each resolver fails
  # CLOSED to its fallback instead of caching the operator config.
  # Process-local, and nothing on a request path calls it; code that could call
  # it could equally pass any actor it liked.
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

  @type opts :: [
          cache_key: term(),
          ttl: pos_integer(),
          read: (Ash.UUID.t() -> {:ok, [struct()]} | {:error, term()}),
          build: (struct() | nil -> term()),
          fallback: (-> term()),
          label: String.t()
        ]

  @doc """
  The resolved value for `org_id` — cached under `:cache_key` for `:ttl`, built
  by `:build` from the row (or `nil` when the site has none), or `:fallback`
  (uncached) when the row could not be read.
  """
  @spec resolve(Ash.UUID.t(), opts()) :: term()
  def resolve(org_id, opts) when is_binary(org_id) do
    cache_key = Keyword.fetch!(opts, :cache_key)
    ttl = Keyword.fetch!(opts, :ttl)
    fallback = Keyword.fetch!(opts, :fallback)

    # `resolve_uncached/2` returns nil only on an infrastructure failure, which
    # the cache then declines to store — see the moduledoc.
    KilnCMS.Cache.fetch(cache_key, ttl, fn -> resolve_uncached(org_id, opts) end) || fallback.()
  end

  @doc """
  The uncached half: `build.(row_or_nil)`, or `nil` when the read failed. Public
  so a caller with its own cache shape (a second key, a different TTL) can still
  share the read-and-degrade rule.
  """
  @spec resolve_uncached(Ash.UUID.t(), opts()) :: term() | nil
  def resolve_uncached(org_id, opts) when is_binary(org_id) do
    build = Keyword.fetch!(opts, :build)

    case row(org_id, opts) do
      :error -> nil
      row -> build.(row)
    end
  end

  # A system read, tenant-scoped, as the caller's `read` function spells it
  # (see "Who the row is read as"). Returns the row, `nil` when the site has
  # none, or `:error` on an infrastructure failure or a refusal (which must NOT
  # be cached).
  defp row(org_id, opts) do
    read = Keyword.fetch!(opts, :read)

    case read.(org_id) do
      {:ok, [row | _rest]} -> row
      {:ok, []} -> nil
      {:error, reason} -> degrade(opts, inspect(reason))
      other -> degrade(opts, inspect(other))
    end
  rescue
    error -> degrade(opts, Exception.message(error))
  end

  defp degrade(opts, detail) do
    label = Keyword.get(opts, :label, "settings")

    Logger.warning("#{label} lookup failed, serving the fallback for this request: #{detail}")

    :error
  end
end
