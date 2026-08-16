defmodule KilnCMS.Accounts.Verifiers.SecondFactorHoldContract do
  @moduledoc """
  Compile-time pin for the two `AshAuthentication` token settings the #742
  hold means nothing without (#1172).

  `KilnCMS.Accounts.PendingSignIn` parks a first-factor token by moving its
  stored row off the `"user"` purpose. That is only a defence because
  `AshAuthentication.Plug.Helpers.validate_token/3` looks the row up under
  exactly that purpose — and it only *looks* when the resource sets
  `require_token_presence_for_authentication?`, and there is only a row to
  move when it sets `store_all_tokens?`. Both are one-line changes in
  `KilnCMS.Accounts.User` that would leave every existing test green while
  turning the hold into a no-op: the JWT would authenticate on its signature
  alone, whatever purpose its row carries.

  This verifier turns each of those into a compile error with the reason in
  it. It runs from `KilnCMS.Accounts.SecondFactorHoldExtension`, which `User`
  lists in its `extensions:`; the third setting it pins — that the token
  resource is `KilnCMS.Accounts.Token` — is what makes the hold and release
  actions reachable at all.

  What it cannot pin is the *dep's* filter itself: a future AshAuthentication
  that accepted a held purpose would pass this and fail only at runtime. That
  half is `test/kiln_cms/accounts/second_factor_hold_contract_test.exs`, which
  drives a held token through the dep's own bearer/session round trip.
  """

  use Spark.Dsl.Verifier

  alias AshAuthentication.Info
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @token_resource KilnCMS.Accounts.Token

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    with :ok <- require_true(dsl_state, module, :require_token_presence_for_authentication?),
         :ok <- require_true(dsl_state, module, :store_all_tokens?) do
      require_token_resource(dsl_state, module)
    end
  end

  defp require_true(dsl_state, module, key) do
    if setting(dsl_state, key) == true do
      :ok
    else
      {:error,
       DslError.exception(
         module: module,
         path: [:authentication, :tokens, key],
         message: """
         `#{key}` must be `true` on #{inspect(module)}.

         The two-factor hold (#742) parks a first-factor token by moving its stored
         row off the "user" purpose. Without `require_token_presence_for_authentication?`
         nothing looks that row up, and without `store_all_tokens?` there is no row
         to move — either way the JWT authenticates on its signature alone and the
         hold silently stops meaning anything (#1172).
         """
       )}
    end
  end

  defp require_token_resource(dsl_state, module) do
    case Info.authentication_tokens_token_resource(dsl_state) do
      {:ok, @token_resource} ->
        :ok

      other ->
        {:error,
         DslError.exception(
           module: module,
           path: [:authentication, :tokens, :token_resource],
           message: """
           `token_resource` must be #{inspect(@token_resource)} on #{inspect(module)}, \
           got #{inspect(other)}.

           The two-factor hold's `:hold_for_second_factor` / `:release_second_factor_hold`
           actions live on that resource (#742, #1172); pointing tokens elsewhere would
           store first-factor tokens where the hold cannot reach them.
           """
         )}
    end
  end

  defp setting(dsl_state, :require_token_presence_for_authentication?),
    do: Info.authentication_tokens_require_token_presence_for_authentication?(dsl_state)

  defp setting(dsl_state, :store_all_tokens?),
    do: Info.authentication_tokens_store_all_tokens?(dsl_state)
end
