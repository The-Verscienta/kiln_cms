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
end
