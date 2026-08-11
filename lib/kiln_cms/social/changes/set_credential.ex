defmodule KilnCMS.Social.Changes.SetCredential do
  @moduledoc """
  Encrypts the submitted `credential` into `credential_encrypted` (#497).

  Blank means **unchanged**, not "erase". The settings form re-submits every
  field on every save and deliberately never echoes a secret back, so blank is
  the normal submission for an account whose credential has not changed —
  reading it as "clear" would silently unconfigure a working account, and the
  operator would find out the next time a publish failed to announce.

  `:create` requires it (`allow_nil?: false` on the argument), so an account
  cannot exist without one.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case changeset |> Ash.Changeset.get_argument(:credential) |> presence() do
      nil ->
        changeset

      secret ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :credential_encrypted,
          KilnCMS.Keys.Vault.encrypt(secret)
        )
    end
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil
end
