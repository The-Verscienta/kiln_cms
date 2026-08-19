defmodule KilnCMSWeb.FederationController do
  @moduledoc """
  The public ActivityPub surface: WebFinger, the actor document, the outbox,
  the followers collection, and the inbox (#491).

  **Every route 404s when federation is off** — for the deployment or for the
  site. That is the `KilnCMSWeb.Plugs.ApiDocs` and billing-webhook posture: a
  404 is what any unrouted path answers, so an instance that does not federate
  is indistinguishable from one built without the feature. A 403 would confirm
  the route exists and is merely closed, which is the one bit of information a
  disabled endpoint should not volunteer.

  Responses are served with `send_resp/3` and an explicit
  `application/activity+json` content type rather than through `json/2`: the
  MIME type is not one Phoenix negotiates, and registering it would be a
  compile-time change to the `mime` application for a header this can just set.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Federation.Activity
  alias KilnCMS.Federation.Actor
  alias KilnCMS.Federation.Follower
  alias KilnCMS.Federation.Inbox
  alias KilnCMSWeb.Params
  alias KilnCMSWeb.Tenant

  require Logger

  # The outbox is a single page in phase 1. Bounded for the same reason the feed
  # is: a client that ignores paging should not be able to make a site serialize
  # its whole archive.
  @outbox_limit 40

  # Discovery documents change when an admin edits federation settings, which is
  # rare; content-derived ones change on publish. Both are safe for a shared
  # cache to hold briefly, and remote servers fetch them often.
  @discovery_max_age 3600
  @outbox_max_age 300

  # Everything the outbox reads. Deliberately narrow — see `select_fields/1`.
  @base_fields [:id, :title, :slug, :locale, :published_at, :inserted_at, :updated_at]

  @doc "`GET /.well-known/webfinger?resource=acct:<user>@<host>`"
  def webfinger(conn, params) do
    resource = Params.string(params, "resource", "")

    with {:ok, settings} <- site(conn),
         true <- Actor.matches_resource?(settings, resource) do
      send_jrd(conn, Actor.webfinger(settings), @discovery_max_age)
    else
      # An unknown resource is a 404 rather than an empty JRD: WebFinger's own
      # answer for "no such subject" is 404, and an empty document would be read
      # as a malformed record instead.
      _other -> not_found(conn)
    end
  end

  @doc "`GET /actor`"
  def actor(conn, _params) do
    case site(conn) do
      {:ok, settings} ->
        send_activity(conn, Actor.document(settings), @discovery_max_age)

      :error ->
        not_found(conn)
    end
  end

  @doc "`GET /actor/outbox`"
  def outbox(conn, _params) do
    case site(conn) do
      {:ok, settings} ->
        identity = Actor.identity(settings)

        activities =
          conn
          |> Tenant.current_org_id()
          |> recent_documents(identity)
          |> Enum.map(&Activity.create(&1, identity))

        send_activity(conn, Activity.outbox(activities, identity), @outbox_max_age)

      :error ->
        not_found(conn)
    end
  end

  @doc "`GET /actor/followers`"
  def followers(conn, _params) do
    case site(conn) do
      {:ok, settings} ->
        org_id = Tenant.current_org_id(conn)

        # `authorize?: false`: an ActivityPub fetch has no actor and `Follower`'s
        # read policy is editor-only. Only the tenant-scoped COUNT leaves here —
        # display data for the public collection, never a follower row.
        count = Follower |> Ash.count!(authorize?: false, tenant: org_id)

        send_activity(
          conn,
          Activity.followers_collection(count, Actor.identity(settings)),
          @outbox_max_age
        )

      :error ->
        not_found(conn)
    end
  end

  @doc """
  `GET /ap/object/:id` — the AS2 object for one document.

  Every activity this site delivers carries an object `id` under this path, and
  an id that does not dereference is a broken post on the receiving side:
  Mastodon re-resolves objects on refresh, on thread expansion, and to confirm
  a `Delete`.

  Only published, `:public`, default-locale content of a syndicated type —
  the same set the outbox serves, because an object that federated must stay
  resolvable and one that never did must not become resolvable here.
  """
  def object(conn, %{"id" => id}) do
    with {:ok, settings} <- site(conn),
         {:ok, document, descriptor} <- federated_document(conn, id) do
      identity = Actor.identity(settings)

      send_activity(
        conn,
        Map.put(
          Activity.object(document(document, descriptor, identity), identity),
          "@context",
          "https://www.w3.org/ns/activitystreams"
        ),
        @outbox_max_age
      )
    else
      _other -> not_found(conn)
    end
  end

  @doc """
  `POST /actor/inbox`

  202 for anything handled or deliberately ignored, 401 for a request whose
  signature does not check out. Never 5xx on a malformed activity — a remote
  server would retry it for days.
  """
  def inbox(conn, _params) do
    org_id = Tenant.current_org_id(conn)

    with {:ok, settings} <- site(conn),
         {:ok, raw_body} <- raw_body(conn),
         {:ok, activity} <- Jason.decode(raw_body),
         :ok <- Inbox.handle(settings, activity, conn.req_headers, raw_body, org_id) do
      send_resp(conn, 202, "")
    else
      :error ->
        not_found(conn)

      {:error, %Jason.DecodeError{}} ->
        send_resp(conn, 400, "")

      {:error, reason} ->
        Logger.info("Federation inbox refused a request: #{reason}")
        send_resp(conn, 401, "")
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp site(conn) do
    conn |> Tenant.current_org_id() |> Inbox.settings()
  end

  # Published, public, default-locale content of types that syndicate — the
  # same set `KilnCMS.Federation` delivers, so the outbox and the timeline agree.
  defp recent_documents(org_id, identity) do
    org_id
    |> KilnCMS.Feeds.syndicated_types()
    |> Enum.flat_map(&type_documents(&1, org_id, identity))
    |> Enum.sort_by(& &1.published_at, {:desc, DateTime})
    |> Enum.take(@outbox_limit)
  end

  defp type_documents(%{resource: nil}, _org_id, _identity), do: []

  defp type_documents(descriptor, org_id, identity) do
    descriptor
    |> KilnCMS.CMS.ContentTypes.list!(
      authorize?: true,
      tenant: org_id,
      query: [
        filter: [audience: :public, locale: KilnCMS.I18n.default_locale()],
        sort: [published_at: :desc],
        limit: @outbox_limit,
        # Without this every entry drags its whole `blocks` union tree and its
        # embedding vector into memory — on an anonymous route. Same reason
        # `FeedController` and `SitemapController` select.
        select: select_fields(descriptor)
      ]
    )
    |> Enum.map(&document(&1, descriptor, identity))
  end

  # Resolved by scanning the syndicated types rather than by a type hint in the
  # URL: the id is minted from the record id alone, deliberately, so that a slug
  # rename does not re-announce the article as a new one.
  defp federated_document(conn, id) do
    org_id = Tenant.current_org_id(conn)

    org_id
    |> KilnCMS.Feeds.syndicated_types()
    |> Enum.reject(&is_nil(&1.resource))
    |> Enum.find_value(:error, fn descriptor ->
      case Ash.get(descriptor.resource, id, authorize?: true, tenant: org_id) do
        {:ok, record} -> resolvable(record, descriptor)
        _other -> nil
      end
    end)
  end

  # `authorize?: true` with no actor already limits this to published content;
  # the audience and locale checks make it the same set the outbox serves.
  defp resolvable(record, descriptor) do
    if Map.get(record, :audience, :public) == :public and
         record.locale == KilnCMS.I18n.default_locale() do
      {:ok, record, descriptor}
    end
  end

  defp select_fields(%{excerpt?: true}), do: @base_fields ++ [:excerpt]
  defp select_fields(_descriptor), do: @base_fields

  # Built from the actor's **pinned** origin, exactly as `AnnounceWorker` does.
  # Using the site's current base URL here would make the outbox and the
  # delivered activities disagree the day a `custom_domain` is added — the very
  # drift pinning the origin exists to prevent.
  defp document(record, descriptor, identity) do
    prefix = KilnCMS.CMS.ContentTypes.public_prefix(descriptor)

    %{
      id: record.id,
      type: to_string(descriptor.type),
      title: record.title,
      url: identity.origin <> "#{prefix}/#{record.slug}",
      summary: Map.get(record, :excerpt),
      published_at: record.published_at || record.inserted_at,
      updated_at: record.updated_at
    }
  end

  # Stashed by `KilnCMSWeb.Plugs.RawBodyReader` in `conn.private`. It must be the
  # exact bytes: the `Digest` header covers them, and a re-encoded parse differs
  # in key order, whitespace and unicode escaping.
  defp raw_body(conn) do
    case conn.private[:raw_body] do
      body when is_binary(body) -> {:ok, body}
      _other -> {:error, "request body was not captured for signature verification"}
    end
  end

  # The content type is a literal in each of these rather than a parameter: it
  # is never caller-influenced, and writing it once through a variable is
  # indistinguishable from the header-injection shape a scanner is looking for.
  #
  # sobelow_skip ["XSS.SendResp"]
  defp send_activity(conn, document, max_age) do
    conn
    |> put_resp_content_type("application/activity+json")
    |> put_resp_header("cache-control", "public, max-age=#{max_age}")
    |> send_resp(200, Jason.encode!(document))
  end

  # sobelow_skip ["XSS.SendResp"]
  defp send_jrd(conn, document, max_age) do
    conn
    |> put_resp_content_type("application/jrd+json")
    |> put_resp_header("cache-control", "public, max-age=#{max_age}")
    |> send_resp(200, Jason.encode!(document))
  end

  # sobelow_skip ["XSS.SendResp"]
  defp not_found(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, ~s({"error":"not_found"}))
  end
end
