defmodule KilnCMS.Accounts.Validations.RegistrationEnabled do
  @moduledoc """
  Rejects self-registration when open registration is turned off (invite-only
  mode): `config :kiln_cms, :registration_enabled, false`.

  Enforced on the registration action itself, so it blocks both the `/register`
  UI and a direct POST to the password-strategy register endpoint — not just the
  link on the sign-in page.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def validate(_changeset, _opts, _context) do
    if Application.get_env(:kiln_cms, :registration_enabled, true) do
      :ok
    else
      {:error,
       InvalidAttribute.exception(
         field: :email,
         message: "self-registration is disabled"
       )}
    end
  end
end
