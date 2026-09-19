defmodule KilnCMS.Federation.Changes.MintKeypair do
  @moduledoc """
  Mints a site actor's RSA-2048 keypair (#491) into `public_key_pem` and
  `private_key_encrypted` — the key half of `MintIdentity`, shared with the
  `:rekey` action (#1487) so a first key and a replacement come from the same
  path (`KilnCMS.Keys.generate_rsa_pem/0`, stored through `KilnCMS.Keys.Vault`).

  It writes the key and nothing else: the actor's `origin` and `username` are
  its identity, and re-keying must leave them exactly as remote servers know
  them.
  """
  use Ash.Resource.Change

  alias KilnCMS.Keys

  @impl true
  def change(changeset, _opts, _context) do
    private_pem = Keys.generate_rsa_pem()

    case public_pem(private_pem) do
      {:ok, public_pem} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:public_key_pem, public_pem)
        |> Ash.Changeset.force_change_attribute(
          :private_key_encrypted,
          Keys.Vault.encrypt(private_pem)
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
