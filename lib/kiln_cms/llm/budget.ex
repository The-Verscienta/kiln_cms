defmodule KilnCMS.LLM.Budget do
  @moduledoc """
  Rate limiting for LLM calls — the only shared state the AI features add.

  Two buckets per feature, both of which must pass:

    * **per user** — stops a stuck button or a replayed event from looping;
    * **per org** — the actual spend ceiling, since a hosted provider bills
      per call and one enthusiastic editor shouldn't be able to run it up.

  Same Hammer/ETS idiom as `KilnCMSWeb.RateLimit` and `KilnCMS.Mail.RelayAlert`.

  One Hammer table serves every feature, but buckets are namespaced by
  `feature` and each caller passes its **own** limits: metadata drafting
  (`KilnCMS.Seo`) is a handful of short strings per page, block assist
  (`KilnCMS.Assist`) is whole paragraphs, and a shared allowance would price
  both at whichever is wrong for it. The limits an operator writes under a
  feature's config key are the limits that feature gets.

  Note there is deliberately **no result cache**. The `KilnCMS.Cache.fetch/3`
  memoization used elsewhere suits pure functions of a stable key; a generation
  is per-document, per-revision and per-org, and a key loose enough to ever hit
  would be a cross-tenant leak.
  """
  use Hammer, backend: :ets

  @doc """
  Whether a call may run now.

  `nil` for either id skips that bucket, so callers without a request context
  (a mix task, a test) aren't blocked by a limiter that can't identify them.

  `limits` takes `:per_user` and `:per_org`, each a `{count, window_ms}` tuple.
  """
  @spec check(String.t(), org_id :: term(), user_id :: term(), keyword()) ::
          :ok | {:error, {:rate_limited, non_neg_integer()}}
  def check(feature, org_id, user_id, limits) do
    with :ok <- bucket(feature, "user", user_id, Keyword.fetch!(limits, :per_user)) do
      bucket(feature, "org", org_id, Keyword.fetch!(limits, :per_org))
    end
  end

  defp bucket(_feature, _kind, nil, _limit), do: :ok

  defp bucket(feature, kind, id, {count, window_ms}) do
    # `inspect/1`, not interpolation: callers hold an `Organization` struct as
    # often as an id (Ash takes the struct as a tenant), and a struct in an
    # interpolated key raises Protocol.UndefinedError from *outside* the
    # facade's rescue — turning a rate-limit check into a crashed request.
    # Distinct terms still produce distinct keys, which is all a bucket needs.
    key = if is_binary(id), do: id, else: inspect(id)

    case hit("#{feature}:#{kind}:#{key}", window_ms, count) do
      {:allow, _count} -> :ok
      {:deny, retry_after_ms} -> {:error, {:rate_limited, retry_after_ms}}
    end
  end
end
