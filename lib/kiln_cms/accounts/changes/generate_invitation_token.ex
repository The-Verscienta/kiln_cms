defmodule KilnCMS.Accounts.Changes.GenerateInvitationToken do
  @moduledoc """
  Mints the token an invitation (#2135) is accepted with, on `:invite` and on
  `:resend`, and restarts the invitation's clock.

  Stores only the token's SHA-256 (`KilnCMS.Accounts.Invitations.hash/1`). The
  plaintext rides in the changeset context for the mail
  (`KilnCMS.Accounts.Changes.SendInvitation`) and comes back once as the
  record's `__metadata__.token`; nothing else ever holds it. A resend replaces
  the hash, so the link mailed before stops working.

  Also stamps who sent it (`invited_by_id`, the acting user), when
  (`last_sent_at`) and how often (`sent_count`). The sender matters later: an
  `:admin` invitation is honoured only while its sender is still a standing
  admin (`KilnCMS.Accounts.Invitations.inviter_still_admin?/1`).
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.Invitations
  alias KilnCMS.Accounts.User

  @context_key :invitation_token

  @doc "The changeset-context key the plaintext token rides under."
  @spec context_key() :: atom()
  def context_key, do: @context_key

  @impl true
  def change(changeset, _opts, context) do
    token = Invitations.generate_token()
    now = DateTime.utc_now()

    sent_count =
      case changeset.action.type do
        :create -> 1
        _update -> (changeset.data.sent_count || 0) + 1
      end

    changeset
    |> Ash.Changeset.force_change_attribute(:token_hash, Invitations.hash(token))
    |> Ash.Changeset.force_change_attribute(:expires_at, Invitations.expiry(now))
    |> Ash.Changeset.force_change_attribute(:last_sent_at, now)
    |> Ash.Changeset.force_change_attribute(:sent_count, sent_count)
    |> put_inviter(context.actor)
    |> Ash.Changeset.set_context(%{@context_key => token})
    |> Ash.Changeset.after_action(fn _changeset, invitation ->
      {:ok, Ash.Resource.put_metadata(invitation, :token, token)}
    end)
  end

  defp put_inviter(changeset, %User{id: id}),
    do: Ash.Changeset.force_change_attribute(changeset, :invited_by_id, id)

  defp put_inviter(changeset, _system), do: changeset
end
