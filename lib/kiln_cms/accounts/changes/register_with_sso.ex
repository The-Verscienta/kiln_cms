defmodule KilnCMS.Accounts.Changes.RegisterWithSso do
  @moduledoc """
  Upsert a user from an OIDC identity (#331, SSO phase).

  Security posture:

    * **Verified email only.** The IdP must assert `email_verified` (`true`, or
      the string `"true"` from string-typed providers) — otherwise an attacker
      could register an address at a lax IdP and take over the matching Kiln
      account on first SSO sign-in. Providers that omit the claim entirely
      (e.g. Entra ID by default) are rejected unless the operator explicitly
      sets `config :kiln_cms, :sso_oidc, assume_email_verified: true` for an
      IdP known to assert only owned emails (docs/sso.md).
    * **Linking, not privilege.** An existing account (matched by provider
      identity or verified email) is signed in as-is — role and audiences
      untouched. A brand-new user lands as `:viewer` with no audiences,
      exactly like password self-registration.
    * **An unconfirmed account is taken over, not linked.** An account nobody
      confirmed may have been registered by a stranger, password and all. The
      first SSO sign-in to one replaces its password and forgets every
      credential it held (`User.:take_over_by_sso`), as a magic-link sign-in
      does.
    * **Invite-only respected.** When `:registration_enabled` is false, SSO
      only signs in *known* accounts — matched by an already-linked provider
      identity (`iss`/`sub`) **or** by email — so an identity-linked employee
      whose IdP email changed is not locked out, while unknown identities are
      refused instead of auto-provisioned.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.AlreadyConfirmed
  alias KilnCMS.Security.Recorder

  @impl true
  def change(changeset, _opts, _context) do
    info = Ash.Changeset.get_argument(changeset, :user_info) || %{}
    email = info["email"]

    cond do
      not (is_binary(email) and email != "") ->
        Ash.Changeset.add_error(changeset, field: :email, message: "identity carries no email")

      not email_verified?(info) ->
        Ash.Changeset.add_error(changeset,
          field: :email,
          message: "identity email is not verified by the provider"
        )

      true ->
        # One short-circuited existence probe: linked identity first (the
        # stable match), then email. Reused for BOTH the invite-only gate and
        # to skip the ~250ms bcrypt hash for returning users (whose insert
        # payload is discarded by the upsert match anyway).
        known? = known_account?(info, email)

        if known? or Application.get_env(:kiln_cms, :registration_enabled, true) do
          changeset
          |> Ash.Changeset.change_attribute(:email, email)
          |> maybe_unusable_password(known?)
          |> maybe_set_name(info)
          |> Ash.Changeset.before_transaction(&take_over_unconfirmed(&1, email))
        else
          Ash.Changeset.add_error(changeset,
            field: :email,
            message: "self-registration is disabled; ask an administrator for an account"
          )
        end
    end
  end

  # Anyone can register an unconfirmed account for any address and choose its
  # password. Linking the provider's identity to that account as it stands
  # would sign the address's owner in to an account a stranger can still open.
  # So the first SSO sign-in to an unconfirmed account takes it over, as a
  # magic link does (`User.:take_over_by_sso`): the password is replaced with
  # one nobody knows, and every token, second factor, passkey, push device and
  # API key it held is forgotten. Runs before the upsert's transaction opens, in
  # its own: the takeover's after-commit effects (session eviction, audit
  # events) must not wait on, or be undone with, the identity link's write.
  defp take_over_unconfirmed(changeset, email) do
    case unconfirmed_account(email) do
      {:ok, nil} ->
        changeset

      {:ok, user} ->
        # authorize?: false — a pre-auth flow with no actor: the provider's
        # verified identity is the credential, and the action is system-only
        # (`forbid_if always()`, and its change refuses any actor).
        case Accounts.take_over_by_sso(user, %{},
               authorize?: false,
               context:
                 Map.take(changeset.context, [Recorder.context_key(), Recorder.tenant_key()])
             ) do
          {:ok, _claimed} -> changeset
          {:error, error} -> keep_or_refuse(changeset, error)
        end

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  # Confirmed between the read and the lock: nothing to take over.
  defp keep_or_refuse(changeset, error) do
    if already_confirmed?(error), do: changeset, else: Ash.Changeset.add_error(changeset, error)
  end

  defp already_confirmed?(%AlreadyConfirmed{}), do: true

  defp already_confirmed?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &already_confirmed?/1)

  defp already_confirmed?(_error), do: false

  defp unconfirmed_account(email) do
    # authorize?: false — an SSO callback, before anyone is signed in. Only the
    # row's id and `confirmed_at` decide anything, and nothing read leaves here.
    Accounts.User
    |> Ash.Query.filter(email == ^email and is_nil(confirmed_at))
    |> Ash.read_one(authorize?: false)
  end

  defp email_verified?(info) do
    case Map.fetch(info, "email_verified") do
      {:ok, value} ->
        value in [true, "true"]

      :error ->
        # Claim absent: only trusted when the operator opted in for their IdP.
        :kiln_cms
        |> Application.get_env(:sso_oidc, [])
        |> Keyword.get(:assume_email_verified, false)
    end
  end

  # A valid-but-unusable bcrypt hash, minted once at compile time from random
  # bytes whose plaintext is discarded. Used as the insert placeholder for
  # KNOWN accounts, whose insert values the upsert match throws away anyway —
  # a fresh ~250ms bcrypt per returning SSO sign-in would be pure wasted CPU
  # on the auth hot path. (The value must still be well-formed: the NOT NULL
  # validation runs before upsert resolution, and `Bcrypt.verify_pass`
  # tolerates only real hashes.)
  @unusable_hash Bcrypt.hash_pwd_salt(32 |> :crypto.strong_rand_bytes() |> Base.encode64())

  # `hashed_password` is non-null (password auth), but an SSO account has none:
  # a genuinely NEW account gets its own unguessable random hash (password
  # sign-in only works after an explicit reset); a known account's discarded
  # insert payload gets the compile-time placeholder.
  defp maybe_unusable_password(changeset, true = _known?) do
    Ash.Changeset.force_change_new_attribute(changeset, :hashed_password, @unusable_hash)
  end

  defp maybe_unusable_password(changeset, false) do
    Ash.Changeset.force_change_new_attribute(
      changeset,
      :hashed_password,
      Bcrypt.hash_pwd_salt(32 |> :crypto.strong_rand_bytes() |> Base.encode64())
    )
  end

  # Only set the display name for a NEW account (no clobbering a chosen name on
  # a returning user — matched rows only write `upsert_fields`).
  defp maybe_set_name(changeset, info) do
    case info["name"] do
      name when is_binary(name) and name != "" ->
        Ash.Changeset.change_new_attribute(changeset, :name, name)

      _ ->
        changeset
    end
  end

  defp known_account?(info, email) do
    identity_linked?(info["sub"] || info["uid"]) or existing_user?(email)
  end

  # A stored provider identity for this iss/sub — the stable match the
  # strategy's resolver will coerce the upsert to.
  defp identity_linked?(sub) when is_binary(sub) and sub != "" do
    # authorize?: false — an SSO callback, before anyone is signed in — there
    # is no actor. An existence check the invite-only gate decides on.
    KilnCMS.Accounts.UserIdentity
    |> Ash.Query.filter(strategy == "sso" and uid == ^sub)
    |> Ash.exists?(authorize?: false)
  end

  defp identity_linked?(_), do: false

  # The domain's canonical email lookup (code interface — AGENTS.md), so the
  # invite-only gate can't drift from what the rest of the app considers an
  # existing account.
  defp existing_user?(email) do
    # authorize?: false — same pre-auth callback, no actor; the answer only
    # decides whether the invite-only gate admits the sign-in, and is never
    # shown to the caller.
    match?({:ok, %{}}, Accounts.get_user_by_email(email, authorize?: false))
  end
end
