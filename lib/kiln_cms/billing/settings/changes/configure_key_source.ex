defmodule KilnCMS.Billing.Settings.Changes.ConfigureKeySource do
  @moduledoc """
  Point one billing secret at an operator-managed source (env var or file):
  check the source is readable and non-empty, then switch the provider and clear
  any database-stored material for that secret.

  Unlike the DKIM twin (`KilnCMS.Mail.Settings.Changes.ConfigureKeySource`) there
  is no PEM to parse — the check is simply "something is there".

  **A blank pointer is rejected rather than normalized away.**
  `KilnCMS.Keys.Providers.Env` falls back to `@default_var "DKIM_PRIVATE_KEY"`
  when its config carries no `"var"`, so accepting an empty pointer here would
  silently resolve a billing secret to the *DKIM signing key* and send it to the
  payment provider as a bearer token. The pointer is validated before any fetch.
  """
  use Ash.Resource.Change

  alias KilnCMS.Billing.Settings
  alias KilnCMS.Keys

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &configure/1)
  end

  defp configure(changeset) do
    key = Ash.Changeset.get_argument(changeset, :key)
    provider = Ash.Changeset.get_argument(changeset, :provider)
    config = Ash.Changeset.get_argument(changeset, :config) || %{}

    {provider_field, config_field, encrypted_field} = Settings.fields(key)

    with {:ok, normalized} <- normalize(config, provider),
         {:ok, secret} <- Keys.provider!(provider).fetch(normalized),
         :ok <- ensure_present(secret) do
      changeset
      |> Ash.Changeset.force_change_attribute(provider_field, provider)
      |> Ash.Changeset.force_change_attribute(config_field, normalized)
      # Switching away from :database must not leave the old ciphertext behind —
      # it would resurrect the previous secret if the provider ever switched back.
      |> Ash.Changeset.force_change_attribute(encrypted_field, nil)
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset, field: :config, message: describe(reason))
    end
  end

  # Keep only the one pointer key the provider understands; tolerate atom-keyed
  # maps from code callers (persisted maps use string keys). A blank pointer is
  # an error, never an empty map — see the moduledoc.
  defp normalize(config, provider) do
    {string_key, atom_key} = pointer_keys(provider)

    case config[string_key] || config[atom_key] do
      value when value in [nil, ""] -> {:error, {:pointer_required, provider}}
      value -> {:ok, %{string_key => String.trim(to_string(value))}}
    end
  end

  defp pointer_keys(:env), do: {"var", :var}
  defp pointer_keys(:file), do: {"path", :path}

  defp ensure_present(secret) do
    if String.trim(to_string(secret)) == "", do: {:error, :empty_secret}, else: :ok
  end

  defp describe({:pointer_required, :env}),
    do: "Enter the name of the environment variable holding the secret."

  defp describe({:pointer_required, :file}),
    do: "Enter the path to the file holding the secret."

  defp describe(:empty_secret), do: "The configured source exists but is empty."
  defp describe(reason), do: Keys.describe_error(reason)
end
