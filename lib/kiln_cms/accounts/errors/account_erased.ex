defmodule KilnCMS.Accounts.Errors.AccountErased do
  @moduledoc """
  A write refused because the account it would attach to was erased (#2514):
  a membership, a paid membership, an API key, or a confirmation, reaching the
  account after a rejected registration's erasure committed
  (`KilnCMS.Accounts.AccountLock`); a site tier, temporary tier or
  audience given to any erased account's membership (#2774); or a platform
  tier, temporary tier or audience given to an erased account itself
  (`User.:manage_access`, `User.:grant_temporary_role`, #3010).

  `:invalid`-class, on the field that names the account.
  """
  use Splode.Error, fields: [:field], class: :invalid

  @impl true
  def message(_error), do: "belongs to an account that was erased"
end
