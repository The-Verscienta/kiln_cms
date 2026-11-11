defmodule KilnCMS.Accounts.Errors.ErasureRefused do
  @moduledoc """
  An erasure by the registrations system actor refused by
  `KilnCMS.Accounts.Changes.GuardRegistrationErasure` (#2514): it was not the
  erasure of a registration this transaction has just rejected, or the account
  is more than that registration.

  Forbidden-class: no argument would make it acceptable. The account is
  untouched.
  """
  use Splode.Error, fields: [], class: :forbidden

  @impl true
  def message(_error),
    do: "only an account a rejection in this transaction may erase can be erased this way"
end
