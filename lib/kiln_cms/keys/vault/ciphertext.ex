defmodule KilnCMS.Keys.Vault.Ciphertext do
  @moduledoc """
  A column holding `KilnCMS.Keys.Vault` ciphertext (#1487).

  Stored exactly as `:binary` — no migration, no change on the wire — and
  exists so the column can be *found*: `KilnCMS.Keys.Vault.encrypted_attributes/0`
  collects every attribute of this type, and that list is what
  `KilnCMS.Keys.Reencrypt` walks across a `SECRET_KEY_BASE` rotation. A test
  refuses any other `:binary` attribute that is not explicitly accounted for,
  so a new vault column declared as plain `:binary` fails the build instead of
  being silently orphaned by the next rotation.
  """
  use Ash.Type.NewType, subtype_of: :binary
end
