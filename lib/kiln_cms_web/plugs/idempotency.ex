defmodule KilnCMSWeb.Plugs.Idempotency do
  @moduledoc """
  `Idempotency-Key` for the headless writes: a client that retries a `POST` or
  `PATCH` after a timeout gets the first attempt's response back instead of a
  second document or a second transition (`docs/api.md#idempotent-writes`).

  Opt-in per request — no header, no effect — and only for an authenticated
  actor, whose id scopes the key. Storage is `KilnCMS.Accounts.IdempotentRequest`.

  For a request carrying a key:

    1. **New key** — claimed (`:in_progress`) before the request runs; its
       response is stored as it is sent (`register_before_send/2`).
    2. **Same key, same request, finished** — the stored status, body and
       `content-type` / `etag` / `location` are sent back with
       `idempotency-replayed: true`, and the request is not run again.
    3. **Same key, different request** — `422 idempotency_key_reused`. The
       fingerprint is a hash of method, path, query string and parsed body.
    4. **Same key, first request still running** — `409
       idempotency_request_in_progress`, `retry-after: 1`. A claim nobody has
       settled for `@stale_after_seconds` is treated as abandoned (its request
       crashed before it could answer) and taken over.

  Which responses are kept: every 2xx, and the 4xx that describe the request
  itself (a validation error, a 404, a 412). Not a 401 / 403 (the caller may fix
  its credentials and retry), a 409 / 429 (transient by definition), any 5xx,
  or a body over `@max_body_bytes` — for those the claim is released so a retry
  runs for real.
  """
  @behaviour Plug

  import Plug.Conn

  alias KilnCMS.Accounts.IdempotentRequest

  require Logger

  @header "idempotency-key"
  @replayed_header "idempotency-replayed"
  @methods ["POST", "PATCH"]
  @stale_after_seconds 60
  @max_body_bytes 1_000_000
  @replayed_response_headers ["content-type", "etag", "location"]
  @not_kept [401, 403, 409, 429]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: method} = conn, _opts) when method in @methods do
    case {get_req_header(conn, @header), Ash.PlugHelpers.get_actor(conn)} do
      # No key: nothing to do. No actor: nothing to scope a key to — an
      # anonymous write is refused by the resource policies anyway.
      {[], _actor} ->
        conn

      {_keys, actor} when not is_map(actor) ->
        conn

      {[key], %{id: actor_id}} ->
        if valid_key?(key),
          do: run(conn, "user:#{actor_id}", key),
          else: invalid(conn)

      # Two different keys on one request: there is no right one to pick, and
      # picking either would make the guarantee depend on header order.
      {_several, _actor} ->
        invalid(conn)
    end
  end

  def call(conn, _opts), do: conn

  defp valid_key?(key), do: byte_size(key) in 1..255 and key =~ ~r/\A[\x21-\x7E]+\z/

  defp invalid(conn) do
    refuse(
      conn,
      400,
      "idempotency_key_invalid",
      "Send one Idempotency-Key of 1–255 printable ASCII characters."
    )
  end

  defp run(conn, scope, key) do
    tenant = Ash.PlugHelpers.get_tenant(conn)
    fingerprint = fingerprint(conn)

    case claim(scope, key, fingerprint, tenant) do
      {:claimed, record} ->
        register_before_send(conn, &settle(&1, record, tenant))

      # The ledger would not hold still (or is unreachable). The request runs
      # without the guarantee rather than being refused: this is a retry aid,
      # not an authorization control.
      :unavailable ->
        conn

      {:existing, %{fingerprint: other}} when other != fingerprint ->
        refuse(
          conn,
          422,
          "idempotency_key_reused",
          "This Idempotency-Key was already used for a different request."
        )

      {:existing, %{status: :completed} = record} ->
        replay(conn, record)

      {:existing, _in_progress} ->
        conn
        |> put_resp_header("retry-after", "1")
        |> refuse(
          409,
          "idempotency_request_in_progress",
          "A request with this Idempotency-Key is still being processed."
        )
    end
  end

  # Insert the claim; the unique identity is the lock. A row that is already
  # there is either live (returned as-is), expired (reused) or an abandoned
  # claim (taken over).
  defp claim(scope, key, fingerprint, tenant, attempt \\ 1) do
    # authorize?: false — a system table with a forbid-all policy; this plug is
    # its only reader and writer, scoped by the caller's own actor id.
    IdempotentRequest
    |> Ash.Changeset.for_create(
      :claim,
      %{scope: scope, key: key, fingerprint: fingerprint},
      authorize?: false,
      tenant: tenant
    )
    |> Ash.create()
    |> case do
      {:ok, record} -> {:claimed, record}
      {:error, _conflict} -> existing(scope, key, fingerprint, tenant, attempt)
    end
  end

  defp existing(scope, key, fingerprint, tenant, attempt) do
    # authorize?: false — see `claim/4`.
    case Ash.read_one(
           Ash.Query.for_read(IdempotentRequest, :lookup, %{scope: scope, key: key}),
           authorize?: false,
           tenant: tenant
         ) do
      {:ok, %IdempotentRequest{} = record} ->
        if expired?(record) or abandoned?(record),
          do: reclaim(record, fingerprint, tenant),
          else: {:existing, record}

      # Pruned between the failed insert and this read: claim afresh — but
      # bounded, so a row that keeps vanishing cannot spin. Giving up runs the
      # request unguarded, which is what a caller without the header gets.
      _ when attempt < 3 ->
        claim(scope, key, fingerprint, tenant, attempt + 1)

      _ ->
        :unavailable
    end
  end

  defp reclaim(record, fingerprint, tenant) do
    # authorize?: false — see `claim/4`.
    record
    |> Ash.Changeset.for_update(:reclaim, %{fingerprint: fingerprint},
      authorize?: false,
      tenant: tenant
    )
    |> Ash.update()
    |> case do
      {:ok, record} -> {:claimed, record}
      {:error, _} -> {:existing, record}
    end
  end

  defp expired?(record),
    do:
      DateTime.diff(DateTime.utc_now(), record.inserted_at, :hour) >=
        IdempotentRequest.ttl_hours()

  defp abandoned?(%{status: :in_progress, updated_at: at}),
    do: DateTime.diff(DateTime.utc_now(), at, :second) >= @stale_after_seconds

  defp abandoned?(_record), do: false

  defp settle(conn, record, tenant) do
    body = IO.iodata_to_binary(conn.resp_body || "")

    if keep?(conn.status, body) do
      headers =
        for {name, value} <- conn.resp_headers,
            name in @replayed_response_headers,
            into: %{},
            do: {name, value}

      # authorize?: false — see `claim/4`.
      record
      |> Ash.Changeset.for_update(
        :complete,
        %{response_status: conn.status, response_headers: headers, response_body: body},
        authorize?: false,
        tenant: tenant
      )
      |> Ash.update()
      |> log_failure()
    else
      # authorize?: false — see `claim/4`.
      record |> Ash.destroy(authorize?: false, tenant: tenant) |> log_failure()
    end

    conn
  end

  defp keep?(status, body),
    do: status in 200..499 and status not in @not_kept and byte_size(body) <= @max_body_bytes

  # Settling runs as the response is sent; a failure there must not turn a
  # finished request into a 500. The worst case is a claim left in progress,
  # which `abandoned?/1` retires.
  defp log_failure({:error, error}) do
    Logger.warning("Idempotency-Key response could not be stored: #{Exception.message(error)}")
  end

  defp log_failure(_ok), do: :ok

  # sobelow_skip ["XSS.SendResp"]
  #
  # The body is not user input reflected into a page: it is this same server's
  # own earlier response to this same actor, stored verbatim and replayed with
  # the `content-type` it was sent under (`application/vnd.api+json` or
  # `application/json` — the API pipelines answer nothing else). Re-encoding it
  # would be worse: a replay has to be byte-identical to be a replay.
  defp replay(conn, record) do
    conn =
      Enum.reduce(record.response_headers || %{}, conn, fn {name, value}, conn ->
        put_resp_header(conn, name, value)
      end)

    conn
    |> put_resp_header(@replayed_header, "true")
    |> send_resp(record.response_status, record.response_body || "")
    |> halt()
  end

  defp refuse(conn, status, code, detail) do
    conn
    |> KilnCMSWeb.ApiError.send(status, code, detail)
    |> halt()
  end

  # What makes two requests "the same": method, path, query string, and the
  # parsed body in a canonical order (map keys sorted), so a client that
  # re-serializes its retry with different key order or whitespace still
  # matches.
  defp fingerprint(conn) do
    [conn.method, conn.request_path, conn.query_string, canonical(conn.body_params)]
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(%Plug.Conn.Unfetched{}), do: nil
  # An upload's temp path differs per request, so a multipart retry never
  # matches — which errs toward running the request, never toward replaying
  # the wrong response.
  defp canonical(%_{} = struct), do: inspect(struct)

  defp canonical(%{} = map),
    do: map |> Enum.map(fn {k, v} -> {to_string(k), canonical(v)} end) |> Enum.sort()

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(other), do: other
end
