defmodule KilnCMS.Accounts.Errors.SecondFactorThrottled do
  @moduledoc """
  The account's second-factor budget is spent (#714, #727).

  Its own error type rather than a generic invalid-argument, because the caller
  has to be able to tell it apart from a wrong code. They are opposite messages:
  *"that code isn't valid"* tells a user to look at their authenticator again,
  and telling them that when the real answer is *"stop for a few minutes"* sends
  them to type five more wrong codes into a spent budget. The refusal also
  carries how long the wait is, which no generic error has room for.

  Distinguishing them costs nothing here. Unlike the sign-in gate — where a
  refusal must be indistinguishable from a wrong password, or it becomes an
  account-existence oracle — whoever is at these actions is already signed in as
  this account. There is nothing left to disclose.
  """
  use Splode.Error, fields: [:retry_after_seconds], class: :invalid

  @impl true
  def message(%{retry_after_seconds: seconds}) do
    "too many attempts — try again in #{seconds} seconds"
  end
end
