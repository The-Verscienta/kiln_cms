defmodule KilnCMSWeb.ChangeFeedController do
  @moduledoc """
  `GET /api/feed` — the change feed over Server-Sent Events (#2275).

      GET /api/feed[?type=post]
      Accept: text/event-stream
      Last-Event-ID: <id>          # or ?last_event_id=<id>

  Resolves the request — the site, the type filter, the resume point, the
  client the per-client cap counts — and hands it to `KilnCMSWeb.FeedStream`,
  whose moduledoc describes the stream. An unknown `type` (or a resume cursor
  naming a type this site no longer has) is a `404`, as on `GET /api/sync`.
  `HEAD` answers the stream's headers and nothing else, holding no slot.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Firing.SyncCursor
  alias KilnCMSWeb.ApiError
  alias KilnCMSWeb.FeedStream
  alias KilnCMSWeb.Params
  alias KilnCMSWeb.RateLimit

  def stream(conn, params) do
    org_id = KilnCMSWeb.Tenant.current_org_id(conn)
    {resume, type} = resume(conn, params, org_id)

    cond do
      type && is_nil(ContentTypes.get(type, org_id)) ->
        ApiError.send(conn, :not_found, "not_found", "Unknown content type.")

      # `Plug.Head` has turned a HEAD into a GET by now (`:kiln_head?` is the
      # endpoint's note of what it was).
      conn.private[:kiln_head?] ->
        conn |> FeedStream.put_headers() |> send_resp(200, "")

      true ->
        FeedStream.run(conn, %{org_id: org_id, type: type, client: client(conn), resume: resume})
    end
  end

  # `{resume, type}`. A cursor carries its own type, which wins over `?type=`,
  # as on `/api/sync`; a delta cursor resumes from its `since` whatever window
  # or page it was in the middle of, since a mid-delta `until` would skip what
  # changed after it.
  defp resume(conn, params, org_id) do
    type = Params.string(params, "type")

    case last_event_id(conn, params) do
      nil ->
        {nil, type}

      cursor ->
        case SyncCursor.verify(cursor, org_id) do
          {:ok, %{type: cursor_type, position: {:delta, since, _until, _after}}} ->
            {{:since, since}, cursor_type}

          # An initial snapshot still paging, or a cursor that does not verify
          # (tampered with, another site's, a rotated secret).
          _not_a_resume_point ->
            {{:reset, "invalid_cursor"}, type}
        end
    end
  end

  defp last_event_id(conn, params) do
    case get_req_header(conn, "last-event-id") do
      [id | _] when id != "" -> id
      _none -> Params.string(params, "last_event_id")
    end
  end

  # The per-client cap's key: the API key when the stream presents one (so a
  # front end's server behind one address can hold its own budget), else the
  # client address.
  defp client(conn) do
    case conn.assigns[:current_user] do
      %{__metadata__: %{api_key: %{id: key_id}}} -> "key:" <> key_id
      _no_key -> "ip:" <> RateLimit.client_key(conn.remote_ip)
    end
  end
end
