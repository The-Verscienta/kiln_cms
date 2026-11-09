defmodule KilnCMS.Accounts.Errors.ChallengeRequired do
  @moduledoc """
  A password sign-in or a registration was refused because it needed a
  human-verification challenge it did not pass (#2249).

  `reason` says which of three things happened, because each door answers them
  differently:

    * `:required` — a challenge was needed and no token came with the attempt.
      The form shows the widget; the API answers `challenge_required`.
    * `:failed` — a token came and the provider refused it (wrong, expired,
      already used, for another host or action). The form resets the widget;
      the API answers `challenge_failed`.
    * `:unavailable` — the provider could not be asked, and this attempt is
      past the point where an outage still admits it (see
      `KilnCMS.Challenge.Gate`). The API answers `503 challenge_unavailable`.

  An `:invalid`-class error on the `:challenge_token` field, not the
  `AuthenticationFailed` a wrong password produces. The refusal says nothing
  about the account: whether a challenge is needed is decided from counters
  keyed on the *submitted* address and on the caller's own client address, so a
  known and an unknown address are refused alike. And it must not read as a
  wrong password, or a user would retype a correct one into a form that is
  asking for something else.
  """
  use Splode.Error, fields: [:reason, field: :challenge_token], class: :invalid

  @type reason :: :required | :failed | :unavailable
  @type t :: %__MODULE__{}

  @impl true
  def message(%{reason: :failed}), do: "the human-verification check did not pass"
  def message(%{reason: :unavailable}), do: "the human-verification check is unavailable"
  def message(_error), do: "a human-verification check is required"

  @doc """
  The `ChallengeRequired` inside `reason` — an Ash error class, a form's source,
  an `AuthenticationFailed` from `AshAuthentication.Strategy.action/4` (which
  wraps the action's error in `caused_by`), or a bare error — or `nil`.
  """
  @spec find(term()) :: t() | nil
  def find(%__MODULE__{} = error), do: error
  def find(%{errors: [_ | _] = errors}), do: Enum.find_value(errors, &find/1)
  def find(%{caused_by: caused_by}) when is_map(caused_by), do: find(caused_by)
  def find(_other), do: nil

  defimpl AshPhoenix.FormData.Error do
    # Attached to its own field, which no input renders: the sign-in and
    # registration forms read the reason from the raw error and draw the widget
    # and its message themselves (`KilnCMSWeb.ChallengeComponents`).
    def to_form_error(error), do: [{:challenge_token, Exception.message(error), []}]
  end
end
