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

      KilnCMS.OrgSettings.resolve(org_id,
        cache_key: KilnCMS.Cache.branding_key(org_id),
        ttl: @ttl,
        read: &KilnCMS.CMS.list_site_branding(tenant: &1, authorize?: false),
        build: &build/1,
        fallback: &defaults/0,
        label: "branding"
      )

  `read` is the code-interface list for the resource, called with the org id;
  it returns `{:ok, rows}` or `{:error, _}` (or raises). `build` receives the
  row or `nil`. `label` names the setting in the degrade log line.
  """

  require Logger

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

  # A system read: the row is read tenant-scoped with no actor, because the
  # layout renders for anonymous visitors and skipping the authorizer keeps the
  # cache-miss path cheap. Returns the row, `nil` when the site has none, or
  # `:error` on an infrastructure failure (which must NOT be cached).
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
