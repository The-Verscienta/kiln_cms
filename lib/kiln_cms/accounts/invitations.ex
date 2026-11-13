defmodule KilnCMS.Accounts.Invitations do
  @moduledoc """
  Inviting someone to a site by email (#2135): the shared rules behind
  `KilnCMS.Accounts.Invitation` and the two accept paths on
  `KilnCMS.Accounts.User`.

  ## Why a row of its own, and not an account up front

  An invitation names an address, a site and a tier. It is not an account: the
  account is created only when the invitee clicks the link, by
  `User.:register_with_invitation`, so nothing exists for the address until
  then. An unconfirmed, passwordless `User` written at invite time would break
  single sign-on for the invitee (an unconfirmed row cannot be confirmed by an
  identity provider, and site sign-on refuses one), would turn the invitee's
  own self-registration into "check your email" plus a mail saying someone
  tried to register their address, something they never did
  (`KilnCMS.Accounts.Changes.RefuseExistingAddress`,
  `KilnCMS.Accounts.User.Senders.SendRegistrationNotice`, #2255), would be
  mailed "confirm your email" by the confirmation add-on, and would hold a role
  before anyone accepted it.

  ## The token

  32 random bytes, URL-safe base64, mailed once. Only its SHA-256 is stored, so
  a database read cannot reconstruct a link. The token is single use (the row is
  destroyed when it is accepted), a resend rotates it (the old link stops
  working), revoking destroys the row, and a row past `expires_at` is treated as
  if it were not there. An expired row stays until the daily prune removes it,
  `prune_after_days/0` days later, so a late click still gets the same "no
  longer valid" page as a made-up token.

  ## Who may accept what

  The token proves the address. So:

    * no account: the invitee sets a password and gets a confirmed `:viewer`
      account with the invited tier on the invited site;
    * a **confirmed** account: one click adds the membership and changes
      nothing on the account. Already a member of the site at a lower tier,
      the membership is raised to the invited one; at that tier or a higher
      one, nothing changes and the page says so (#2452). Never lowered;
    * an **unconfirmed** account: treated as if there were none. Anyone can
      register an unconfirmed account for any address, so its password is not
      the invitee's: the invitee sets a new one, the account is confirmed,
      every token it held is revoked, and every credential the earlier
      registrant could have added is forgotten
      (`KilnCMS.Accounts.Changes.ForgetPriorCredentials`, #2453: the
      authenticator app and its recovery codes, passkeys, identity-provider
      links, push devices and API keys) before the membership is added.

  An `:admin` invitation is honored only while the admin who sent it is still
  a standing platform admin (`inviter_still_admin?/1`).
  """

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.InvitationRefused
  alias KilnCMS.Accounts.Errors.RegistrationRefused
  alias KilnCMS.Accounts.Invitation
  alias KilnCMS.Accounts.LegacyAffiliation
  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.AfterCommit

  @ttl_days 7
  @prune_after_days 30
  @token_bytes 32

  @doc "How long an invitation stays usable, in days. A resend restarts it."
  @spec ttl_days() :: pos_integer()
  def ttl_days, do: @ttl_days

  @doc "How long past its expiry an invitation row is kept before the prune, in days."
  @spec prune_after_days() :: pos_integer()
  def prune_after_days, do: @prune_after_days

  @doc "A fresh plaintext token, as mailed. Store only `hash/1` of it."
  @spec generate_token() :: String.t()
  def generate_token do
    @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  @doc "The stored form of a token."
  @spec hash(String.t()) :: binary()
  def hash(token) when is_binary(token), do: :crypto.hash(:sha256, token)

  @doc "When an invitation sent now stops working."
  @spec expiry(DateTime.t()) :: DateTime.t()
  def expiry(now \\ DateTime.utc_now()), do: DateTime.add(now, @ttl_days, :day)

  @doc "Whether an invitation can still be accepted."
  @spec live?(Invitation.t()) :: boolean()
  def live?(%Invitation{expires_at: %DateTime{} = at}),
    do: DateTime.compare(at, DateTime.utc_now()) == :gt

  def live?(_other), do: false

  @doc """
  The live invitation a token names, or `nil`. A peek: nothing is consumed.
  Every miss looks the same to the caller — a made-up token, an expired one, a
  revoked or a used one.
  """
  @spec peek(term()) :: Invitation.t() | nil
  def peek(token) when is_binary(token) and token != "" do
    # authorize?: false — the token is the credential being checked; the
    # system-only read refuses any actor-carrying call and returns only a live
    # row whose stored hash matches.
    case Accounts.get_invitation_by_token(token, authorize?: false, not_found_error?: false) do
      {:ok, %Invitation{} = invitation} -> invitation
      _miss -> nil
    end
  end

  def peek(_token), do: nil

  @doc """
  Whether an `:admin` invitation may still be honoured: its sender must still be
  a standing platform admin (not a temporary one, not erased, not deleted).
  Every other tier passes.
  """
  @spec inviter_still_admin?(Invitation.t()) :: boolean()
  def inviter_still_admin?(%Invitation{role: :admin, invited_by_id: nil}), do: false

  def inviter_still_admin?(%Invitation{role: :admin, invited_by_id: id}) do
    # authorize?: false — a system check of the stored inviter, made while a
    # system-only accept runs; it only ever refuses.
    case Accounts.get_user(id, authorize?: false, not_found_error?: false) do
      {:ok, %Accounts.User{role: :admin, anonymized_at: nil}} -> true
      _other -> false
    end
  end

  def inviter_still_admin?(%Invitation{}), do: true

  @doc """
  Give `user` the membership `invitation` names, as a system write, and say
  what happened: `{:ok, %{outcome: outcome, membership: membership}}`, where
  `outcome` is

    * `:joined` — a membership on that site now: a new one, or a registration
      there awaiting approval, or rejected, approved with the invitation's tier
      instead (`OrgMembership.:approve_registration_by_invitation`, #2514): the
      site's admin invited this address, which is the decision the queue was
      waiting for. A rejected one only when the invitation was sent after the
      rejection; otherwise the invitation is refused as no longer valid;
    * `:raised` — an active membership there below the invited tier, raised to
      it (`OrgMembership.:raise_role_by_invitation`, #2452). Its other axes are
      kept, and its custom role becomes the invitation's when it names one;
    * `:already_member` — an active membership there at the invited tier or a
      higher one. Nothing is written: an invitation never lowers anyone.

  `membership` is the row as it now stands, so its `role` is the tier the
  invitee holds there. The tiers compared are standing ones: a live temporary
  grant above the standing tier is not what the invitation is measured against.

  Before an account's first membership on another site, its legacy
  default-site tier is carried onto a membership of its own
  (`KilnCMS.Accounts.LegacyAffiliation`), so accepting never demotes it there.

  `context` is the Ash context to write with (the request's client address, for
  the audit event). Approving a registration or raising a membership evicts the
  invitee's sessions through `KilnCMS.AfterCommit`, so a caller running this
  inside its own transaction must hold that effect until its commit:
  `AfterCommit.deferring/1` around the transaction, or `capture/1` here and
  `replay/1` from its own `after_transaction` hook. Pass `carry_legacy?: false`
  for an account this same transaction just created: it has no legacy tier to
  carry, and carrying would give it a stray `:viewer` membership on the default
  site (the site-SSO admission skips the carry for a new account for the same
  reason).
  """
  @spec grant_membership(Accounts.User.t(), Invitation.t(), map(), keyword()) ::
          {:ok, %{outcome: :joined | :raised | :already_member, membership: OrgMembership.t()}}
          | {:error, term()}
  def grant_membership(user, %Invitation{} = invitation, context \\ %{}, grant_opts \\ []) do
    # authorize?: false — membership writes are a platform-admin action; this is
    # the system honouring an invitation an admin sent, after the token, its
    # expiry and the sender's standing were all checked by the caller.
    opts = [authorize?: false, context: context]

    with {:ok, memberships} <- memberships(user),
         :ok <- maybe_carry(user, memberships, invitation.organization_id, opts, grant_opts) do
      case Enum.find(memberships, &(&1.organization_id == invitation.organization_id)) do
        nil ->
          create(user, invitation, opts)

        %{status: status} = registration when status in [:pending, :rejected] ->
          approve_registration(registration, invitation, context)

        %{status: :active} = membership ->
          raise_role(membership, invitation, context)
      end
    end
  end

  defp create(user, invitation, opts) do
    with {:ok, membership} <-
           Accounts.create_org_membership(
             %{
               user_id: user.id,
               organization_id: invitation.organization_id,
               role: invitation.role,
               role_id: invitation.role_id
             },
             opts
           ),
         do: joined(membership)
  end

  defp joined(membership), do: {:ok, %{outcome: :joined, membership: membership}}

  # As the invitations system actor, the one actor the action admits.
  #
  # A row another writer approved between the read above and the lock is a
  # membership now, so it is judged as one: raised when below the invited
  # tier, left alone otherwise (`settle/3`). Every other refusal (a
  # rejection newer than the invitation, an unconfirmed or erased applicant)
  # reads as an invitation that is no longer valid, so the accept page says
  # what it says for any other. `rollback_on_error?: false` hands the refusal
  # back here rather than aborting the accept's transaction with it; the
  # caller still rolls back on an error returned.
  #
  # `AfterCommit.context/0`: the action's one after-commit effect, the
  # eviction, goes through `AfterCommit.run/1`, which the callers hold until
  # their own commit (see the doc above).
  defp approve_registration(registration, invitation, context) do
    case Accounts.approve_registration_by_invitation(
           registration,
           %{
             role: invitation.role,
             role_id: invitation.role_id,
             invited_at: invitation.last_sent_at || invitation.inserted_at,
             via: :invitation
           },
           system_write_opts(context)
         ) do
      {:ok, membership} ->
        joined(membership)

      {:error, error} ->
        case RegistrationRefused.reason(error) do
          :not_pending -> settle(registration, invitation, context)
          nil -> {:error, error}
          _refused -> invalid()
        end
    end
  end

  # An active membership below the invited tier is raised to it; one at the
  # tier or above is left as it is. The comparison is the action's, made on
  # the row it has locked, not on `membership` as read above: a site admin may
  # have changed the tier since. Refused as `:not_higher`, the row is read
  # again for the tier it holds, under the lock the action took (inside the
  # caller's transaction).
  defp raise_role(membership, invitation, context) do
    case Accounts.raise_membership_role_by_invitation(
           membership,
           %{role: invitation.role, role_id: invitation.role_id},
           system_write_opts(context)
         ) do
      {:ok, raised} ->
        {:ok, %{outcome: :raised, membership: raised}}

      {:error, error} ->
        case InvitationRefused.reason(error) do
          :not_higher -> already_member(membership)
          :invalid -> invalid()
          _other -> {:error, error}
        end
    end
  end

  # A registration decided by someone else between the read and the lock: an
  # active row now is judged as any active membership, once (no loop: the
  # raise refuses anything but an active row as no longer valid); anything
  # else (rejected meanwhile) leaves the invitation no longer valid.
  defp settle(registration, invitation, context) do
    case reread(registration) do
      {:ok, %{status: :active} = membership} -> raise_role(membership, invitation, context)
      {:ok, _not_active} -> invalid()
      {:error, error} -> {:error, error}
    end
  end

  defp already_member(membership) do
    case reread(membership) do
      {:ok, %{status: :active} = current} ->
        {:ok, %{outcome: :already_member, membership: current}}

      {:ok, _not_active} ->
        invalid()

      {:error, error} ->
        {:error, error}
    end
  end

  defp reread(membership) do
    # authorize?: false — a system re-read of the invitee's own row on the
    # invited site, to report the tier it holds; nothing else is returned.
    Accounts.get_org_membership(membership.user_id, membership.organization_id, authorize?: false)
  end

  defp system_write_opts(context),
    do: [
      actor: KilnCMS.SystemActor.new(:invitations),
      context: Map.merge(context, AfterCommit.context()),
      rollback_on_error?: false
    ]

  defp invalid, do: {:error, InvitationRefused.exception(field: :token, reason: :invalid)}

  defp maybe_carry(user, memberships, org_id, opts, grant_opts) do
    if Keyword.get(grant_opts, :carry_legacy?, true),
      do: carry_legacy_tier(user, memberships, org_id, opts),
      else: :ok
  end

  defp memberships(user) do
    # authorize?: false — a system read of the account's own memberships, to
    # decide whether its legacy tier must be carried first; nothing is returned
    # to a caller.
    Accounts.list_memberships_for_user(user.id, authorize?: false)
  end

  @doc """
  Before `user`'s first membership on `org_id`, carry its legacy default-site
  tier onto a membership of its own (`LegacyAffiliation.ensure_default_membership/2`),
  written with `opts`. `memberships` is every membership it holds now. On the
  default site the membership about to be written IS that first one, at the
  tier the admin chose, so only another site needs the carry.
  """
  @spec carry_legacy_tier(map(), list(), Ash.UUID.t(), keyword()) :: :ok | {:error, term()}
  def carry_legacy_tier(user, memberships, org_id, opts) do
    if LegacyAffiliation.unaffiliated?(memberships) and org_id != Accounts.default_org_id() do
      with {:ok, _carried} <- LegacyAffiliation.ensure_default_membership(user, opts), do: :ok
    else
      :ok
    end
  end
end
