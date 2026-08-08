defmodule KilnCMS.LLM.Budget do
  @moduledoc """
  Rate limiting for LLM calls — the only shared state the AI features add.

  Two buckets per feature, both of which must pass:

    * **per user** — stops a stuck button or a replayed event from looping;
    * **per org** — the actual spend ceiling, since a hosted provider bills
      per call and one enthusiastic editor shouldn't be able to run it up.

  ## Why unattended callers stop early (#943)

  Once #942 gave automation rules an LLM reaction, the per-org bucket was
  shared between a human clicking a button and a background rule nobody is
  watching. An admin creating `*.updated → suggest_metadata` on a busy day
  could exhaust the whole hourly allowance, and the first an editor knew of it
  was their own "Suggest with AI" returning a rate-limit error — caused by a
  rule they cannot see and have no permission to inspect, since
  `/editor/automation` is admin-only.

  So a caller passing `unattended?: true` may only proceed while the org has
  spent **less than `unattended_share` of its window**, counting every
  caller's spend. The remainder is a genuine reserve: at the default share of
  0.5 and a 200/hour limit, an interactive caller always has at least 100
  units available, at any moment in the window, no matter what automation did.

  A sub-bucket counting only unattended hits was the first shape of this, and
  it does not hold the property this issue is named for. With editors at 199 of
  200 and automation at 0, the sub-bucket has room and the background rule
  takes the last unit — which is precisely "an unattended one takes the last
  unit". Reading the *shared* counter is what closes that.

  The cost is that the read and the subsequent write are not one atomic
  operation, so simultaneous unattended calls can each see room and both
  proceed. The overshoot is bounded by how many run at once (Oban's queue
  concurrency), and the per-org bucket still caps the total either way.

  Same Hammer/ETS idiom as `KilnCMSWeb.RateLimit` and `KilnCMS.Mail.RelayAlert`.

  One Hammer table serves every feature, but buckets are namespaced by
  `feature` and each caller passes its **own** limits: metadata drafting
  (`KilnCMS.Seo`) is a handful of short strings per page, block assist
  (`KilnCMS.Assist`) is whole paragraphs, and a shared allowance would price
  both at whichever is wrong for it. The limits an operator writes under a
  feature's config key are the limits that feature gets — which is why
  `:unattended_share` is fetched, not defaulted: a feature that starts making
  unattended calls must choose its own reserve rather than inherit one.

  Note there is deliberately **no result cache**. The `KilnCMS.Cache.fetch/3`
  memoization used elsewhere suits pure functions of a stable key; a generation
  is per-document, per-revision and per-org, and a key loose enough to ever hit
  would be a cross-tenant leak.
  """
  use Hammer, backend: :ets

  require Logger

  @doc """
  Whether a call may run now.

  `nil` for either id skips that bucket, so callers without a request context
  (a mix task, a test) aren't blocked by a limiter that can't identify them.

  `limits` takes `:per_user` and `:per_org`, each a `{count, window_ms}` tuple,
  and optionally:

    * `:unattended?` — this call has nobody waiting on it (an automation
      reaction). Applies the reserve described above.
    * `:unattended_share` — the fraction of `:per_org` an unattended caller may
      let the org reach. **Required** when `:unattended?` is true.

  Returns `{:error, :unattended_disabled}` — not a rate limit — when the share
  leaves no room at all. That is a standing configuration decision, and
  reporting it as a retryable overload sends an operator to wait out a window
  that will never help.
  """
  @spec check(String.t(), org_id :: term(), user_id :: term(), keyword()) ::
          :ok | {:error, {:rate_limited, non_neg_integer()} | :unattended_disabled}
  def check(feature, org_id, user_id, limits) do
    with :ok <- bucket(feature, "user", user_id, Keyword.fetch!(limits, :per_user)),
         # BEFORE the org bucket, so a refused unattended call doesn't spend an
         # org unit on its way to being told no.
         :ok <- unattended(feature, org_id, limits) do
      bucket(feature, "org", org_id, Keyword.fetch!(limits, :per_org))
    end
  end

  @doc """
  The org spend at which unattended callers stop, for a `{count, window}`.

  Everything above it is the interactive reserve. Public so a test — and an
  operator reading the docs — can see the number the share produces rather
  than inferring it.

  A share that isn't a number in `0..1` yields `0`, which stops unattended
  calls, and says so in the log. `unattended_share: 50` (meaning percent) is
  the natural mistake, and the alternative — a `FunctionClauseError` raised
  inside the rate limiter — becomes an Oban retry storm in the one caller that
  has retries, which is the opposite of what that worker is built to do.
  """
  @spec unattended_ceiling({pos_integer(), pos_integer()}, term()) :: non_neg_integer()
  def unattended_ceiling({count, _window_ms}, share)
      when is_number(share) and share >= 0 and share <= 1 do
    # `Float.round/2` first: `90 * 0.7` is 62.99999999999999, and a bare floor
    # quietly hands back 62 where both the docs and the operator expect 63.
    # `* 1.0` because an integer share (`0` or `1`) leaves an integer product,
    # which `Float.round/2` refuses.
    count |> Kernel.*(share) |> Kernel.*(1.0) |> Float.round(6) |> floor()
  end

  def unattended_ceiling({_count, _window_ms}, share) do
    Logger.warning(
      "LLM budget `unattended_share` must be a number between 0 and 1, got " <>
        "#{inspect(share)}; treating it as 0, so unattended callers are refused. " <>
        "Note it is a fraction, not a percentage."
    )

    0
  end

  defp unattended(feature, org_id, limits) do
    if Keyword.get(limits, :unattended?, false) do
      per_org = Keyword.fetch!(limits, :per_org)
      share = Keyword.fetch!(limits, :unattended_share)

      reserve(feature, org_id, per_org, unattended_ceiling(per_org, share))
    else
      :ok
    end
  end

  # No org to read a counter for. The module's contract is that a caller it
  # can't identify is not blocked, and that has to hold before the ceiling is
  # consulted — otherwise a share of 0.0 would refuse the mix task the rule
  # exists to exempt.
  defp reserve(_feature, nil, _per_org, _ceiling), do: :ok

  defp reserve(_feature, _org_id, _per_org, 0), do: {:error, :unattended_disabled}

  defp reserve(feature, org_id, {_count, window_ms}, ceiling) do
    if spent(feature, "org", org_id, window_ms) >= ceiling do
      {:error, {:rate_limited, window_ms}}
    else
      :ok
    end
  end

  # Reads the same window `hit/3` writes — Hammer's fixed window is
  # `div(now, scale)`, so a `get/2` with the same scale sees the live count.
  defp spent(feature, kind, id, window_ms), do: get(bucket_key(feature, kind, id), window_ms)

  defp bucket(_feature, _kind, nil, _limit), do: :ok

  defp bucket(feature, kind, id, {count, window_ms}) do
    case hit(bucket_key(feature, kind, id), window_ms, count) do
      {:allow, _count} -> :ok
      {:deny, retry_after_ms} -> {:error, {:rate_limited, retry_after_ms}}
    end
  end

  # `inspect/1`, not interpolation: callers hold an `Organization` struct as
  # often as an id (Ash takes the struct as a tenant), and a struct in an
  # interpolated key raises Protocol.UndefinedError from *outside* the
  # facade's rescue — turning a rate-limit check into a crashed request.
  # Distinct terms still produce distinct keys, which is all a bucket needs.
  defp bucket_key(feature, kind, id) do
    key = if is_binary(id), do: id, else: inspect(id)

    "#{feature}:#{kind}:#{key}"
  end
end
