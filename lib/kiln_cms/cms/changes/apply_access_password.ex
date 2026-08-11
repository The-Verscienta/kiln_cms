defmodule KilnCMS.CMS.Changes.ApplyAccessPassword do
  @moduledoc """
  Turns the `access_password` / `remove_access_password` arguments into the
  stored `access_password_hash` + `password_fingerprint` pair (#496).

  ## Why setting and clearing are two different arguments

  The obvious design — "an empty `access_password` clears the lock" — is wrong
  here, and quietly so. The editor's Settings rail re-submits every field on
  every change, and a password input's value is deliberately *not* echoed back
  into the form. So the blank string is the overwhelmingly common submission for
  a record whose passphrase is unchanged, and treating it as "clear" would drop
  the lock off a published document the first time anyone edited its title.

  So: a blank or absent `access_password` means **no change**, and clearing is
  an explicit `remove_access_password: true`. This is the same distinction
  `KilnCMS.CMS.Changes` draws elsewhere between an absent argument and an
  explicit null — except that here the safe reading of "blank" is *keep*, not
  *clear*, because the loss is silent and the content is already published.

  The two attributes always move together. Nothing else in the codebase may
  write `password_fingerprint`, so it cannot drift from the hash it summarises —
  which matters because the delivery filter trusts it to decide who reads a
  locked document.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.ContentPassword

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &apply_password/1)
  end

  # In `before_action`, not at changeset-build time. Changes run on every
  # `AshPhoenix.Form.validate/2`, which the content editor fires per keystroke —
  # and bcrypt is a deliberately slow KDF. Hashing there would have burned a full
  # work factor on every character typed into the passphrase field, which is both
  # a laggy editor and a way to load the server from the admin UI.
  defp apply_password(changeset) do
    cond do
      Ash.Changeset.get_argument(changeset, :remove_access_password) == true ->
        clear(changeset)

      passphrase = presence(Ash.Changeset.get_argument(changeset, :access_password)) ->
        set(changeset, passphrase)

      true ->
        changeset
    end
  end

  defp set(changeset, passphrase) do
    hash = ContentPassword.hash(passphrase)

    changeset
    |> Ash.Changeset.force_change_attribute(:access_password_hash, hash)
    |> Ash.Changeset.force_change_attribute(
      :password_fingerprint,
      ContentPassword.fingerprint(hash)
    )
  end

  defp clear(changeset) do
    changeset
    |> Ash.Changeset.force_change_attribute(:access_password_hash, nil)
    |> Ash.Changeset.force_change_attribute(:password_fingerprint, nil)
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil
end
