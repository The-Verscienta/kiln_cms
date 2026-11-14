defmodule KilnCMS.Accounts.Errors.LastSecondFactorRequired do
  @moduledoc """
  The account's last second factor can't be removed: a site it uses requires
  one (#2247, `KilnCMS.Accounts.Validations.KeepsRequiredSecondFactor`).

  Forbidden-class, like `DemoAccountLocked`: no argument would be accepted
  while the requirement stands. Its own type, so the settings page can say why
  and what still works (adding another factor first, or replacing the app).
  """
  use Splode.Error, fields: [], class: :forbidden

  @impl true
  def message(_error) do
    "a site this account uses requires a second factor — add another before removing this one"
  end
end
