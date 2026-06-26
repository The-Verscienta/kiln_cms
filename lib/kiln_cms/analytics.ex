defmodule KilnCMS.Analytics do
  @moduledoc """
  Privacy-first content analytics.

  Records aggregate **view counts** per content item — no IP addresses, user
  agents, cookies or any other personal data, in keeping with the project's
  privacy-first goal. Backed by a single upserting counter row per content item
  (`KilnCMS.Analytics.ContentView`) plus a per-day bucket
  (`KilnCMS.Analytics.ContentViewDaily`) for 7d/30d trends. Each recorded view
  also emits a `[:kiln_cms, :analytics, :view]` telemetry event for external
  sinks (issue #45).
  """
  use Ash.Domain, otp_app: :kiln_cms

  resources do
    resource KilnCMS.Analytics.ContentView do
      define :record_view, action: :record, args: [:content_type, :content_id]
      define :list_views, action: :top
    end

    resource KilnCMS.Analytics.ContentViewDaily do
      define :record_daily_view, action: :record, args: [:content_type, :content_id, :day]
      define :views_since, action: :since, args: [:from]
    end

    resource KilnCMS.Analytics.SearchQuery do
      define :record_search, action: :record
      define :top_searches, action: :top
      define :zero_result_searches, action: :zero_result
    end
  end
end
