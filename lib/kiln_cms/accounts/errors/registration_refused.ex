defmodule KilnCMS.Accounts.Errors.RegistrationRefused do
  @moduledoc """
  A registration (#2251) that could not be recorded or decided, for a reason
  the caller is told by name.

  `reason` is one of:

    * `:not_pending` — the row is not awaiting this decision: another admin
      (or another tab) decided it first, or it is already active (a rejected
      row may still be approved, but not rejected again);
    * `:unconfirmed` — the applicant has not confirmed their email address, so
      it cannot be approved yet (rejecting it is still allowed);
    * `:erased` — the applicant's account was erased, so there is nobody to
      approve (rejecting it is still allowed);
    * `:rejected_after_invitation` — the registration was rejected after the
      invitation being honoured was sent, so that invitation does not overrule
      the rejection (#2514);
    * `:not_approved` — the account's registration on this site awaits
      approval or was rejected, so a paid membership here is refused;
    * `:settings_unavailable` — the site's registration settings could not be
      read, so the registration was refused rather than let in unreviewed. Worth
      retrying: nothing was created.

  `:invalid`-class, on a field, so `AshPhoenix.Form` and the console's flash
  render it. `reason/1` picks the reason out of an Ash error.
  """
  use Splode.Error, fields: [:field, :reason], class: :invalid

  @impl true
  def message(%{reason: :not_pending}), do: "is no longer awaiting a decision"

  def message(%{reason: :unconfirmed}),
    do: "can't be approved until the applicant confirms their email address"

  def message(%{reason: :erased}),
    do: "can't be approved because the applicant's account was erased"

  def message(%{reason: :rejected_after_invitation}),
    do: "was rejected after this invitation was sent, so the invitation can't approve it"

  def message(%{reason: :not_approved}),
    do: "can't start a membership until the registration on this site is approved"

  def message(%{reason: :settings_unavailable}),
    do: "registration is unavailable for a moment — try again shortly"

  def message(_error), do: "this registration can't be changed"

  @doc "The refusal's reason, if `error` carries one."
  @spec reason(term()) :: atom() | nil
  def reason(%__MODULE__{reason: reason}), do: reason
  def reason(%{errors: [_ | _] = errors}), do: Enum.find_value(errors, &reason/1)
  def reason(errors) when is_list(errors), do: Enum.find_value(errors, &reason/1)
  def reason(_other), do: nil
end
