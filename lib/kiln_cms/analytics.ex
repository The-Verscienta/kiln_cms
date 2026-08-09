defmodule KilnCMS.Analytics do
  @moduledoc """
  Privacy-first content analytics.

  Records aggregate **view counts** and, optionally, **coarse referrer
  categories** per content item — no IP addresses, user agents, cookies,
  raw referrer URLs, or any other personal data, in keeping with the
  project's privacy-first goal. Backed by a single upserting counter row per
  content item (`KilnCMS.Analytics.ContentView`), a per-day bucket
  (`KilnCMS.Analytics.ContentViewDay`) that gives the dashboard its 7d/30d
  trends, and a per-day, per-source bucket (`KilnCMS.Analytics.ReferrerDay`,
  off by default — see `referrers_enabled?/0`) for "where did readers come
  from". All three are written independently and buckets expire on a
  retention window, so their sums diverge — the `ContentView` counter stays
  the source of truth for all-time totals.

  Views are recorded by `KilnCMSWeb.ViewTracking` from both delivery surfaces —
  the rendered site and the headless `/api/content` artifact fetch — so a
  decoupled front end still reports traffic. Read its docs before comparing the
  two: a headless count is an artifact *fetch*, which a caching front end makes
  a floor rather than a census.

  Each recorded view also emits a `[:kiln_cms, :analytics, :view]` telemetry
  event so external sinks (Prometheus, OTLP) can observe view traffic; see
  `docs/observability.md`.

  `KilnCMS.Analytics.Funnel`/`FunnelStep` (#621) are the exception to all of
  the above: admin-authored editorial *definitions*, not recorded traffic —
  the first writable resources in this domain. A funnel's step traffic is
  derived from `ContentViewDay` buckets at read time (#622), never stored.
  """
  use Ash.Domain, otp_app: :kiln_cms

  resources do
    resource KilnCMS.Analytics.ContentView do
      define :record_view, action: :record, args: [:content_type, :content_id]
      define :list_views, action: :top
    end

    resource KilnCMS.Analytics.ContentViewDay do
      define :record_view_day, action: :record, args: [:content_type, :content_id]
      define :views_since, action: :in_window, args: [:since]
    end

    resource KilnCMS.Analytics.ReferrerDay do
      define :record_referrer, action: :record, args: [:content_type, :content_id, :source]
      define :referrers_since, action: :in_window, args: [:since]
    end

    resource KilnCMS.Analytics.SearchQuery do
      define :record_search, action: :record
      define :top_searches, action: :top
      define :zero_result_searches, action: :zero_result
    end

    resource KilnCMS.Analytics.Funnel do
      define :list_funnels, action: :read
      define :get_funnel, action: :read, get_by: [:id]
      define :create_funnel, action: :create
      define :update_funnel, action: :update
      define :destroy_funnel, action: :destroy
    end

    resource KilnCMS.Analytics.FunnelStep do
      define :funnel_steps_for, action: :for_funnel, args: [:funnel_id]
      define :create_funnel_step, action: :create
      define :update_funnel_step, action: :update
      define :destroy_funnel_step, action: :destroy
    end
  end

  @doc """
  Whether referrer attribution (#619) is enabled — off by default. Read with
  `Application.get_env/3`, never `compile_env`, so an operator can flip
  `KILN_ANALYTICS_REFERRERS` without a rebuild (see `config/runtime.exs`);
  unlike `:view_analytics`'s `retention_days`, this is a plain operator
  switch, not a value baked into an AshOban `where` expression.
  """
  @spec referrers_enabled?() :: boolean()
  def referrers_enabled? do
    Application.get_env(:kiln_cms, :analytics_referrers, [])[:enabled] == true
  end

  @default_low_count_threshold 5

  @doc """
  The low-count suppression threshold (#620): a referrer category below this
  many hits renders — in the dashboard **and** the export — as `"< n"` rather
  than an exact number, because a `(content, source, day, hits: 1)` row can
  describe a single visitor's arrival (design doc, "Where 'aggregate' gets
  thin: low counts"). Runtime-readable like `referrers_enabled?/0`, so an
  operator can tighten or loosen it without a rebuild; defaults to 5.
  """
  @spec low_count_threshold() :: pos_integer()
  def low_count_threshold do
    Application.get_env(:kiln_cms, :analytics_referrers, [])[:low_count_threshold] ||
      @default_low_count_threshold
  end

  @doc """
  Formats a referrer hit count for display or export: the exact integer at or
  above `low_count_threshold/0`, or the string `"< n"` below it. The only
  sanctioned way to surface a referrer count — never read `hits` directly for
  anything a user or an export file will see.

  A true zero is never suppressed: an absent category describes no one — the
  privacy concern is a *small but real* count, not the lack of one.
  """
  @spec suppress_low_count(non_neg_integer()) :: non_neg_integer() | String.t()
  def suppress_low_count(0), do: 0

  def suppress_low_count(hits) do
    threshold = low_count_threshold()
    if hits < threshold, do: "< #{threshold}", else: hits
  end

  @doc """
  The referrer categories, in display order — read off `ReferrerDay`'s own
  `one_of` constraint rather than restated.

  A category list that lives in two places is a category list that will
  eventually disagree, and the failure is silent: a new source would simply
  never appear in a chart or an export, and the suppression arithmetic below
  would be computed over a set that no longer sums to the view total.
  """
  @spec referrer_sources() :: [atom()]
  def referrer_sources do
    KilnCMS.Analytics.ReferrerDay
    |> Ash.Resource.Info.attribute(:source)
    |> Map.fetch!(:constraints)
    |> Keyword.fetch!(:one_of)
  end

  @doc """
  Decide what a whole referrer breakdown may show, given `totals` — a map of
  `source => hits` for **one** content item over one span (#620, #777).

  Read the warning below before treating this as a privacy guarantee.

  Returns one `{source, hits, display}` per category in `referrer_sources/0`
  order, including categories with no hits: a zero-hit source still needs a
  place, or its absence reads as "we don't track this" rather than "nobody
  arrived this way" — and, more importantly, it is a candidate partner below.

  ## Complementary suppression, and the equation it has to defeat

  Every classified arrival writes exactly one referrer hit alongside its view
  (`KilnCMSWeb.ViewTracking`'s private `record/4`), so these categories sum to
  the item's own view total — which both the dashboard and the export publish
  **exactly**, right beside them. That equation is what suppression here has to
  survive, and #620's first version did not:

  > #### The version this replaced {: .warning}
  >
  > It suppressed one partner, chosen as the **smallest** of the other
  > categories. That is precisely what made the partner predictable: the
  > smallest is bounded above by every published exact, and it is not naturally
  > low, so it is `0` or at least the threshold. One equation plus those two
  > constraints usually pins the pair — and whenever the residual falls below
  > the threshold, the partner *must* be zero, which recovers the hidden count
  > exactly (#1073). Brute force found `direct: 3, rest zero` and
  > `direct: 2, search: 40, social: 50, other: 60` each admitting exactly one
  > consistent assignment.

  Two changes close it.

  **The partner is the largest of the others, not the smallest.** A partner
  chosen as the maximum is bounded *below* by every published exact and
  unbounded above, so the residual splits many ways instead of one. It costs
  the breakdown its biggest category, which is the price of the biggest hiding
  place.

  **When the split is still unique, the whole breakdown goes.** Some
  breakdowns have nowhere to hide — `direct: 3` with four genuine zeros is
  three views total, and no choice of partner makes three ambiguous. Those are
  published as five `"hidden"` values against a view total that can be split
  #{"C(T+4, 4)"} ways, and they are exactly the breakdowns with nothing worth
  reading in them anyway.

  `ambiguous?/3` decides which case this is by counting the assignments a
  reader who knows this algorithm could construct. Knowing the rule gains them
  nothing: a partial publication is only emitted when that count is at least
  two.

  > #### What this still does not do {: .neutral}
  >
  > It does not make a suppressed count unknowable — it makes it *not uniquely
  > determined*. A `"< n"` category still announces its own range, and where
  > the residual admits only the four values that range already published, the
  > breakdown is published as-is: nothing was learned that the label did not
  > already say.

  ## The three display values

    * an integer — the exact count, at or above the threshold (or a true zero,
      which describes nobody and is never suppressed)
    * `"< n"` — naturally below the threshold
    * `"hidden"` — suppressed as a complement. Deliberately *not* `"< n"`: its
      real value can be at or above the threshold, so that label would be false.
  """
  @spec suppress_referrer_group(%{optional(atom()) => non_neg_integer()}) ::
          [{atom(), non_neg_integer(), non_neg_integer() | String.t()}]
  def suppress_referrer_group(totals) do
    threshold = low_count_threshold()
    raw = Enum.map(referrer_sources(), fn source -> {source, Map.get(totals, source, 0)} end)
    natural = for {source, hits} <- raw, hits > 0 and hits < threshold, do: source

    cond do
      # Nothing is small, so nothing needs hiding and the equation reveals
      # nothing anyone could not already read off the chart.
      natural == [] ->
        Enum.map(raw, fn {source, hits} -> {source, hits, hits} end)

      ambiguous?(raw, natural ++ List.wrap(partner(raw, natural)), threshold) ->
        partial(raw, partner(raw, natural))

      # Nowhere to hide: every zero published is one unknown removed from an
      # equation that already has only one. The whole breakdown goes, zeros
      # included — a published `0` is not a courtesy here, it is a term.
      true ->
        Enum.map(raw, fn {source, hits} -> {source, hits, "hidden"} end)
    end
  end

  # The naturally-low ones by their own range, the partner as `"hidden"`,
  # everything else exactly.
  defp partial(raw, forced) do
    Enum.map(raw, fn {source, hits} ->
      display = if source == forced, do: "hidden", else: suppress_low_count(hits)
      {source, hits, display}
    end)
  end

  # The LARGEST of the categories that are not naturally low — see the
  # moduledoc. `nil` when every category is naturally low or zero, in which
  # case the naturally-low ones are the whole suppressed set.
  defp partner(raw, natural) do
    raw
    |> Enum.reject(fn {source, _hits} -> source in natural end)
    |> case do
      [] -> nil
      candidates -> candidates |> Enum.max_by(fn {_source, hits} -> hits end) |> elem(0)
    end
  end

  @doc """
  Whether more than one assignment of the suppressed categories is consistent
  with everything published beside them (#1073).

  Public so a test can brute-force against it rather than trusting the
  arithmetic below — which is the only way this claim has ever been checked
  honestly.

  What a reader knows, given they know the algorithm:

    * the view total, published exactly beside the breakdown, and the exact
      value of every category that is not suppressed
    * a `"< n"` category holds `1..n-1` — it says so
    * the `"hidden"` partner is the largest of the categories that are not
      naturally low, so it is at least every published exact, and being not
      naturally low it is `0` or at least the threshold

  Counted rather than reasoned about: the naturally-low categories range over
  a small interval each, so their sum is enumerable, and the partner is then
  determined. Saturating at two, because "more than one" is the whole question.
  """
  @spec ambiguous?([{atom(), non_neg_integer()}], [atom()], pos_integer()) :: boolean()
  def ambiguous?(raw, suppressed, threshold) do
    hidden = for {source, hits} <- raw, source in suppressed, do: hits
    published = for {source, hits} <- raw, source not in suppressed, do: hits
    residual = Enum.sum(hidden)

    low_count = Enum.count(hidden, &(&1 > 0 and &1 < threshold))
    floor = Enum.max([threshold | published])

    partner? = length(hidden) > low_count

    low_count
    |> sums(threshold - 1)
    |> Enum.reduce_while(0, fn {sum, ways}, total ->
      cond do
        not partner_fits?(partner?, residual - sum, floor) -> {:cont, total}
        total + ways >= 2 -> {:halt, 2}
        true -> {:cont, total + ways}
      end
    end)
    |> Kernel.>=(2)
  end

  # With no partner in the suppressed set the naturally-low values must sum to
  # the residual exactly; with one, it takes up the slack and must itself be a
  # value the algorithm could have produced.
  defp partner_fits?(false, slack, _floor), do: slack == 0
  defp partner_fits?(true, slack, floor), do: slack == 0 or slack >= floor

  # `{sum, ways}` for `count` parts each in `1..max`, by the obvious DP.
  # Bounded by `count <= length(referrer_sources())` and `max = threshold - 1`,
  # so this is a few thousand steps at the most generous threshold anyone would
  # set — and the whole thing is skipped when nothing is naturally low.
  defp sums(0, _max), do: [{0, 1}]

  defp sums(count, max) do
    2..count//1
    |> Enum.reduce(one_part(max), fn _n, acc -> add_part(acc, max) end)
    |> Enum.sort()
  end

  defp add_part(sums, max) do
    Enum.reduce(sums, %{}, fn {sum, ways}, next ->
      Enum.reduce(1..max//1, next, &Map.update(&2, sum + &1, ways, fn w -> w + ways end))
    end)
  end

  defp one_part(max), do: Map.new(1..max//1, &{&1, 1})
end
