defmodule KilnCMS.Accounts.ThrottledMagicLinkRequest do
  @moduledoc """
  Bounds `:request_magic_link` per client address, then delegates (#724).

  Softer than registration — `KilnCMS.Accounts.AccountThrottle.allow_mail?/2`
  already caps outbound mail at five per address per hour, so the mailbomb is
  bounded whatever happens here. What was uncapped is the **request rate**: each
  one is a database read and, for an address that exists, a token mint, from a
  `/live` event that passes no pipeline.

  Shares the `:auth` bucket rather than taking one of its own, because this form
  sits on the sign-in page and is the same flow to the same person — and because
  `docs/threat-model.md` has always listed `/reset` and `/register` under
  `:auth`, which after #715 was true only of their GETs. This makes the row
  honest again for the magic-link and reset submits.

  A `run` wrapper since AshAuthentication 5.0, which made the magic-link request
  a **generic** action (it was a read with a preparation before). The shape is
  `KilnCMS.Accounts.ThrottledPasswordResetRequest`'s, for the reasons that module
  gives: a generic action's `run` executes once, when the action does, so the
  charge sits in front of the delegate and nothing needs deferring.
  """
  use Ash.Resource.Actions.Implementation

  alias KilnCMS.Accounts.ClientIpBudget

  @delegate AshAuthentication.Strategy.MagicLink.Request

  @impl true
  def run(input, opts, context) do
    case ClientIpBudget.check(input.context, :auth) do
      :allow ->
        @delegate.run(input, opts, context)

      # An error rather than `:ok`, for the reason
      # `KilnCMS.Accounts.ThrottledPasswordResetRequest` gives: a throttle says
      # nothing about any address, only that the caller's own IP is out of
      # budget.
      {:deny, _retry_after} ->
        {:error, ClientIpBudget.refusal(__MODULE__, :request_magic_link)}
    end
  end
end
