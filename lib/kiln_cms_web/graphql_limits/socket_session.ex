defmodule KilnCMSWeb.GraphqlLimits.SocketSession do
  @moduledoc """
  Refuses every document sent over `/ws/gql` once the bearer JWT the socket
  was opened with is no longer a live sign-in (#2490): the per-document
  backstop under the socket's per-session subscription.

  `KilnCMSWeb.GraphqlSocket` binds a signed-in connection to its bearer's jti
  and subscribes it to
  `KilnCMS.Accounts.SessionEviction.session_socket_topic/1`, so signing that
  token out closes the socket at once. A revocation no broadcast reached — one
  lost between nodes, sent by a node on an older release, or made by a path
  that broadcasts nothing — would otherwise leave the socket serving
  documents under the connect-time actor. So each document reads the token
  row by its primary key first and is refused when the row is gone, is no
  longer a sign-in (`KilnCMS.Accounts.Token.user_purpose/0`; a revoked row
  reads `"revocation"`), or is past its `expires_at`.

  The refusal is a GraphQL error with `extensions.code` `"unauthenticated"`,
  the code `/gql` answers a bearer that does not verify with, and runs no
  other phase. A client should reconnect with a valid token.

  A row that cannot be read passes the document, as every other session check
  fails open on a database blip; a missing row is refused like an expired
  one. An anonymous socket has no jti and passes untouched.

  What remains: a socket that only holds subscriptions sends no documents, so
  after an unbroadcast revocation it keeps receiving pushes until it next
  sends one or reconnects. A subscription's pushes skip this phase, as they
  skip `KilnCMSWeb.GraphqlLimits.SocketDocumentBudget`: both run before
  Absinthe.Phase.Init.
  """

  use Absinthe.Phase

  alias Absinthe.Blueprint
  alias Absinthe.Phase
  alias KilnCMS.Accounts.IdleTimeout
  alias KilnCMS.Accounts.Token

  @context_key :kiln_session_jti

  @doc "The Absinthe context key that holds the jti of the socket's bearer JWT."
  @spec context_key() :: atom()
  def context_key, do: @context_key

  @impl Absinthe.Phase
  @spec run(Blueprint.t(), keyword()) :: Phase.result_t()
  def run(%Blueprint{} = blueprint, options) do
    context = Keyword.get(options, :context, %{})

    if signed_out?(Map.get(context, @context_key)),
      do: {:replace, refuse(blueprint), [Phase.Document.Result]},
      else: {:ok, blueprint}
  end

  defp signed_out?(jti) when is_binary(jti) do
    # The idle timeout's own row read (by jti, any purpose): the policy is not
    # consulted, so "off" only sets the idle floor nothing here looks at.
    case IdleTimeout.read(jti, IdleTimeout.off()) do
      {:ok, row} -> not live?(row)
      :error -> false
    end
  end

  defp signed_out?(_anonymous), do: false

  defp live?(%Token{purpose: purpose, expires_at: %DateTime{} = expires_at}),
    do:
      purpose == Token.user_purpose() and DateTime.compare(expires_at, DateTime.utc_now()) == :gt

  defp live?(_missing), do: false

  defp refuse(blueprint) do
    error = %Phase.Error{
      phase: __MODULE__,
      message:
        "The bearer token this connection was opened with is no longer valid. Reconnect with a valid token.",
      extra: %{extensions: %{code: "unauthenticated"}}
    }

    put_in(blueprint.execution.validation_errors, [error])
  end
end
