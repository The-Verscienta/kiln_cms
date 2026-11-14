defmodule KilnCMSWeb.Plugs.ApiKeyAuth do
  @moduledoc """
  Authenticates headless API requests presenting an **API key** as
  `Authorization: Bearer kiln_…`, setting the owning user as the Ash actor.

  Runs after `:load_from_bearer`/`:set_actor` so JWT and API-key auth share one
  `Authorization: Bearer` scheme, disambiguated by the key's `kiln_` prefix:

    * `Bearer kiln_…` → delegated to `AshAuthentication.Strategy.ApiKey.Plug`,
      which validates the key and assigns `current_user` / the actor. An invalid,
      expired or revoked key is rejected with `401`. The key is found in any
      `authorization` value, not only the first, and the scheme is matched
      case-insensitively (`bearer kiln_…` works). When several values carry a
      key the first one decides, and a key wins over a JWT sent alongside it
      (#2633).
    * anything else (a JWT, or no header) → passed through untouched, so
      `:load_from_bearer` retains sole responsibility for JWT bearer tokens.

  ## Rejecting a bearer that verifies as nothing (#2161)

  `:load_from_bearer` silently degrades a JWT that fails verification (garbage,
  expired, signed by another instance) to **anonymous**, so a client with a
  broken credential reads public content and takes it for success. So an
  `Authorization: Bearer …` header that left no actor behind is answered `401`
  in the standard `KilnCMSWeb.ApiError` envelope instead (on `/gql`:
  `{"errors": [{"message", "extensions": {"code": "unauthenticated"}}]}`), with
  `cache-control: private, no-store` and `vary: authorization`. The scheme is
  matched case-insensitively across every `authorization` value, and a bare
  `Bearer` is invalid too. A request with no
  `Authorization` header stays anonymous, and so does one using another scheme.

  **On by default.** It shipped off for one release and flipped on in the next
  (`docs/decisions/0012-*`). `config :kiln_cms, #{inspect(__MODULE__)},
  reject_invalid_bearer: false` (`KILN_API_REJECT_INVALID_BEARER=false`) restores
  the anonymous fallback; that escape hatch is kept for one more release, then
  removed.

  ### Counting the stale tokens

  Every request that presents such a bearer emits
  `[:kiln_cms, :api, :invalid_bearer]`, whether or not it was refused:
  measurement `count: 1`, metadata `enforced: boolean()`,
  `surface: :json_api | :graphql | :media | :other`, `read?: boolean()` (a
  `GET`/`HEAD`, or anything on `/gql`: the nearest cheap proxy for "a public
  route that never needed the token") and `reason: :expired | :malformed |
  :invalid` (read from the unverified payload, never sent to the client;
  revoked, deleted-user and bad-signature tokens are all `:invalid`). No token,
  user or address is in the event.

  `KilnCMSWeb.Telemetry.metrics/0` counts it as `kiln_cms.api.invalid_bearer.count`
  (#2635), exported as `kiln_cms_api_invalid_bearer_count` when
  `KILN_METRICS_ENABLED` is on. Its labels are `enforced`, `surface`, `read` and
  `reason`: `read?` is exported as `read`, because a `?` is not valid in a
  Prometheus label name. The event's metadata keeps `read?`.

  Keeping the two apart matters: the API-key plug treats a present-but-unrecognised
  `Bearer` value as an *invalid key* (401), so it must never see a JWT.
  """
  @behaviour Plug

  @key_prefix KilnCMS.Accounts.ApiKey.prefix() <> "_"

  # `required?: false` so requests *without* a key aren't rejected here (they may
  # be anonymous or JWT-authenticated); we only invoke this plug once we've
  # confirmed the header carries one of our keys, so a bad key still 401s.
  @impl true
  def init(opts) do
    key_opts =
      AshAuthentication.Strategy.ApiKey.Plug.init(
        resource: KilnCMS.Accounts.User,
        required?: false
      )

    # `loads_bearer: true` only where `:load_from_bearer` ran earlier in the
    # pipeline. Without it a valid JWT has no actor yet, so the #2161 rejection
    # would 401 it (the `:api_spec` pipeline has no JWT loader).
    {key_opts, Keyword.get(opts, :loads_bearer, false)}
  end

  @impl true
  def call(conn, {opts, loads_bearer?}) do
    case presented_key(conn) do
      {:ok, key} -> authenticate_key(conn, key, opts)
      :error when loads_bearer? -> if unverified_bearer?(conn), do: stale_bearer(conn), else: conn
      :error -> conn
    end
  end

  # The key plug reads only the first `authorization` value and needs the
  # exact `Bearer ` prefix, so it is handed one normalized header. The
  # caller's headers are put back afterwards for everything downstream. A key
  # that authenticated is remembered on this node, so a later rate-limit
  # refusal can tell it was a real key (`KilnCMS.Security.ApiKeyTrip`).
  defp authenticate_key(conn, key, opts) do
    original = conn.req_headers

    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> key)
      |> AshAuthentication.Strategy.ApiKey.Plug.call(opts)
      |> Map.put(:req_headers, original)

    unless conn.halted,
      do: KilnCMS.Security.ApiKeyTrip.remember(key, Ash.PlugHelpers.get_actor(conn))

    conn
  end

  defp stale_bearer(conn) do
    enforced? = reject_invalid_bearer?()

    :telemetry.execute([:kiln_cms, :api, :invalid_bearer], %{count: 1}, %{
      enforced: enforced?,
      surface: surface(conn),
      read?: read?(conn),
      reason: reason(conn)
    })

    if enforced?, do: reject(conn), else: conn
  end

  defp surface(%Plug.Conn{path_info: ["api", "json" | _]}), do: :json_api
  defp surface(%Plug.Conn{path_info: ["api", "graphql" | _]}), do: :graphql
  defp surface(%Plug.Conn{path_info: ["gql" | _]}), do: :graphql
  defp surface(%Plug.Conn{path_info: ["api", "media" | _]}), do: :media
  defp surface(_conn), do: :other

  defp read?(%Plug.Conn{method: method} = conn),
    do: surface(conn) == :graphql or method in ["GET", "HEAD"]

  # Classified from the unverified payload, for telemetry only.
  defp reason(conn) do
    case bearer_headers(conn) do
      [value | _] -> value |> bearer_token() |> classify_token()
      _ -> :malformed
    end
  end

  defp classify_token(nil), do: :malformed
  defp classify_token(token), do: token |> Joken.peek_claims() |> classify_claims()

  defp classify_claims({:ok, %{"exp" => exp}}) when is_number(exp),
    do: if(exp < System.os_time(:second), do: :expired, else: :invalid)

  defp classify_claims({:ok, _claims}), do: :invalid
  defp classify_claims(_error), do: :malformed

  @doc """
  For a transport with no conn (`KilnCMSWeb.GraphqlSocket`, #2634): emits the
  same `[:kiln_cms, :api, :invalid_bearer]` event for `token`, a bearer that
  did not verify, and answers whether it is refused
  (`reject_invalid_bearer?/0`).
  """
  @spec note_invalid_bearer(String.t(), :json_api | :graphql | :media | :other, boolean()) ::
          boolean()
  def note_invalid_bearer(token, surface, read?) do
    enforced? = reject_invalid_bearer?()

    :telemetry.execute([:kiln_cms, :api, :invalid_bearer], %{count: 1}, %{
      enforced: enforced?,
      surface: surface,
      read?: read?,
      reason: classify_token(token)
    })

    enforced?
  end

  @doc "Whether an unverifiable bearer token is a `401` (`KILN_API_REJECT_INVALID_BEARER`)."
  @spec reject_invalid_bearer?() :: boolean()
  def reject_invalid_bearer? do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(:reject_invalid_bearer, true)
  end

  # A `Bearer` header, not a `kiln_` key (handled above), and no actor: the
  # JWT in it did not verify. A verified one has set the actor by now.
  defp unverified_bearer?(conn) do
    match?([_ | _], bearer_headers(conn)) and is_nil(Ash.PlugHelpers.get_actor(conn)) and
      is_nil(conn.assigns[:current_user])
  end

  # Every `authorization` value whose scheme is `Bearer`, matched
  # case-insensitively (RFC 7235), including a bare `Bearer` with no token. A
  # proxy may append a second value; a bearer among them that did not
  # authenticate must not slip past.
  defp bearer_headers(conn) do
    for value <- Plug.Conn.get_req_header(conn, "authorization"),
        value
        |> String.trim_leading()
        |> String.split(~r/\s+/, parts: 2)
        |> hd()
        |> String.downcase() ==
          "bearer",
        do: value
  end

  @message "The bearer token is invalid or expired. Send a valid token or API key, or omit the Authorization header to read public content."

  # Never cacheable, and keyed on the credential (#2318).
  defp reject(conn) do
    conn
    |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer error="invalid_token"))
    |> Plug.Conn.put_resp_header("cache-control", "private, no-store")
    |> KilnCMSWeb.Plugs.PublicCache.put_vary(["authorization"])
    |> send_error()
    |> Plug.Conn.halt()
  end

  # `/gql` speaks GraphQL's error shape; every other surface keeps the
  # `ApiError` envelope with `401 invalid_token`.
  defp send_error(%Plug.Conn{path_info: ["gql" | _]} = conn) do
    # `code` is kept alongside `extensions.code` so a client that read
    # `errors[0].code == "invalid_token"` from the old envelope still matches.
    body = %{
      errors: [
        %{message: @message, code: "invalid_token", extensions: %{code: "unauthenticated"}}
      ]
    }

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(401, Jason.encode!(body))
  end

  defp send_error(conn),
    do: KilnCMSWeb.ApiError.send(conn, :unauthorized, "invalid_token", @message)

  @doc """
  The API key `conn` presents, unverified: the first `kiln_…` token under a
  `Bearer` scheme (any case) across every `authorization` value (#2633), or
  `:error`. It decides the request: a later key is ignored, and an invalid
  first key is a 401 even when a later one is valid. Pure; reads only the
  headers.
  """
  @spec presented_key(Plug.Conn.t()) :: {:ok, String.t()} | :error
  def presented_key(conn) do
    Enum.find_value(bearer_headers(conn), :error, fn value ->
      case bearer_token(value) do
        @key_prefix <> _ = token -> {:ok, token}
        _ -> nil
      end
    end)
  end

  # The token after the scheme, or `nil` for a bare `Bearer`.
  defp bearer_token(value) do
    value |> String.trim() |> String.split(~r/\s+/, parts: 2) |> Enum.at(1)
  end
end
