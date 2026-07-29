defmodule KilnCMS.Analytics do
  @moduledoc """
  Privacy-first content analytics.

  Records aggregate **view counts** per content item — no IP addresses, user
  agents, cookies or any other personal data, in keeping with the project's
  privacy-first goal. Backed by a single upserting counter row per content item
  (`KilnCMS.Analytics.ContentView`) plus a per-day bucket
  (`KilnCMS.Analytics.ContentViewDay`) that gives the dashboard its 7d/30d
  trends. The two are written independently and buckets expire on a retention
  window, so their sums diverge — the counter stays the source of truth for
  all-time totals.

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

    resource KilnCMS.Analytics.SearchQuery do
      define :record_search, action: :record
      define :top_searches, action: :top
      define :zero_result_searches, action: :zero_result
    end
  end
end
