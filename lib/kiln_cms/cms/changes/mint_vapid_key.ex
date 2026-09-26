defmodule KilnCMS.CMS.Changes.MintVapidKey do
  @moduledoc """
  Mints a site's VAPID key pair (#1560) into `SiteVapidKey.public_key` and
  `private_key_encrypted` (`KilnCMS.Keys.Vault`).

  Without `rotate: true` it mints only when the row has no key yet, so it can
  sit on `:save` and `:update` and a subject edit never replaces a pair. On a
  `:save` that conflicts with an existing row the freshly minted pair is not
  written: the upsert overwrites the subject alone, and the stored pair wins.
  With `rotate: true` (the `:rotate` action) it always mints.
  """
  use Ash.Resource.Change

  alias KilnCMS.Keys.Vault
  alias KilnCMS.Push.Vapid

  @impl true
  def change(changeset, opts, _context) do
    if opts[:rotate] || is_nil(changeset.data.public_key) do
      {public, private} = Vapid.generate()

      changeset
      |> Ash.Changeset.force_change_attribute(:public_key, public)
      |> Ash.Changeset.force_change_attribute(:private_key_encrypted, Vault.encrypt(private))
    else
      changeset
    end
  end
end
