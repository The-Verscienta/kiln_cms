defmodule KilnCMS.Seo.Budget do
  @moduledoc """
  Rate limiting for LLM drafting — the only shared state the feature adds.

  Two buckets, both of which must pass:

    * **per user** — stops a stuck button or a replayed event from looping;
    * **per org** — the actual spend ceiling, since a hosted provider bills
      per call and one enthusiastic editor shouldn't be able to run it up.

  Same Hammer/ETS idiom as `KilnCMSWeb.RateLimit` and `KilnCMS.Mail.RelayAlert`.

  Note there is deliberately **no draft cache**. The `KilnCMS.Cache.fetch/3`
  memoization used elsewhere suits pure functions of a stable key; a draft is
  per-document, per-revision and per-org, and a key loose enough to ever hit
  would be a cross-tenant leak.
  """
  use Hammer, backend: :ets

  @doc """
  Whether a draft may run now.

  `nil` for either id skips that bucket, so callers without a request context
  (a mix task, a test) aren't blocked by a limiter that can't identify them.
  """
  @spec check(org_id :: term(), user_id :: term()) ::
          :ok | {:error, {:rate_limited, non_neg_integer()}}
  def check(org_id, user_id) do
    with :ok <- bucket("user", user_id, limit(:per_user_limit, {20, :timer.minutes(1)})) do
      bucket("org", org_id, limit(:per_org_limit, {200, :timer.hours(1)}))
    end
  end

  defp bucket(_kind, nil, _limit), do: :ok

  defp bucket(kind, id, {count, window_ms}) do
    case hit("seo:#{kind}:#{id}", window_ms, count) do
      {:allow, _count} -> :ok
      {:deny, retry_after_ms} -> {:error, {:rate_limited, retry_after_ms}}
    end
  end

  defp limit(key, default) do
    :kiln_cms |> Application.get_env(KilnCMS.Seo, []) |> Keyword.get(key, default)
  end
end
