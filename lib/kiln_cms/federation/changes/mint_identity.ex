defmodule KilnCMS.Federation.Changes.MintIdentity do
  @moduledoc """
  Mints a site's ActivityPub identity on `:enable` (#491): the pinned origin,
  the username, and a fresh RSA-2048 keypair (`MintKeypair`).

  This always *computes* an identity; whether it is *stored* is decided by the
  action's `upsert_fields`, which lists `enabled` alone. So a first enable
  inserts everything, and re-enabling a site that was switched off updates only
  the flag and keeps the actor id and key its followers already cached.

  That split matters: re-minting here would silently swap the key under the
  actor followers know, with nothing telling them. Replacing the key on
  purpose is the `:rekey` action (#1487), which keeps the identity and sends
  followers an actor `Update`.
  """
  use Ash.Resource.Change

  alias KilnCMS.Federation.Changes.MintKeypair

  @impl true
  def change(changeset, opts, context) do
    changeset
    |> Ash.Changeset.force_change_attribute(
      :origin,
      Ash.Changeset.get_argument(changeset, :origin)
    )
    |> Ash.Changeset.force_change_attribute(
      :username,
      Ash.Changeset.get_argument(changeset, :username)
    )
    |> MintKeypair.change(opts, context)
  end
end
