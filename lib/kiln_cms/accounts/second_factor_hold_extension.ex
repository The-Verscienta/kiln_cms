defmodule KilnCMS.Accounts.SecondFactorHoldExtension do
  @moduledoc """
  A DSL extension with no sections and one verifier — a place to hang
  `KilnCMS.Accounts.Verifiers.SecondFactorHoldContract` off
  `KilnCMS.Accounts.User` (#1172).

  Listed after `AshAuthentication` in `User`'s `extensions:` so the
  `authentication.tokens` section it inspects has been built by the time it
  runs. Verifiers run after every transformer, so the order only matters for
  reading the option values, and it does no writing.
  """

  use Spark.Dsl.Extension,
    verifiers: [KilnCMS.Accounts.Verifiers.SecondFactorHoldContract]
end
