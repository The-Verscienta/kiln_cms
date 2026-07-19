defmodule KilnCMSWeb.BearerAuth do
  @moduledoc """
  Shared bearer-token verification for HTTP plugs and the GraphQL WebSocket.
  Mirrors `AshAuthentication.Plug.Helpers.retrieve_from_bearer/3` without a conn.
  """

  alias AshAuthentication.Info
  alias AshAuthentication.Jwt
  alias AshAuthentication.TokenResource.Actions, as: TokenActions

  @user KilnCMS.Accounts.User

  @doc "Extract a bearer token from WebSocket connection params."
  def token_from_params(params) when is_map(params) do
    params["token"] ||
      case params["Authorization"] || params["authorization"] do
        "Bearer " <> token -> String.trim(token)
        _ -> nil
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
  # NOTE (epic #336): `tenant: nil` — the GraphQL WebSocket transport
  # (`/ws/gql`, KilnCMSWeb.GraphqlSocket) bypasses the endpoint plug pipeline, so
  # KilnCMSWeb.Plugs.SetTenant never runs for it and socket queries/subscriptions
  # are unscoped (allow-global under `global?: true`). The HTTP `/gql` path IS
  # scoped (AshGraphql.Plug reads the plug tenant). Resolving the tenant from the
  # socket `connect_info` host is a follow-up before real multi-org is enabled;
  # safe under the single-org rollout guard until then.
  def graphql_context(nil), do: %{actor: nil, tenant: nil, context: %{}}

  def graphql_context(user), do: %{actor: user, tenant: nil, context: %{}}

  defp validate_jti(resource, jti, opts) do
    if Info.authentication_tokens_require_token_presence_for_authentication?(resource) do
      with {:ok, token_resource} <- Info.authentication_tokens_token_resource(resource),
           {:ok, [_]} <-
             TokenActions.get_token(
               token_resource,
               %{"jti" => jti, "purpose" => "user"},
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
