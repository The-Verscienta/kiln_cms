defmodule KilnCMSWeb.EventIndexController do
  @moduledoc """
  The JSON half of the occurrence-sorted delivery index (#766).

  `GET /<plural>/index.json` — event-shaped documents of one type, **soonest
  first**, windowed by `?from=`/`?until=` and paginated by `?page=`. The HTML
  half lives in `KilnCMSWeb.ContentController`, at `/<plural>`; the two read
  through `KilnCMSWeb.EventIndex` so they cannot answer differently.

  ## Why this exists when `/<plural>/feed.json` already does

  A feed is *newest published first*, which is the right order for syndication
  and the wrong one for a listing: a gig announced a year ago and happening
  tomorrow belongs at the top of "what's on" and at the bottom of a feed. The
  `.ics` routes sort by `published_at` too, and that is fine for them — a
  calendar client re-sorts by date itself — but an HTML or JSON index is
  consumed in the order it is served.

  ## What it may contain

  Published **and** `audience: :public`, one locale, unlocked — read actorless
  under `authorize?: true` so the passphrase policy (#496) applies too. The
  filter is `KilnCMS.Events.Index`'s own, written once and shared with the
  HTML index, and identical to `KilnCMSWeb.CalendarController`'s for the reason
  that controller gives at length: *published is not public*, and a delivery
  route that widens it is a leak rather than a listing.

  ## Not response-cached, deliberately

  The feeds and calendars are Cachex-backed because their URL set is closed. This
  route's is not: `from`, `until` and `page` are caller-chosen, so a cache key
  built from them is a way to mint unbounded entries in a shared cache one
  request at a time — the trap `CalendarController` avoids by making its tag
  scope a path segment resolved against real rows. The read is an index seek
  with a `LIMIT` instead, and the response carries a short `max-age` so a CDN
  absorbs the repeats.
  """
  use KilnCMSWeb, :controller

  alias KilnCMSWeb.EventIndex
  alias KilnCMSWeb.Tenant

  # Shorter than the feeds' five minutes: this document reorders as events
  # start, and it is cheap to regenerate.
  @max_age 60

  def index(conn, %{"plural" => plural} = params) do
    org = Tenant.current_org(conn)

    case EventIndex.type_for(org.id, plural) do
      # 404, never an empty document, for the reason the calendar 404s a type
      # with no schedule field: an index that will never have anything in it and
      # no way for a client to tell is worse than a miss.
      nil ->
        conn |> put_status(404) |> json(%{"error" => "not_found"})

      descriptor ->
        send_index(conn, org, descriptor, params)
    end
  end

  defp send_index(conn, org, descriptor, params) do
    {from, until} = EventIndex.window(params)
    page = EventIndex.page(params)
    locale = conn.assigns[:locale] || KilnCMS.I18n.default_locale()

    %{entries: entries, more?: more?} =
      EventIndex.fetch(descriptor, org,
        from: from,
        until: until,
        locale: locale,
        page: page
      )

    conn
    |> put_resp_header("cache-control", "public, max-age=#{@max_age}")
    |> put_resp_header("vary", "Accept-Language")
    |> json(%{
      "type" => to_string(descriptor.type),
      "title" => descriptor.label,
      "home_page_url" => Tenant.base_url(org) <> EventIndex.index_path(descriptor),
      "language" => locale,
      # The window that was actually applied, not the one that was asked for:
      # `from` is clamped to the index's anchor, and a client that echoes its own
      # request back has no way to know that happened.
      "from" => DateTime.to_iso8601(from),
      "until" => until && DateTime.to_iso8601(until),
      "page" => page + 1,
      "has_more" => more?,
      "events" => Enum.map(entries, &event/1)
    })
  end

  # `starts_at` is the *next* occurrence, which for a recurring document is one
  # of many — `recurring` says so rather than leaving a client to assume the
  # date it was given is the only one. `ends_at` is this occurrence's end, i.e.
  # the stored range's duration applied here, not the stored end instant.
  defp event(entry) do
    %{
      "id" => entry.id,
      "title" => entry.title,
      "url" => entry.url,
      "summary" => entry.summary,
      "starts_at" => DateTime.to_iso8601(entry.starts_at),
      "ends_at" => entry.ends_at && DateTime.to_iso8601(entry.ends_at),
      "all_day" => entry.all_day?,
      "time_zone" => entry.time_zone,
      "recurring" => entry.recurring?
    }
  end
end
