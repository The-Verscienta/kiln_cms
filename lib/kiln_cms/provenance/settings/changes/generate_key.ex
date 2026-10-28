defmodule KilnCMS.Provenance.Settings.Changes.GenerateKey do
  @moduledoc """
  Fills a new `KilnCMS.Provenance.Settings` row with a fresh RSA-2048 key:
  the PEM encrypted at rest, its public half and its `key_id` in the clear.
  """
  use Ash.Resource.Change

  alias KilnCMS.Keys
  alias KilnCMS.Keys.Vault
  alias KilnCMS.Provenance.KeyRegistry

  @impl true
  def change(changeset, _opts, _context) do
    pem = Keys.generate_rsa_pem()
    {:ok, private_key} = Keys.rsa_private_key(pem)
    public_key = Keys.rsa_public_key(private_key)

    changeset
    |> Ash.Changeset.force_change_attribute(:private_key_encrypted, Vault.encrypt(pem))
    |> Ash.Changeset.force_change_attribute(:public_key_pem, Keys.rsa_public_key_pem(public_key))
    |> Ash.Changeset.force_change_attribute(
      :key_id,
      KeyRegistry.key_id(Keys.rsa_public_key_der_b64(public_key))
    )
  end
end
