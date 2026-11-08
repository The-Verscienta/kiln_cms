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
  identity provider, and site sign-on refuses one), would answer the
  self-registration form as "already taken", would be mailed "confirm your
  email" by the confirmation add-on, and would hold a role before anyone
  accepted it.

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
      nothing on the account;
    * an **unconfirmed** account: treated as if there were none. Anyone can
      register an unconfirmed account for any address, so its password is not
      the invitee's: the invitee sets a new one, the account is confirmed and
      every token it held is revoked before the membership is added.

  An `:admin` invitation is honoured only while the admin who sent it is still
  a standing platform admin (`inviter_still_admin?/1`).
  """

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Invitation
  alias KilnCMS.Accounts.LegacyAffiliation

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
  Give `user` the membership `invitation` names, as a system write. An existing
  membership on that site is left as it is (the invitation is then simply used
  up). Before an account's first membership on another site, its legacy
  default-site tier is carried onto a membership of its own
  (`KilnCMS.Accounts.LegacyAffiliation`), so accepting never demotes it there.

  `context` is the Ash context to write with (the request's client address, for
  the audit event). Pass `carry_legacy?: false` for an account this same
  transaction just created: it has no legacy tier to carry, and carrying would
  give it a stray `:viewer` membership on the default site (the site-SSO
  admission skips the carry for a new account for the same reason).
  """
  @spec grant_membership(Accounts.User.t(), Invitation.t(), map(), keyword()) ::
          {:ok, Accounts.OrgMembership.t() | :already_member} | {:error, term()}
  def grant_membership(user, %Invitation{} = invitation, context \\ %{}, grant_opts \\ []) do
    # authorize?: false — membership writes are a platform-admin action; this is
    # the system honouring an invitation an admin sent, after the token, its
    # expiry and the sender's standing were all checked by the caller.
    opts = [authorize?: false, context: context]

    with {:ok, memberships} <- memberships(user),
         :ok <- maybe_carry(user, memberships, invitation.organization_id, opts, grant_opts) do
      if Enum.any?(memberships, &(&1.organization_id == invitation.organization_id)) do
        {:ok, :already_member}
      else
        Accounts.create_org_membership(
          %{
            user_id: user.id,
            organization_id: invitation.organization_id,
            role: invitation.role,
            role_id: invitation.role_id
          },
          opts
        )
      end
    end
  end

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
