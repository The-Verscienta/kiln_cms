defmodule KilnCMSWeb.SyncController do
  @moduledoc """
  `GET /api/sync` — the delta API over a site's public content
  (`KilnCMS.Firing.Sync`).

      GET /api/sync?initial=true[&type=post][&surface=json][&limit=100]
      GET /api/sync?cursor=…

  Every response is

      {"items": [...], "cursor": "…", "has_more": true | false}

  Follow `cursor` straight away while `has_more` is true; once it is false,
  store the cursor and poll with it later. Items are

      {"op": "upsert", "type", "id", "slug", "locale", "published_at",
       "updated_at", "artifact": {…}}
      {"op": "delete", "type", "id"}

  where `artifact` is the fired surface `GET /api/content/:type/:slug` serves.

  The cursor is signed and opaque, and carries its own scope: the org it was
  issued for, the type (if any) and the surface, so `type` and `surface` on a
  cursor request are ignored (`limit` is not). A cursor that fails verification
  — tampered with, from another site, or signed with a `SECRET_KEY_BASE` that
  has since been rotated — is a `400 invalid_cursor`; the client starts over
  with `initial=true`.

  Anonymous visibility whoever calls, so the response is never a function of
  the caller; it is `no-store` all the same, because a delta for the same
  cursor changes as time passes.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Firing.Sync
  alias KilnCMSWeb.ApiError
  alias KilnCMSWeb.Params

  @surfaces KilnCMS.Firing.Surfaces.name_map()
  @salt "kiln sync cursor"
  @retry_after_seconds 2

  def index(conn, params) do
    org_id = KilnCMSWeb.Tenant.current_org_id(conn)
    limit = Params.integer(params, "limit", 100, 1..500)
    conn = put_resp_header(conn, "cache-control", "no-store")

    with {:ok, scope, position} <- request(conn, params, org_id),
         result <-
           Sync.page(org_id, scope.type, position, limit: limit, surface: scope.surface) do
      respond(conn, scope, result)
    else
      {:error, status, code, detail} -> ApiError.send(conn, status, code, detail)
    end
  end

  # Exactly one of `initial=true` and `cursor=`.
  defp request(conn, params, org_id) do
    case {Params.string(params, "initial"), Params.string(params, "cursor")} do
      {"true", nil} ->
        start(params)

      {nil, cursor} when is_binary(cursor) ->
        resume(conn, cursor, org_id)

      {nil, nil} ->
        error(:bad_request, "missing_cursor", "Pass `initial=true` or `cursor`.")

      _both ->
        error(:bad_request, "invalid_request", "Pass `initial=true` or `cursor`, not both.")
    end
  end

  defp start(params) do
    case Map.fetch(@surfaces, Params.string(params, "surface", "json")) do
      {:ok, surface} ->
        {:ok, %{type: Params.string(params, "type"), surface: surface}, Sync.start()}

      :error ->
        error(:bad_request, "invalid_surface", "Unknown `surface`.")
    end
  end

  defp resume(conn, cursor, org_id) do
    with {:ok, %{"o" => ^org_id, "t" => type, "s" => surface, "p" => position}} <-
           Phoenix.Token.verify(conn, @salt, cursor, max_age: :infinity),
         {:ok, surface} <- Map.fetch(@surfaces, surface),
         {:ok, position} <- decode_position(position) do
      {:ok, %{type: type, surface: surface}, position}
    else
      _invalid ->
        error(
          :bad_request,
          "invalid_cursor",
          "This cursor is not valid for this site. Start a new sync with `initial=true`."
        )
    end
  end

  defp respond(conn, scope, {:ok, items, next, more?}) do
    json(conn, %{items: items, cursor: sign(conn, scope, next), has_more: more?})
  end

  defp respond(conn, _scope, {:error, :unknown_type}),
    do: ApiError.send(conn, :not_found, "not_found", "Unknown content type.")

  defp respond(conn, _scope, :backfilling) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(@retry_after_seconds))
    |> ApiError.send(
      :service_unavailable,
      "artifact_compiling",
      "A document on this page is compiling; retry the same request shortly."
    )
  end

  defp respond(conn, _scope, :unavailable) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(@retry_after_seconds))
    |> ApiError.send(
      :service_unavailable,
      "temporarily_unavailable",
      "Sync is temporarily unavailable; retry shortly."
    )
  end

  defp error(status, code, detail), do: {:error, status, code, detail}

  # ── Cursor encoding ──────────────────────────────────────────────────────
  #
  # Signed, not encrypted: nothing in it is secret (instants, a type name and
  # the last id already sent), but every part of it steers a query, so the
  # client must not be able to edit it. Bound to the org it was issued for.

  defp sign(conn, scope, position) do
    Phoenix.Token.sign(conn, @salt, %{
      "o" => KilnCMSWeb.Tenant.current_org_id(conn),
      "t" => scope.type,
      "s" => to_string(scope.surface),
      "p" => encode_position(position)
    })
  end

  defp encode_position({:initial, started_at, after_key}),
    do: ["i", usec(started_at), encode_after(after_key)]

  defp encode_position({:delta, since, until, after_key}),
    do: ["d", usec(since), usec(until), encode_after(after_key)]

  defp encode_after(nil), do: nil
  defp encode_after({name, id}), do: [name, id]

  defp decode_position(["i", started_at, after_key]) when is_integer(started_at) do
    with {:ok, after_key} <- decode_after(after_key),
         do: {:ok, {:initial, from_usec(started_at), after_key}}
  end

  defp decode_position(["d", since, until, after_key]) when is_integer(since) do
    with {:ok, after_key} <- decode_after(after_key),
         do: {:ok, {:delta, from_usec(since), until && from_usec(until), after_key}}
  end

  defp decode_position(_other), do: :error

  defp decode_after(nil), do: {:ok, nil}
  defp decode_after([name, id]) when is_binary(name) and is_binary(id), do: {:ok, {name, id}}
  defp decode_after(_other), do: :error

  defp usec(nil), do: nil
  defp usec(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)

  defp from_usec(usec), do: DateTime.from_unix!(usec, :microsecond)
end
