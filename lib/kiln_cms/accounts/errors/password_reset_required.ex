defmodule KilnCMS.Accounts.Errors.PasswordResetRequired do
  @moduledoc """
  A password sign-in was refused because the password appears in a known
  breach and a site the account administers blocks breached passwords at
  sign-in (#2407, `KilnCMS.Accounts.Preparations.CheckBreachedPasswordAtSignIn`).

  The password was right, so this is not the `AuthenticationFailed` a wrong
  one produces: that would read as "incorrect email or password" to someone
  who typed the correct one, and `KilnCMS.Accounts.Preparations.ThrottleSignIn`
  would count it as a guess. An `:invalid`-class error on the
  `:password_reset` field, which no input renders: each door reads it and
  sends the person to choose a new password (the sign-in form to `/reset`
  with a flash, the direct POST likewise, the API a `403
  password_reset_required`).

  `org_ids` are the orgs whose policy refused the sign-in, for the audit log
  alone (`KilnCMS.Security.Preparations.AuditSignIn`). The message names
  nothing: no account, no org, no password.
  """
  use Splode.Error, fields: [org_ids: [], field: :password_reset], class: :invalid

  @type t :: %__MODULE__{}

  @impl true
  def message(_error), do: "the password must be reset before signing in"

  @doc """
  The `PasswordResetRequired` inside `reason` (an Ash error class, a form's
  source, an `AuthenticationFailed` wrapping it in `caused_by`, or a bare
  error), or `nil`.
  """
  @spec find(term()) :: t() | nil
  def find(%__MODULE__{} = error), do: error
  def find(%{errors: [_ | _] = errors}), do: Enum.find_value(errors, &find/1)
  def find(%{caused_by: caused_by}) when is_map(caused_by), do: find(caused_by)
  def find(_other), do: nil

  defimpl AshPhoenix.FormData.Error do
    # Its own field, which no input renders: the sign-in form navigates to
    # `/reset` instead of drawing an error under the password box.
    def to_form_error(error), do: [{:password_reset, Exception.message(error), []}]
  end
end
