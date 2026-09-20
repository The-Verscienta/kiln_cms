defmodule KilnCMSWeb.GraphqlLimits.SocketDocumentBudget do
  @moduledoc """
  Charges each document a client sends over `/ws/gql` to the `:gql` bucket, the
  one `/gql` requests are charged to. It is the first phase of
  `KilnCMSWeb.GraphqlLimits.socket_pipeline/2` and is not part of the HTTP
  pipeline, where `KilnCMSWeb.Plugs.RateLimit` and
  `KilnCMSWeb.Plugs.GraphqlBatchLimit` charge the request.

  Before this phase only the connect was counted (`KilnCMSWeb.SocketJoinBudget`,
  `:gql_join`). A client could connect once and send documents for as long as
  the socket stayed open, each of them allowed the full complexity cap.

  ## The key: the client address, in the bucket `/gql` uses

  The key is the address the connect was charged under
  (`KilnCMSWeb.SocketJoinBudget.client_key/1`). `KilnCMSWeb.GraphqlSocket` puts
  it in the Absinthe context at connect, under `context_key/0`, because the
  context is the only socket state a pipeline sees. The bucket is `:gql` itself,
  not a socket bucket of its own. A GraphQL document costs the same whichever
  transport carries it, so a client gets one budget for both and gains nothing
  by moving from `/gql` to the socket.

  It is not keyed on the actor, as `KilnCMSWeb.SocketEventBudget` keys
  `/ws/collab` frames. That budget is per account because collaboration is a
  stream of frames per keystroke, and an address-wide ceiling sized for one
  office NAT of editors typing at once would be too high to catch a flood.
  Documents are not a stream: a client sends one per query and one per
  subscription, and a subscription's pushes are free (below). The per-address
  size `/gql` already has fits them. An anonymous socket, which is where the gap
  was, has no actor to key on. An actor key alongside the address would bound
  one token used from many addresses, which `/gql` does not bound either.

  ## Only what the client sends is charged

  A subscription's push re-runs its document every time a subscribed record
  changes. It runs the phases Absinthe.Phase.Init recorded when the document
  was first run (Absinthe.Subscription.Local.pipeline/2), and Init records the
  pipeline from itself onward. This phase runs before Init, so pushes skip it.
  A push is caused by a write, not by the subscriber, and the subscriber paid
  for it once, when it subscribed.

  ## The context survives a refused document

  Absinthe.Phoenix.Channel stores the context a document ends with as the
  socket's context for the next one. Absinthe copies the socket's context onto
  the blueprint in `Absinthe.Phase.Document.Context`, which runs after parsing.
  A document refused before that point (a syntax error, the token limit, or this
  budget) therefore ended with an empty context, and the socket lost its tenant,
  its actor and the pubsub subscriptions need, until the client reconnected.
  The next query ran with no tenant, and the next subscription crashed the
  channel. It would also have lost the budget key. This phase builds the
  blueprint with the context already on it, so every early refusal hands the
  socket's context back unchanged.

  ## The refusal

  An over-budget document is answered with a GraphQL error and runs no other
  phase: it is not parsed. The error carries `extensions.code`
  `"too_many_requests"`, the code of the HTTP 429 (`KilnCMSWeb.Plugs.RateLimit`),
  and `extensions.retry_after` in seconds, as in the `retry-after` header. The
  connection stays open, and so do its subscriptions. A refused document is not
  resent by any client on its own, so there is no retry loop to break by closing
  the socket, as `/ws/collab`'s budget has to.
  """

  use Absinthe.Phase

  alias Absinthe.Blueprint
  alias Absinthe.Phase
  alias KilnCMSWeb.RateLimit

  @bucket :gql
  @context_key :rate_limit_key

  @doc "The Absinthe context key that holds the socket's client address key."
  @spec context_key() :: atom()
  def context_key, do: @context_key

  @impl Absinthe.Phase
  @spec run(String.t() | Blueprint.t(), keyword()) :: Phase.result_t()
  def run(input, options) do
    context = Keyword.get(options, :context, %{})
    blueprint = with_context(input, context)

    # A context without a key shares the node-wide unknown-client bucket
    # rather than going uncharged.
    key = Map.get(context, @context_key) || RateLimit.client_key(nil)

    case RateLimit.check(@bucket, key) do
      :allow ->
        {:ok, blueprint}

      {:deny, retry_after_ms} ->
        {:replace, refuse(blueprint, retry_after_ms), [Phase.Document.Result]}
    end
  end

  defp with_context(%Blueprint{} = blueprint, context),
    do: put_in(blueprint.execution.context, context)

  defp with_context(input, context), do: with_context(%Blueprint{input: input}, context)

  defp refuse(blueprint, retry_after_ms) do
    error = %Phase.Error{
      phase: __MODULE__,
      message: "Too many requests.",
      extra: %{
        extensions: %{code: "too_many_requests", retry_after: div(retry_after_ms, 1000)}
      }
    }

    put_in(blueprint.execution.validation_errors, [error])
  end
end
