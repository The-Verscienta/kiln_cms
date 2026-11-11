defmodule KilnCMS.Accounts.SignInUnlockAction do
  @moduledoc """
  The run of `User`'s two sign-in unlock actions (#2250),
  `:request_sign_in_unlock` and `:redeem_sign_in_unlock`; the work is
  `KilnCMS.Accounts.SignInUnlock`'s.

  Both are system-only. Their policy is `forbid_if always()`, and because the
  platform-admin bypass on `User` would still pass that, this refuses any call
  that carries an actor as well: an emailed link and an anonymous request are
  the only ways in, and no signed-in caller (an operator included) can mint or
  spend a link through them. `KilnCMSWeb.SignInUnlockController` calls them with
  `authorize?: false` and no actor.

  The org is the one in the action's context
  (`KilnCMS.Security.Recorder.tenant_key/0`), which the controller fills from
  the request host (`KilnCMS.Security.AuthEvents.context/2`), never from input.
  """
  use Ash.Resource.Actions.Implementation

  alias KilnCMS.Accounts.Errors.SignInUnlockRefused
  alias KilnCMS.Accounts.SignInUnlock

  @impl true
  def run(_input, _opts, %{actor: actor}) when not is_nil(actor),
    do: {:error, Ash.Error.Forbidden.exception([])}

  def run(input, opts, _context) do
    case Keyword.fetch!(opts, :step) do
      :request ->
        SignInUnlock.request(to_string(input.arguments.email), input.context)

      :redeem ->
        with {:error, %SignInUnlockRefused{} = refused} <-
               SignInUnlock.redeem(input.arguments.token, input.context),
             do: {:error, refused}
    end
  end
end
