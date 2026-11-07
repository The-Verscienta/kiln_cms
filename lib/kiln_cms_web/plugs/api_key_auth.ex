defmodule KilnCMSWeb.Plugs.ApiKeyAuth do
  @moduledoc """
  Authenticates headless API requests presenting an **API key** as
  `Authorization: Bearer kiln_…`, setting the owning user as the Ash actor.

  Runs after `:load_from_bearer`/`:set_actor` so JWT and API-key auth share one
  `Authorization: Bearer` scheme, disambiguated by the key's `kiln_` prefix:

    * `Bearer kiln_…` → delegated to `AshAuthentication.Strategy.ApiKey.Plug`,
      which validates the key and assigns `current_user` / the actor. An invalid,
      expired or revoked key is rejected with `401`.
    * anything else (a JWT, or no header) → passed through untouched, so
      `:load_from_bearer` retains sole responsibility for JWT bearer tokens.

  ## Rejecting a bearer that verifies as nothing (#2161)

  `:load_from_bearer` silently degrades a JWT that fails verification (garbage,
  expired, signed by another instance) to **anonymous**, so a client with a
  broken credential reads public content and takes it for success. So an
  `Authorization: Bearer …` header that left no actor behind is answered `401`
  in the standard `KilnCMSWeb.ApiError` envelope instead. A request with no
  `Authorization` header stays anonymous, and so does one using another scheme.

  **On by default.** It shipped off for one release and flipped on in the next
  (`docs/decisions/0012-*`). `config :kiln_cms, #{inspect(__MODULE__)},
  reject_invalid_bearer: false` (`KILN_API_REJECT_INVALID_BEARER=false`) restores
  the anonymous fallback; that escape hatch is kept for one more release, then
  removed.

  Keeping the two apart matters: the API-key plug treats a present-but-unrecognised
  `Bearer` value as an *invalid key* (401), so it must never see a JWT.
  """
  @behaviour Plug

  @prefix "Bearer " <> KilnCMS.Accounts.ApiKey.prefix() <> "_"

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
    cond do
      api_key_request?(conn) -> AshAuthentication.Strategy.ApiKey.Plug.call(conn, opts)
      loads_bearer? and reject_invalid_bearer?() and unverified_bearer?(conn) -> reject(conn)
      true -> conn
    end
  end

  @doc "Whether an unverifiable bearer token is a `401` (`KILN_API_REJECT_INVALID_BEARER`)."
  @spec reject_invalid_bearer?() :: boolean()
  def reject_invalid_bearer? do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(:reject_invalid_bearer, true)
  end

  # A `Bearer` header, not a `kiln_` key (handled above), and no actor: the
  # JWT in it did not verify. A verified one has set the actor by now.
  defp unverified_bearer?(conn) do
    match?([_ | _], bearer_headers(conn)) and is_nil(Ash.PlugHelpers.get_actor(conn))
  end

  defp bearer_headers(conn) do
    for "Bearer " <> _ = value <- Plug.Conn.get_req_header(conn, "authorization"), do: value
  end

  defp reject(conn) do
    conn
    |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer error="invalid_token"))
    |> KilnCMSWeb.ApiError.send(
      :unauthorized,
      "invalid_token",
      "The bearer token is invalid or expired. Send a valid token or API key, or omit the Authorization header to read public content."
    )
    |> Plug.Conn.halt()
  end

  defp api_key_request?(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      [value | _] -> String.starts_with?(value, @prefix)
      _ -> false
    end
  end
end
