defmodule KilnCMS.Accounts.Errors.DemoAccountLocked do
  @moduledoc """
  A self-service credential change refused because demo mode is on
  (`docs/demo-mode.md`).

  On a demo every visitor signs in as the same shared account, so its password
  and sign-in methods belong to everyone at once: one visitor changing the
  password, or turning on two-factor with an authenticator only they hold,
  locks every other visitor out until the next reset.
  `KilnCMS.Accounts.Validations.NotDemoSharedAccount` refuses those actions for
  a non-admin actor with this error.

  Forbidden-class, because it is a refusal and not a correction the caller can
  make: no value of any argument would be accepted. Its own type, so the
  settings page can say *why* rather than "check your current password".
  """
  use Splode.Error, fields: [], class: :forbidden

  @impl true
  def message(_error) do
    "this is a shared demo account — its password and sign-in methods can't be changed"
  end
end
