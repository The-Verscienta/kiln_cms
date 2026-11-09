defmodule KilnCMS.Accounts.Errors.SignInUnlockRefused do
  @moduledoc """
  A sign-in unlock link (#2250) that was not redeemed.

  `reason` is one of `:invalid` (made up, malformed, or not minted as an unlock
  link), `:expired`, `:used` (already redeemed, or revoked by a password change
  or reset), `:wrong_site` (minted for another site; not spent, so it still
  works on its own site) or `:account_changed` (the address changed, or the
  account was erased). The page that redeems shows one message for all of them;
  the reason goes to the security log.
  """
  use Splode.Error, fields: [:reason], class: :invalid

  @type t :: %__MODULE__{}

  @impl true
  def message(_error), do: "this unlock link is no longer valid"

  @doc "The refusal's reason, if `error` (an Ash error class, a list or a bare error) carries one."
  @spec reason(term()) :: atom() | nil
  def reason(%__MODULE__{reason: reason}), do: reason
  def reason(%{errors: [_ | _] = errors}), do: Enum.find_value(errors, &reason/1)
  def reason(errors) when is_list(errors), do: Enum.find_value(errors, &reason/1)
  def reason(_other), do: nil
end
