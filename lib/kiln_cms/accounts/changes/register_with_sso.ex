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
    * **Invite-only respected.** When `:registration_enabled` is false, SSO
      only signs in *known* accounts — matched by an already-linked provider
      identity (`iss`/`sub`) **or** by email — so an identity-linked employee
      whose IdP email changed is not locked out, while unknown identities are
      refused instead of auto-provisioned.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias KilnCMS.Accounts

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
        else
          Ash.Changeset.add_error(changeset,
            field: :email,
            message: "self-registration is disabled; ask an administrator for an account"
          )
        end
    end
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
    KilnCMS.Accounts.UserIdentity
    |> Ash.Query.filter(strategy == "sso" and uid == ^sub)
    |> Ash.exists?(authorize?: false)
  end

  defp identity_linked?(_), do: false

  # The domain's canonical email lookup (code interface — AGENTS.md), so the
  # invite-only gate can't drift from what the rest of the app considers an
  # existing account.
  defp existing_user?(email) do
    match?({:ok, %{}}, Accounts.get_user_by_email(email, authorize?: false))
  end
end
