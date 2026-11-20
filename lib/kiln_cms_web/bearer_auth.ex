defmodule KilnCMSWeb.BearerAuth do
  @moduledoc """
  Shared bearer-token parsing and verification for HTTP plugs and the GraphQL
  WebSocket. `user_from_token/1` mirrors
  `AshAuthentication.Plug.Helpers.retrieve_from_bearer/3` without a conn.

  `parse/1` is the one reading of an `Authorization` value every surface uses
  (#2632): the scheme is matched case-insensitively (RFC 7235), so `bearer`,
  `BEARER` and `Bearer` are the same scheme.
  """

  alias AshAuthentication.Info
  alias AshAuthentication.Jwt
  alias AshAuthentication.TokenResource.Actions, as: TokenActions

  @user KilnCMS.Accounts.User

  @doc """
  Reads one `Authorization` value: `{:bearer, token}` when its scheme is
  `Bearer` in any case, with the token trimmed, or `{:bearer, nil}` for a
  bare `Bearer` with no token (which never authenticates); `:other` for any
  other scheme, or a value that is not a string. Leading and trailing
  whitespace and any run of whitespace after the scheme are tolerated.

      iex> KilnCMSWeb.BearerAuth.parse("bearer  abc ")
      {:bearer, "abc"}

      iex> KilnCMSWeb.BearerAuth.parse("BEARER")
      {:bearer, nil}

      iex> KilnCMSWeb.BearerAuth.parse("Basic dXNlcjpwYXNz")
      :other
  """
  @spec parse(term()) :: {:bearer, String.t() | nil} | :other
  def parse(value) when is_binary(value) do
    [scheme | rest] = value |> String.trim() |> String.split(~r/\s+/, parts: 2)

    if String.downcase(scheme) == "bearer",
      do: {:bearer, List.first(rest)},
      else: :other
  end

  def parse(_value), do: :other

  @doc """
  `value` rewritten to the exact `Bearer <token>` form that AshAuthentication's
  plugs match, when it is a bearer with a token; any other value unchanged.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(value) do
    case parse(value) do
      {:bearer, token} when is_binary(token) -> "Bearer " <> token
      _ -> value
    end
  end

  @doc """
  The bearer token in WebSocket connection params: `params["token"]`, else an
  `Authorization`/`authorization` param under a `Bearer` scheme in any case
  (`parse/1`). `nil` when neither carries one, so the socket is anonymous; `""`
  for a bare `Bearer`, which verifies as nothing and is refused like any other
  bad token, as `/api` and `/gql` refuse it over HTTP.
  """
  def token_from_params(params) when is_map(params) do
    params["token"] ||
      case parse(params["Authorization"] || params["authorization"]) do
        {:bearer, token} -> token || ""
        :other -> nil
      end
  end

  def token_from_params(_), do: nil

  @doc "Verify a JWT and return the user, or `:error`."
  def user_from_token(token) when is_binary(token) do
    token = String.trim(token)
    opts = []

    with {:ok, %{"sub" => subject, "jti" => jti} = claims, @user}
         when not is_map_key(claims, "act") <- Jwt.verify(token, :kiln_cms, opts),
         {:ok, _} <- validate_jti(@user, jti, opts),
         {:ok, user} <- AshAuthentication.subject_to_user(subject, @user, opts) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  def user_from_token(_), do: :error

  @doc "Absinthe context map matching `AshGraphql.Plug`."
  # `tenant: nil` here is a PLACEHOLDER, never served as-is: both socket
  # callers (KilnCMSWeb.GraphqlSocket and the bridge socket) overwrite it with
  # the org resolved from the connecting host (`connect_info`), mirroring the
  # SetTenant plug on the HTTP path (epic #336; wired in the guard-lift).
  def graphql_context(nil), do: %{actor: nil, tenant: nil, context: %{}}

  def graphql_context(user), do: %{actor: user, tenant: nil, context: %{}}

  defp validate_jti(resource, jti, opts) do
    if Info.authentication_tokens_require_token_presence_for_authentication?(resource) do
      with {:ok, token_resource} <- Info.authentication_tokens_token_resource(resource),
           {:ok, [_]} <-
             TokenActions.get_token(
               token_resource,
               # Not a literal (#742). This purpose is what the two-factor hold
               # moves a first-factor row *off*, so a second copy of the string
               # here is a second place the hold can silently stop meaning
               # anything.
               %{"jti" => jti, "purpose" => KilnCMS.Accounts.Token.user_purpose()},
               opts
             ) do
        {:ok, :valid}
      else
        _ -> :error
      end
    else
      {:ok, :valid}
    end
  end
end
