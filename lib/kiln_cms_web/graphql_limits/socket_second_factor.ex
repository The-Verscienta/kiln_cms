defmodule KilnCMSWeb.GraphqlLimits.SocketSecondFactor do
  @moduledoc """
  Refuses every document sent over `/ws/gql` by an account its site now holds
  for a second factor it has not set up (#2247): the socket's equivalent of
  `KilnCMSWeb.Plugs.SecondFactorBearer`, which checks each `/gql` request.

  The socket's actor and site were fixed at connect, from a JWT that may have
  been minted during the grace period. `KilnCMSWeb.GraphqlSocket` refuses the
  connect once the deadline has passed and closes the socket at the deadline;
  this phase holds even if that close never arrives, for queries, mutations
  and new subscriptions alike. A subscription's pushes skip it, as they skip
  `KilnCMSWeb.GraphqlLimits.SocketDocumentBudget`: both run before
  Absinthe.Phase.Init.

  The refusal is a GraphQL error with `extensions.code`
  `"second_factor_required"`, the code `/gql` answers with, and runs no other
  phase. A passkey-only account past its deadline is refused too: the socket
  was opened with a JWT, which never passed the passkey. An anonymous socket
  passes untouched.
  """

  use Absinthe.Phase

  alias Absinthe.Blueprint
  alias Absinthe.Phase
  alias KilnCMSWeb.SecondFactorGate

  @impl Absinthe.Phase
  @spec run(Blueprint.t(), keyword()) :: Phase.result_t()
  def run(%Blueprint{} = blueprint, options) do
    context = Keyword.get(options, :context, %{})

    if held?(context),
      do: {:replace, refuse(blueprint), [Phase.Document.Result]},
      else: {:ok, blueprint}
  end

  defp held?(%{actor: %KilnCMS.Accounts.User{__metadata__: %{using_api_key?: true}}}), do: false

  defp held?(%{actor: %KilnCMS.Accounts.User{} = user, tenant: org_id}),
    do: SecondFactorGate.bearer_refused?(user, org_id, [])

  defp held?(_anonymous), do: false

  defp refuse(blueprint) do
    error = %Phase.Error{
      phase: __MODULE__,
      message:
        "This site requires two-step sign-in for your account. Set it up in a browser, then sign in again.",
      extra: %{extensions: %{code: "second_factor_required"}}
    }

    put_in(blueprint.execution.validation_errors, [error])
  end
end
