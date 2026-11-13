defmodule KilnCMS.Accounts.Errors.PasskeyLimitReached do
  @moduledoc """
  The account already holds the most passkeys it may (#2247,
  `KilnCMS.Accounts.Passkey.max_per_account/0`).

  Its own type so the settings page can say why, and how to make room (remove
  one), rather than "couldn't verify that passkey". Forbidden-class, like
  `DemoAccountLocked`: no value of any argument would be accepted.
  """
  use Splode.Error, fields: [:max], class: :forbidden

  @impl true
  def message(%{max: max}), do: "this account already has #{max} passkeys — remove one first"
end
