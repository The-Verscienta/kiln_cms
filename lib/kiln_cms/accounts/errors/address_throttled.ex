defmodule KilnCMS.Accounts.Errors.AddressThrottled do
  @moduledoc """
  Too many requests from this client address (#724).

  Its own `:invalid`-class error rather than the `AuthenticationFailed` the
  sign-in refusal uses, and the reason is what each form can safely say.

  A refused **sign-in** must be indistinguishable from a wrong password, or the
  refusal becomes an oracle for which accounts are currently throttled. A
  refused **registration** has no such secret to keep: it says nothing about any
  account, only that the caller's own address is out of budget — which the
  caller knows, because they sent the traffic.

  It matters because `AuthenticationFailed` is a *forbidden*-class Splode error,
  which `AshPhoenix.Form` surfaces as no field error at all. A throttled
  registration therefore rendered a page with no message: the Register button
  appeared to do nothing, indistinguishable from a broken page. An
  `:invalid`-class error on a field renders.
  """
  use Splode.Error, fields: [:field], class: :invalid

  @impl true
  def message(_error), do: "too many requests from this address — try again shortly"
end
