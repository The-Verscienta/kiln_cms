defmodule KilnCMS.Federation.Changes.MintIdentity do
  @moduledoc """
  Mints a site's ActivityPub identity on `:enable` (#491): the pinned origin,
  the username, and a fresh RSA-2048 keypair.

  This always *computes* an identity; whether it is *stored* is decided by the
  action's `upsert_fields`, which lists `enabled` alone. So a first enable
  inserts everything, and re-enabling a site that was switched off updates only
  the flag and keeps the actor id and key its followers already cached.

  That split matters: re-minting would silently orphan every remote follower,
  and there is no mechanism for a remote server to learn it happened.
  """
  use Ash.Resource.Change

  alias KilnCMS.Keys

  @impl true
  def change(changeset, _opts, _context) do
    private_pem = Keys.generate_rsa_pem()

    case public_pem(private_pem) do
      {:ok, public_pem} ->
        changeset
        |> Ash.Changeset.force_change_attribute(
          :origin,
          Ash.Changeset.get_argument(changeset, :origin)
        )
        |> Ash.Changeset.force_change_attribute(
          :username,
          Ash.Changeset.get_argument(changeset, :username)
        )
        |> Ash.Changeset.force_change_attribute(:public_key_pem, public_pem)
        |> Ash.Changeset.force_change_attribute(
          :private_key_encrypted,
          KilnCMS.Keys.Vault.encrypt(private_pem)
        )

      :error ->
        Ash.Changeset.add_error(changeset,
          field: :public_key_pem,
          message: "could not derive a public key for this site's actor"
        )
    end
  end

  defp public_pem(private_pem) do
    case Keys.rsa_private_key(private_pem) do
      {:ok, private_key} -> {:ok, Keys.rsa_public_key_pem(private_key)}
      {:error, _reason} -> :error
    end
  end
end
