defmodule KilnCMSWeb.CalendarController do
  @moduledoc """
  iCalendar delivery for event-shaped content (#480).

  Three shapes: `/calendar.ics` across every event type, `/<plural>/calendar.ics`
  for one type, `/<plural>/tags/<tag>/calendar.ics` for one taxonomy term — and
  `/<plural>/<slug>/calendar.ics`, the single-document download an "Add to
  calendar" link points at.

  Shaped like `KilnCMSWeb.FeedController`, deliberately: same per-org scoping,
  same actor-less `authorize?: true` read, same explicit `audience: :public`
  filter, same short-TTL aggregate cache dropped by the existing publish hooks.

  ## Why the audience filter is here and not left to the policy

  **Published is not public.** An audience-gated record is published and
  paywalled, and a subscribed calendar is fetched by an anonymous client with no
  session, forever, on a timer. The filter is explicit for the reason the feeds'
  is: it is the difference between a calendar and a leak, and it must not depend
  on a read policy staying shaped the way it is today.

  ## Why the tag scope is a path segment resolved against real rows

  A cache key must not be reachable from arbitrary input, or a caller can mint
  unbounded entries in a shared Cachex by varying a query parameter. So the term
  is a path segment, it is resolved to an actual `Tag` first, and an unknown one
  404s before anything is cached.

  ## Every response is bounded

  A recurring event ships as an `RRULE` rather than expanded occurrences
  (`KilnCMS.Events.ICS` has the argument), so an infinite series is a handful of
  bytes. What is bounded here is the *document count*: a calendar carries at most
  `KilnCMS.Feeds.entry_limit/0` records, like a feed, because an org with 50,000
  archived events should not serve them all to an anonymous fetch.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Cache
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Events
  alias KilnCMS.Events.ICS
  alias KilnCMS.Feeds
  alias KilnCMSWeb.Tenant

  @cache_ttl :timer.minutes(5)

  # `type_definition_id` is not decoration: it is how a record resolves to the
  # field definitions that hold its schedule, and a select that omits it hands
  # `Events.scope_for/1` an `%Ash.NotLoaded{}` instead of an id.
  @base_fields [
    :id,
    :type_definition_id,
    :title,
    :slug,
    :path_alias,
    :locale,
    :seo_description,
    :custom_fields,
    :published_at,
    :inserted_at,
    :updated_at
  ]

  def index(conn, _params), do: send_calendar(conn, nil, nil)

  def type(conn, %{"plural" => plural}) do
    with_type(conn, plural, fn descriptor -> send_calendar(conn, descriptor, nil) end)
  end

  def tag(conn, %{"plural" => plural, "tag" => tag_slug}) do
    with_type(conn, plural, fn descriptor ->
      case tag_for(Tenant.current_org(conn).id, tag_slug) do
        nil -> not_found(conn)
        tag -> send_calendar(conn, descriptor, tag)
      end
    end)
  end

  @doc """
  One document's `.ics` — the "add to calendar" download.

  Not cached: it is one record's read, it carries a `Content-Disposition`
  filename derived from that record, and a per-document cache key on an
  anonymous route is a way to fill a shared cache one URL at a time.
  """
  def show(conn, %{"plural" => plural, "slug" => slug}) do
    org = Tenant.current_org(conn)

    with_type(conn, plural, fn descriptor ->
      case record_by_slug(descriptor, org, slug) do
        nil ->
          not_found(conn)

        record ->
          body = ICS.event(record, org_id: org.id, url_for: &url_for(&1, descriptor, org))

          conn
          |> put_resp_header(
            "content-disposition",
            ~s(attachment; filename="#{ICS.filename(record)}")
          )
          |> send_ics(body)
      end
    end)
  end

  # The content type is a compile-time literal, never a computed value: it is
  # what tells a client this is a calendar rather than a document to render (and
  # a variable here is a Sobelow `XSS.ContentType` finding for that reason).
  #
  # `body` is server-generated — `KilnCMS.Events.ICS` escapes every interpolated
  # value per RFC 5545 and strips the control characters the format cannot
  # represent — and it is not HTML, so `send_resp/3` carries no XSS sink.
  # sobelow_skip ["XSS.SendResp"]
  defp send_ics(conn, body) do
    conn
    |> put_resp_content_type("text/calendar")
    |> send_resp(200, body)
  end

  defp send_calendar(conn, descriptor, tag) do
    org = Tenant.current_org(conn)
    key = Cache.feed_key(org.id, cache_scope(descriptor, tag), :ics)

    body =
      Cache.fetch(key, @cache_ttl, fn ->
        types = if descriptor, do: [descriptor], else: Events.calendar_types(org.id)
        # Resolved once, not per record: `calendar_types/1` asks the database
        # which types carry a schedule field, and doing that inside the URL
        # builder would make a mixed calendar N type-lookups deep.
        by_scope = Map.new(types, &{Events.scope_for_descriptor(&1), &1})

        org
        |> records(types, tag)
        |> ICS.calendar(
          org_id: org.id,
          name: calendar_name(org, descriptor, tag),
          url_for: &url_for(&1, Map.get(by_scope, Events.scope_for(&1)), org)
        )
      end)

    send_ics(conn, body)
  end

  # Namespaced so a type's own calendar and a tag-scoped one can't collide, and
  # so `Cache.bust_feeds/2` — which drops `{org, type}` across every format —
  # still reaches the untagged key on publish.
  defp cache_scope(nil, nil), do: nil
  defp cache_scope(descriptor, nil), do: to_string(descriptor.type)
  defp cache_scope(descriptor, tag), do: "#{descriptor.type}/tag/#{tag.slug}"

  # ── lookups ───────────────────────────────────────────────────────────────

  # 404 rather than an empty calendar for a type that has no schedule field: an
  # empty VCALENDAR is a client silently subscribing to nothing forever.
  defp with_type(conn, plural, fun) do
    org = Tenant.current_org(conn)

    case find_type(org.id, plural) do
      nil -> not_found(conn)
      descriptor -> fun.(descriptor)
    end
  end

  defp find_type(org_id, plural) do
    org_id
    |> Events.calendar_types()
    |> Enum.find(&(&1.plural == plural or &1.path_segment == plural))
  end

  defp tag_for(org_id, slug) do
    case CMS.get_tag_by_slug(slug, authorize?: false, tenant: org_id) do
      {:ok, tag} -> tag
      _other -> nil
    end
  end

  defp not_found(conn), do: conn |> put_status(404) |> text("")

  # ── records ───────────────────────────────────────────────────────────────

  defp records(org, types, tag) do
    limit = Feeds.entry_limit()

    Enum.flat_map(types, &type_records(&1, org, tag, limit))
  end

  defp type_records(descriptor, org, tag, limit) do
    ContentTypes.list!(descriptor,
      authorize?: true,
      tenant: org.id,
      query: [
        # Published *and* public, one locale — the same three reasons the feeds
        # give. A calendar carrying every translation shows a subscriber the
        # same gig three times.
        filter: filter(tag),
        # Newest first, then capped. NOT "soonest occurrence first": the next
        # occurrence of a recurring event is a function of `now()`, so it is not
        # a column anything can sort on, and expanding every candidate to sort
        # in memory would mean reading the whole archive on an anonymous route.
        # Ordering inside a VCALENDAR is not significant anyway — a client sorts
        # by date itself (see #766 for the JSON index, where it does matter).
        sort: [published_at: :desc],
        limit: limit,
        select: @base_fields
      ]
    )
  end

  defp filter(nil),
    do: [audience: :public, locale: KilnCMS.I18n.default_locale()]

  defp filter(tag),
    do: [audience: :public, locale: KilnCMS.I18n.default_locale(), tags: [id: tag.id]]

  defp record_by_slug(descriptor, org, slug) do
    ContentTypes.list!(descriptor,
      authorize?: true,
      tenant: org.id,
      query: [
        filter: [slug: slug, audience: :public],
        limit: 1,
        select: @base_fields
      ]
    )
    |> List.first()
  end

  # ── urls ──────────────────────────────────────────────────────────────────

  # The site-wide calendar mixes types, so each record's URL is built against
  # *its own* descriptor rather than the one the route named — nil for a record
  # whose type isn't in the set, which only means no `URL` line for it.
  defp url_for(_record, nil, _org), do: nil

  defp url_for(record, descriptor, org) do
    Tenant.base_url(org) <> locale_prefix(record.locale) <> public_path(record, descriptor)
  end

  defp public_path(%{path_alias: alias_path}, _descriptor) when is_binary(alias_path),
    do: alias_path

  defp public_path(record, descriptor),
    do: "#{ContentTypes.public_prefix(descriptor)}/#{record.slug}"

  defp locale_prefix(locale) do
    if locale == KilnCMS.I18n.default_locale(), do: "", else: "/#{locale}"
  end

  defp calendar_name(org, nil, _tag), do: KilnCMS.Branding.for_org(org.id).site_name

  defp calendar_name(org, descriptor, nil),
    do: "#{KilnCMS.Branding.for_org(org.id).site_name} — #{descriptor.label}"

  defp calendar_name(org, descriptor, tag),
    do: "#{KilnCMS.Branding.for_org(org.id).site_name} — #{descriptor.label}: #{tag.name}"

  @doc """
  The path a calendar is served at — shared with the `<link>` tags so the
  advertised URL and the routed one cannot drift.
  """
  @spec calendar_path(map() | nil) :: String.t()
  def calendar_path(nil), do: "/calendar.ics"
  def calendar_path(descriptor), do: "#{calendar_prefix(descriptor)}/calendar.ics"

  @doc "The path a single document's `.ics` is served at."
  @spec document_calendar_path(map(), struct()) :: String.t()
  def document_calendar_path(descriptor, record),
    do: "#{calendar_prefix(descriptor)}/#{record.slug}/calendar.ics"

  # The type's public prefix where it has one, its plural otherwise — NOT
  # `public_prefix/1` unguarded, which returns "" for a type served at the root
  # and would put its calendar at `/calendar.ics`, the site-wide one's own URL.
  defp calendar_prefix(%{path_segment: segment}) when is_binary(segment) and segment != "",
    do: "/" <> segment

  defp calendar_prefix(%{plural: plural}), do: "/" <> plural
end
