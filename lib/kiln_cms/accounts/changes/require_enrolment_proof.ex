defmodule KilnCMS.Accounts.Changes.RequireEnrolmentProof do
  @moduledoc """
  Refuses adding a second factor without the email proof the site requires
  (#2247, owner decision 1b; `KilnCMS.Accounts.EnrolmentProof`), on `User`'s
  `:confirm_totp` and `Passkey`'s `:register`.

  The page that offers the proof step (`KilnCMSWeb.TwoFactorSetupLive`) and the
  settings page put the site, the session and the proof in the action's
  context under `:second_factor_enrolment` (`EnrolmentProof.context/3`). This
  decides again from those, so a page that skipped its proof step, or a forged
  event, cannot add a factor the site says needs one.

  ## Without that context, it fails closed

  An enrolment that arrives without the context does not say which site or
  which session it came from, so it is judged as the weakest case: a password
  session with no proof, on every site the account belongs to
  (`TwoFactorRequirement.enforced_somewhere?/1`). An account no site holds is
  unaffected; one that is held anywhere is refused.

  A caller that adds a factor with no person's session behind it, and has a
  reason the proof does not apply, says so explicitly with
  `context: %{second_factor_enrolment: :system}`. Nothing in the app does
  today.

  ## The `proof` metadata

  On success the label the event records — `"email"`,
  `"email_skipped_no_relay"`, `"not_required"` or `"magic_link_session"` — is
  left in the context under `:enrolment_proof`, where the `Record` change on
  each action reads it (`metadata/2`). None with the system marker or without
  the context.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.EnrolmentProof
  alias KilnCMS.Accounts.Errors.EnrolmentProofRequired
  alias KilnCMS.Accounts.TwoFactorRequirement

  @context_key :second_factor_enrolment
  @label_key :enrolment_proof

  @impl true
  def change(changeset, _opts, context) do
    case Map.get(changeset.context, @context_key) do
      :system ->
        changeset

      enrolment ->
        case enrolling_user(changeset, context) do
          # No stored account (a changeset built over a bare struct, as an
          # authorization check does): nothing to judge, and the action
          # cannot run against it anyway.
          %Accounts.User{id: id} = user when is_binary(id) -> judge(changeset, user, enrolment)
          _none -> changeset
        end
    end
  end

  defp judge(changeset, user, %{} = enrolment) do
    case EnrolmentProof.accept(user, enrolment[:org_id], enrolment[:session], enrolment[:proof]) do
      {:ok, label} -> Ash.Changeset.put_context(changeset, @label_key, label)
      {:error, :proof_required} -> refuse(changeset)
    end
  end

  defp judge(changeset, user, _absent) do
    if TwoFactorRequirement.enforced_somewhere?(user),
      do: refuse(changeset),
      else: changeset
  end

  @doc """
  `metadata` with the `proof` label this change left on `changeset`, when it
  left one. For the `Record` change's `metadata:` function.
  """
  @spec metadata(Ash.Changeset.t(), map()) :: map()
  def metadata(changeset, metadata) do
    case Map.get(changeset.context, @label_key) do
      label when is_binary(label) -> Map.put(metadata, "proof", label)
      _none -> metadata
    end
  end

  defp refuse(changeset),
    do: Ash.Changeset.add_error(changeset, EnrolmentProofRequired.exception([]))

  # The account the factor is for: the row `:confirm_totp` updates, or the
  # account a passkey is registered to. `nil` when there is none to read; the
  # action fails on its own then.
  defp enrolling_user(%{resource: Accounts.User} = changeset, _context), do: changeset.data

  defp enrolling_user(changeset, context) do
    case {Ash.Changeset.get_attribute(changeset, :user_id), context.actor} do
      {nil, _actor} -> nil
      {user_id, %Accounts.User{id: user_id} = actor} -> actor
      {user_id, _other} -> read_user(user_id)
    end
  end

  defp read_user(user_id) do
    # authorize?: false — reads the account a passkey is being registered to,
    # only to decide whether its site requires the proof; nothing read here
    # leaves this change. The registration's own authorization is the
    # ceremony's (see `Passkey`'s policies).
    case Accounts.get_user(user_id, authorize?: false, not_found_error?: false) do
      {:ok, %Accounts.User{} = user} -> user
      _missing -> nil
    end
  end
end
