defmodule KilnCMS.Accounts.Errors.AlreadyRegistered do
  @moduledoc """
  A registration named an address that already has an account (#2255).

  Never meant to reach a person. `:register_with_password` raises it so that no
  row is created and nothing is signed in; the two doors that call the action
  (`KilnCMSWeb.AuthRegisterForm` and `KilnCMSWeb.AuthController`) recognise it
  with `in?/1` and answer exactly as they answer a successful registration. If it
  were shown, "that address is taken" would be the very oracle this exists to
  close.
  """
  use Splode.Error, fields: [:field], class: :invalid

  @impl true
  def message(_error), do: "an account with this address already exists"

  @doc """
  Whether `reason` — an Ash error class, a form's errors, or a bare error — is
  a refusal because the address already has an account.

  Only that refusal counts: an error list that also carries a real validation
  failure (a short password) is shown as usual, and it says the same of a known
  and an unknown address, since validation never looks the address up.
  """
  @spec in?(term()) :: boolean()
  def in?(%{errors: [_ | _] = errors}), do: Enum.any?(errors, &in?/1)
  def in?(%__MODULE__{}), do: true
  def in?(_other), do: false
end
