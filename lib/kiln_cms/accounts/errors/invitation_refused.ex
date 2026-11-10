defmodule KilnCMS.Accounts.Errors.InvitationRefused do
  @moduledoc """
  An invitation (#2135) that could not be sent, or could not be accepted, for a
  reason the caller is told by name.

  `reason` is one of:

    * `:already_member` — the address already belongs to someone on this site;
    * `:already_invited` — a live invitation for the address is pending here;
    * `:suppressed` — the address hard-bounced and is on a suppression list, so
      no mail would go out;
    * `:mail_budget` — the address has been sent too many invitations within
      the per-address mail window;
    * `:invalid` — the token is made up, expired, revoked or used, or the
      invitation no longer stands. One reason for all of them, so the accept
      page cannot tell them apart;
    * `:not_higher` — the invitee's membership on the site already holds the
      invited tier or a higher one, so accepting raises nothing
      (`OrgMembership.:raise_role_by_invitation`, #2452). Never shown as an
      error: `KilnCMS.Accounts.Invitations.grant_membership/4` reads it as
      "already a member".

  `:invalid`-class, on a field, so `AshPhoenix.Form` and the console's flash
  render it. `in?/2` lets a caller pick out one reason.
  """
  use Splode.Error, fields: [:field, :reason], class: :invalid

  @impl true
  def message(%{reason: :already_member}), do: "is already a member of this site"

  def message(%{reason: :already_invited}),
    do: "already has a pending invitation to this site — resend it instead"

  def message(%{reason: :suppressed}),
    do: "is on the mail suppression list, so the invitation would not be delivered"

  def message(%{reason: :mail_budget}),
    do: "has been sent too many invitations in the last hour — try again later"

  def message(%{reason: :not_higher}),
    do: "already holds this tier or a higher one on this site"

  def message(_error), do: "this invitation is no longer valid"

  @doc "Whether `error` (an Ash error class, a list or a bare error) carries this refusal with `reason`."
  @spec in?(term(), atom()) :: boolean()
  def in?(%__MODULE__{reason: reason}, reason), do: true
  def in?(%{errors: [_ | _] = errors}, reason), do: Enum.any?(errors, &in?(&1, reason))
  def in?(errors, reason) when is_list(errors), do: Enum.any?(errors, &in?(&1, reason))
  def in?(_other, _reason), do: false

  @doc "The refusal's reason, if `error` carries one."
  @spec reason(term()) :: atom() | nil
  def reason(%__MODULE__{reason: reason}), do: reason
  def reason(%{errors: [_ | _] = errors}), do: Enum.find_value(errors, &reason/1)
  def reason(errors) when is_list(errors), do: Enum.find_value(errors, &reason/1)
  def reason(_other), do: nil
end
