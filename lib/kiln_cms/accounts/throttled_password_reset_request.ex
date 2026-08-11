defmodule KilnCMS.Accounts.ThrottledPasswordResetRequest do
  @moduledoc """
  Bounds `:request_password_reset_token` per client address, then delegates
  (#724).

  A **generic** action, unlike the other three credential forms — it has a `run`
  rather than a changeset or a query, so it takes no `change` or `prepare` hook
  to charge from. Wrapping the run is the only seam there is, which is why this
  is a module of its own rather than a fourth sibling in `changes/` or
  `preparations/`.

  There is no build-per-keystroke hazard here for the same reason: a generic
  action's `run` executes once, when the action does. The problem
  `KilnCMS.Accounts.ClientIpBudget` documents for the other three does not
  arise, and nothing needs deferring.

  Charges `:auth`, alongside the magic-link request, for the reason
  `KilnCMS.Accounts.Preparations.ThrottleMagicLink` gives. The per-address mail
  budget (`AccountThrottle.allow_mail?/2`, five per hour) still bounds what
  actually leaves the building; this bounds the requests that reach it.
  """
  use Ash.Resource.Actions.Implementation

  alias KilnCMS.Accounts.ClientIpBudget

  @delegate AshAuthentication.Strategy.Password.RequestPasswordReset

  @impl true
  def run(input, opts, context) do
    case ClientIpBudget.check(input.context, :auth) do
      :allow ->
        @delegate.run(input, opts, context)

      {:deny, _retry_after} ->
        # Returned as an error rather than `:ok` so a caller *can* tell, though
        # the shipped one does not: `AshAuthentication.Phoenix`'s `ResetForm`
        # discards the result and renders its "you will be contacted shortly"
        # flash either way. That is the component's decision, not this module's,
        # and answering `:ok` here would remove the option from any caller that
        # wanted to make a different one.
        #
        # Nothing is disclosed by it. The indistinguishability this endpoint
        # protects is between a *known* and an *unknown* address; a throttle
        # says nothing about any address, only that the caller's own IP is out
        # of budget, which they know because they sent the traffic.
        {:error, ClientIpBudget.refusal(__MODULE__, :request_password_reset_token)}
    end
  end
end
