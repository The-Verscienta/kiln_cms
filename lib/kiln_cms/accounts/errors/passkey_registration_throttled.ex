defmodule KilnCMS.Accounts.Errors.PasskeyRegistrationThrottled do
  @moduledoc """
  The account's passkey-registration budget is spent (#2247,
  `KilnCMS.Accounts.AccountThrottle.consume_passkey_registration/1`).

  Carries the wait, like `SecondFactorThrottled`, and for the same reason it may:
  whoever reaches the registration ceremony is already signed in as this
  account, so the refusal discloses nothing they don't know.
  """
  use Splode.Error, fields: [:retry_after_seconds], class: :invalid

  @impl true
  def message(%{retry_after_seconds: seconds}) do
    "too many passkeys added — try again in #{seconds} seconds"
  end
end
