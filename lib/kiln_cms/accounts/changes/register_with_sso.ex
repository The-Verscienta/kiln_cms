defmodule KilnCMS.Accounts.Changes.RegisterWithSso do
  @moduledoc """
  Upsert a user from an OIDC identity (#331, SSO phase).

  Security posture:

    * **Verified email only.** The IdP must assert `email_verified` — an
      unverified claim is rejected outright, or an attacker could register an
      address at a lax IdP and take over the matching Kiln account on first
      SSO sign-in.
    * **Linking, not privilege.** An existing account (matched by email) is
      signed in as-is — role and audiences untouched. A brand-new user lands
      as `:viewer` with no audiences, exactly like password self-registration;
      access is granted by an admin afterwards.
    * **Invite-only respected.** When `:registration_enabled` is false, SSO
      only signs in *existing* accounts; unknown emails are refused instead of
      auto-provisioned.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    info = Ash.Changeset.get_argument(changeset, :user_info) || %{}
    email = info["email"]

    cond do
      not (is_binary(email) and email != "") ->
        Ash.Changeset.add_error(changeset, field: :email, message: "identity carries no email")

      info["email_verified"] != true ->
        Ash.Changeset.add_error(changeset,
          field: :email,
          message: "identity email is not verified by the provider"
        )

      not registration_allowed?(email) ->
        Ash.Changeset.add_error(changeset,
          field: :email,
          message: "self-registration is disabled; ask an administrator for an account"
        )

      true ->
        changeset
        |> Ash.Changeset.change_attribute(:email, email)
        # `hashed_password` is non-null (password auth), but an SSO account has
        # none: give the INSERT path an unguessable random hash (never
        # disclosed — password sign-in only works after an explicit reset).
        # On an upsert match, `upsert_fields [:email]` leaves the real hash
        # untouched.
        |> Ash.Changeset.force_change_new_attribute(
          :hashed_password,
          Bcrypt.hash_pwd_salt(32 |> :crypto.strong_rand_bytes() |> Base.encode64())
        )
        |> maybe_set_name(info)
    end
  end

  # Only set the display name for a NEW account (no clobbering a chosen name on
  # a returning user). The upsert only writes accepted/changed attributes for
  # matched rows via upsert_fields — name is deliberately not among them.
  defp maybe_set_name(changeset, info) do
    case info["name"] do
      name when is_binary(name) and name != "" ->
        Ash.Changeset.change_new_attribute(changeset, :name, name)

      _ ->
        changeset
    end
  end

  # Invite-only mode (#331): a new (unknown) email may not auto-provision.
  # A pre-check read rather than a changeset-time constraint because the upsert
  # can't distinguish insert-vs-update before it runs.
  defp registration_allowed?(email) do
    Application.get_env(:kiln_cms, :registration_enabled, true) or existing_user?(email)
  end

  defp existing_user?(email) do
    KilnCMS.Accounts.User
    |> Ash.Query.filter(email == ^email)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{}} -> true
      _ -> false
    end
  end
end
