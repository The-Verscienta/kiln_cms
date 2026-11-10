defmodule KilnCMS.Accounts.Errors.AccountTakenOver do
  @moduledoc """
  A write refused because the account changed hands while the request was in
  flight (#2453): an invitation took over the unconfirmed account the request
  was acting as, setting a new password and forgetting every credential, after
  the request loaded the account (`KilnCMS.Accounts.Changes.GuardAccountTakeover`).

  Also raised when a staged two-step verification secret was replaced or
  cleared after `:confirm_totp` read it.

  `:invalid`-class, on the field that names the account.
  """
  use Splode.Error, fields: [:field], class: :invalid

  @impl true
  def message(_error), do: "belongs to an account that changed since this request began"
end
