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

  ## Complementary suppression — what it does, and what it does NOT do

  Every classified arrival writes exactly one referrer hit alongside its view
  (`KilnCMSWeb.ViewTracking`'s private `record/4`), so these categories sum to
  the item's own view total, which both the dashboard and the export publish
  **exactly**, right next to them. When one category is naturally below the
  threshold, a second is suppressed too — the smallest of the others, zero-hit
  ones included.

  > #### This does not prevent arithmetic recovery {: .warning}
  >
  > It reads as though it does, and #620 shipped it saying so. It does not.
  > Brute-forcing every assignment consistent with the published projection
  > *plus the published view total* (threshold 5):
  >
  > | breakdown | published | consistent assignments |
  > |---|---|---|
  > | `direct: 3`, rest zero | `"< 5"`, `hidden`, `0,0,0` | **1 — exact** |
  > | `direct: 2, search: 40, social: 50, other: 60` | `"< 5"`, `hidden`, `40,50,60` | **1 — exact** |
  > | `direct: 4`, others all `5` | `"< 5"`, `hidden`, `5,5,5` | **1 — exact** |
  > | `direct: 1, internal: 1`, rest zero | `"< 5"`, `"< 5"`, `0,0,0` | **1 — exact** |
  > | `direct: 4, internal: 100, …` | `"< 5"`, `hidden`, `200,300,400` | 4 — the range `"< 5"` already announced |
  >
  > The reader knows the algorithm. The partner is the *minimum* of the others,
  > so it is bounded above by every published exact; and it is not naturally
  > low, so it is `0` or `>= threshold`. With one equation and that constraint
  > the pair is usually unique — and whenever the residual is below the
  > threshold the partner **must** be zero, which pins the low value exactly.
  >
  > Choosing the smallest partner is what makes it predictable. Two
  > naturally-low categories are not safe either, contrary to what #620
  > claimed: small totals pin both.
  >
  > Closing this needs the exact total to stop being published beside the
  > breakdown, or the whole breakdown suppressed together — a design change to
  > both surfaces, tracked as #1073. What this function delivers today is a
  > **consistent** decision across the dashboard and the export, which is the
  > prerequisite for fixing it in one place rather than two.

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
    naturally_suppressed = for {source, hits} <- raw, hits > 0 and hits < threshold, do: source

    forced =
      case naturally_suppressed do
        [only] -> complementary_partner(raw, only)
        _other -> nil
      end

    Enum.map(raw, fn {source, hits} ->
      {source, hits, if(source == forced, do: "hidden", else: suppress_low_count(hits))}
    end)
  end

  defp complementary_partner(raw, already_suppressed) do
    {source, _hits} =
      raw
      |> Enum.reject(fn {source, _hits} -> source == already_suppressed end)
      |> Enum.min_by(fn {_source, hits} -> hits end)

    source
  end
end
