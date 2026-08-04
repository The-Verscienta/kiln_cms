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
end
