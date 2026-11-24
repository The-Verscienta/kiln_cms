defmodule KilnCMS.Billing.Errors.StillBilled do
  @moduledoc """
  A comp refused because the membership may still be billed by the payment
  provider (#3156): the row is `:active`, `:past_due` or `:incomplete` and
  holds a provider subscription id (`KilnCMS.Billing.Changes.RefuseBilledComp`).

  A comped row ignores every provider event, so comping over a live
  subscription would leave the provider charging a member whose later
  cancellation or payment failure never reaches the row. The operator cancels
  the subscription at the provider first and comps once the cancellation has
  arrived.

  `:invalid`-class, on `:status`.
  """
  use Splode.Error, fields: [:field], class: :invalid

  @impl true
  def message(_error) do
    "is still billed by the payment provider; cancel the subscription at the provider " <>
      "(immediately, not at period end) and wait for the cancellation to arrive, then comp"
  end
end
