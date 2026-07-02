defmodule KilnCMS.Mail.Settings.Changes.GenerateDkim do
  @moduledoc """
  Generate (or, with `rotate: true`, replace) a database-provider DKIM key:
  fresh RSA-2048 PEM encrypted at rest, derived public key for the TXT
  record, and a new selector so the old DNS record can stay published while
  in-transit mail signed with the old key still verifies.
  """
  use Ash.Resource.Change

  alias KilnCMS.Keys
  alias KilnCMS.Keys.Vault

  @impl true
  def change(changeset, opts, _context) do
    rotate? = Keyword.get(opts, :rotate, false)

    changeset
    |> Ash.Changeset.before_action(&generate(&1, rotate?))
    |> invalidate_dkim_cache_after()
  end

  defp generate(changeset, rotate?) do
    data = changeset.data
    database_key? = data.dkim_key_provider == :database and data.dkim_private_key_encrypted

    cond do
      rotate? and !database_key? ->
        Ash.Changeset.add_error(changeset,
          field: :dkim_key_provider,
          message: "no database-stored key to rotate — generate one first"
        )

      !rotate? and database_key? ->
        Ash.Changeset.add_error(changeset,
          field: :dkim_key_provider,
          message: "a key already exists — rotate it instead"
        )

      true ->
        pem = Keys.generate_rsa_pem()
        {:ok, public_key} = Keys.rsa_public_key_b64(pem)

        changeset
        |> Ash.Changeset.force_change_attribute(:dkim_key_provider, :database)
        |> Ash.Changeset.force_change_attribute(:dkim_key_provider_config, %{})
        |> Ash.Changeset.force_change_attribute(:dkim_private_key_encrypted, Vault.encrypt(pem))
        |> Ash.Changeset.force_change_attribute(:dkim_public_key, public_key)
        |> Ash.Changeset.force_change_attribute(:dkim_selector, Keys.new_selector())
    end
  end

  @doc false
  def invalidate_dkim_cache_after(changeset) do
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      KilnCMS.Mail.invalidate_dkim_cache()
      result
    end)
  end
end
