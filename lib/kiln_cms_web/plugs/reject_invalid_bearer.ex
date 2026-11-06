defmodule KilnCMSWeb.Plugs.RejectInvalidBearer do
  @moduledoc """
  Opt-in `401` for a request that presents a bearer token and is not
  authenticated by it (#2161).

  `:load_from_bearer` leaves the actor unset when a JWT does not verify (it
  expired, was revoked, was malformed, or belongs to a deleted user), and the
  request then proceeds as an anonymous caller. A client holding a stale token
  gets a `200` with the published subset and never learns it has been signed
  out. With `config :kiln_cms, :reject_invalid_bearer, true` (the
  `KILN_API_REJECT_INVALID_BEARER` variable) such a request is refused instead:

      HTTP/1.1 401
      www-authenticate: Bearer
      cache-control: private, no-store
      vary: authorization

  The body is `KilnCMSWeb.ApiError`'s envelope on the JSON surfaces,
  `{"errors": [{"message": …, "extensions": {"code": "unauthenticated"}}]}` on
  `/gql`. The message is generic: it does not say whether the token was
  expired, revoked or malformed.

  Mounted after `KilnCMSWeb.Plugs.ApiKeyAuth` in the `:api` and `:graphql`
  pipelines, so `Bearer kiln_…` keys have already been answered (an invalid key
  is a `401` from that plug and never reaches this one). `/mcp` is key-only
  and already refuses a missing or invalid key; `/api/openapi` and the sign-in
  endpoints load no bearer token.

  ## What counts as invalid

  Any `Authorization` header value whose scheme is `Bearer` (matched
  case-insensitively, RFC 7235), including an empty one, on a request where
  neither `Ash.PlugHelpers.get_actor/1` nor `conn.assigns.current_user` is set.
  No header, or another scheme (`Basic`, …), is never invalid here.

  ## Flag off

  The default. The request passes untouched, and the plug emits the telemetry
  event below so an operator can measure how many callers the flag would
  refuse before turning it on.

    * `[:kiln_cms, :api, :invalid_bearer]`, measurements `%{count: 1}`,
      metadata `%{pipeline: :api | :graphql, enforced: boolean(),
      surface: :json_api | :graphql | :media | :other, read?: boolean(),
      reason: :expired | :malformed | :invalid}`

  With the flag on the event is emitted too, with `enforced: true`.
  `read?` is a request that reads (`GET`/`HEAD`, or anything on `/gql`), the
  nearest cheap proxy for "a public route that never needed the token".
  `reason` is read from the unverified JWT: `:malformed` is not a JWT,
  `:expired` has an `exp` in the past, `:invalid` is everything else (revoked,
  deleted user, bad signature). It is never sent to the client, and the event
  carries no token, user or address.

  ## Staleness header (flag off)

  With the flag off the request is still served, but the response carries
  `x-kiln-token-status: invalid`, so a client can notice that its token no
  longer authenticates (ADR 0013). The value is one fixed word: it does not say
  why. Such a request presents a credential, so `PublicCache` already treats it
  as non-anonymous and varies on `authorization`; the header never reaches an
  anonymous cache entry.

  `invalid_bearer?/1` exposes the detection for other plugs that need the same
  verdict.
  """
  @behaviour Plug

  import Plug.Conn

  alias KilnCMSWeb.ApiError
  alias KilnCMSWeb.Plugs.PublicCache

  @message "The bearer token is missing, invalid or expired."

  @doc "Whether `KILN_API_REJECT_INVALID_BEARER` (`:reject_invalid_bearer`) is on. Read per request."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:kiln_cms, :reject_invalid_bearer, false) == true

  @impl true
  def init(pipeline) when pipeline in [:api, :graphql], do: pipeline

  @impl true
  def call(conn, pipeline) do
    if invalid_bearer?(conn) do
      enforced? = enabled?()

      :telemetry.execute([:kiln_cms, :api, :invalid_bearer], %{count: 1}, %{
        pipeline: pipeline,
        enforced: enforced?,
        surface: surface(conn, pipeline),
        read?: read?(conn, pipeline),
        reason: reason(conn)
      })

      if enforced?, do: reject(conn, pipeline), else: flag_stale(conn)
    else
      conn
    end
  end

  @doc """
  Whether `conn` presents a bearer token and carries no authenticated actor.

  Meant to run after the pipeline's auth plugs. It does not look at the flag.
  """
  @spec invalid_bearer?(Plug.Conn.t()) :: boolean()
  def invalid_bearer?(conn), do: bearer?(conn) and not authenticated?(conn)

  defp authenticated?(conn) do
    not is_nil(Ash.PlugHelpers.get_actor(conn)) or not is_nil(conn.assigns[:current_user])
  end

  # Every `authorization` value counts: a proxy may append a second one, and a
  # `Bearer` among them that did not authenticate must not slip past.
  defp bearer?(conn) do
    conn
    |> get_req_header("authorization")
    |> Enum.any?(fn value ->
      value
      |> String.trim_leading()
      |> String.split(~r/\s+/, parts: 2)
      |> hd()
      |> bearer_scheme?()
    end)
  end

  defp flag_stale(conn) do
    conn
    |> put_resp_header("x-kiln-token-status", "invalid")
    |> PublicCache.put_vary(["authorization"])
  end

  defp surface(_conn, :graphql), do: :graphql

  defp surface(%Plug.Conn{path_info: ["api", "json" | _]}, :api), do: :json_api
  defp surface(%Plug.Conn{path_info: ["api", "media" | _]}, :api), do: :media
  defp surface(_conn, :api), do: :other

  defp read?(_conn, :graphql), do: true
  defp read?(%Plug.Conn{method: method}, :api), do: method in ["GET", "HEAD"]

  # Classified from the unverified payload, for telemetry only.
  defp reason(conn) do
    token = bearer_token(conn)

    case token && Joken.peek_claims(token) do
      {:ok, %{"exp" => exp}} when is_number(exp) ->
        if exp < System.os_time(:second), do: :expired, else: :invalid

      {:ok, _claims} ->
        :invalid

      _ ->
        :malformed
    end
  end

  defp bearer_token(conn) do
    conn
    |> get_req_header("authorization")
    |> Enum.find_value(&token_of/1)
  end

  defp token_of(value) do
    case String.split(String.trim_leading(value), ~r/\s+/, parts: 2) do
      [scheme, token] -> if bearer_scheme?(scheme), do: String.trim(token)
      _ -> nil
    end
  end

  defp bearer_scheme?(scheme), do: String.downcase(scheme) == "bearer"

  defp reject(conn, pipeline) do
    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> put_resp_header("cache-control", "private, no-store")
    |> PublicCache.put_vary(["authorization"])
    |> send_error(pipeline)
    |> halt()
  end

  defp send_error(conn, :api), do: ApiError.send(conn, :unauthorized, "invalid_token", @message)

  defp send_error(conn, :graphql) do
    body = %{errors: [%{message: @message, extensions: %{code: "unauthenticated"}}]}

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(body))
  end
end
