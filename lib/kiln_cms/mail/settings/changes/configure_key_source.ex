defmodule KilnCMS.Mail.Settings.Changes.ConfigureKeySource do
  @moduledoc """
  Point the DKIM key at an operator-managed source (env var or file): check
  the source is readable and a valid RSA PEM, derive + store the public key
  from what it holds, and clear any database-stored material. The selector
  only rotates when the key material actually changed, so re-saving the same
  source doesn't invalidate the published DNS record.
  """
  use Ash.Resource.Change

  alias KilnCMS.Keys
  alias KilnCMS.Mail.Settings.Changes.GenerateDkim

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&configure/1)
    |> GenerateDkim.invalidate_dkim_cache_after()
  end

  defp configure(changeset) do
    provider = Ash.Changeset.get_argument(changeset, :provider)
    config = changeset |> Ash.Changeset.get_argument(:config) |> normalize(provider)

    with {:ok, pem} <- Keys.provider!(provider).fetch(config),
         :ok <- Keys.validate_private_key_pem(pem),
         {:ok, public_key} <- Keys.rsa_public_key_b64(pem) do
      changeset
      |> Ash.Changeset.force_change_attribute(:dkim_key_provider, provider)
      |> Ash.Changeset.force_change_attribute(:dkim_key_provider_config, config)
      |> Ash.Changeset.force_change_attribute(:dkim_private_key_encrypted, nil)
      |> Ash.Changeset.force_change_attribute(:dkim_public_key, public_key)
      |> maybe_rotate_selector(public_key)
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :config,
          message: Keys.describe_error(reason)
        )
    end
  end

  # Keep only the one pointer key the provider understands; tolerate
  # atom-keyed maps from code callers (persisted maps use string keys).
  defp normalize(config, provider) do
    {string_key, atom_key} = pointer_keys(provider)

    case config[string_key] || config[atom_key] do
      value when value in [nil, ""] -> %{}
      value -> %{string_key => value}
    end
  end

  defp pointer_keys(:env), do: {"var", :var}
  defp pointer_keys(:file), do: {"path", :path}

  defp maybe_rotate_selector(changeset, public_key) do
    if changeset.data.dkim_public_key == public_key and changeset.data.dkim_selector do
      changeset
    else
      Ash.Changeset.force_change_attribute(changeset, :dkim_selector, Keys.new_selector())
    end
  end
end
