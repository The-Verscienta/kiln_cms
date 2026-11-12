defmodule KilnCMS.Accounts.Errors.AlreadyConfirmed do
  @moduledoc """
  A magic-link takeover refused because the account was confirmed (or is gone)
  by the time its row was locked (#2594, `Changes.ClaimUnconfirmedAccount`).

  Not a failure of the sign-in: `Preparations.ClaimUnconfirmedAccount` takes it
  as "the account is no longer up for takeover" and signs in as usual.

  `:invalid`-class.
  """
  use Splode.Error, fields: [:field], class: :invalid

  @impl true
  def message(_error), do: "is no longer an unconfirmed account"
end
