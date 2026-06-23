defmodule KilnCMS.Analytics do
  @moduledoc """
  Privacy-first content analytics.

  Records aggregate **view counts** per content item — no IP addresses, user
  agents, cookies or any other personal data, in keeping with the project's
  privacy-first goal. Backed by a single upserting counter row per content item
  (`KilnCMS.Analytics.ContentView`).
  """
  use Ash.Domain, otp_app: :kiln_cms

  resources do
    resource KilnCMS.Analytics.ContentView do
      define :record_view, action: :record, args: [:content_type, :content_id]
      define :list_views, action: :top
    end

    resource KilnCMS.Analytics.SearchQuery do
      define :record_search, action: :record
      define :top_searches, action: :top
      define :zero_result_searches, action: :zero_result
    end
  end
end
