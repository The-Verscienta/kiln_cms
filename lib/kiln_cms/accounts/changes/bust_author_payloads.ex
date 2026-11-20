defmodule KilnCMS.Accounts.Changes.BustAuthorPayloads do
  @moduledoc """
  Drops every site's cached delivery payloads after a user's display name
  changes (#2765).

  The name is what a published post shows as its byline when no reference
  field names one, and the JSON-LD `author`. It reaches the page through the
  author loaded into the cached payload, so a rename moves nothing on the
  content row: without this the payload kept the old name until its TTL, and
  the ETag, which hashes the payload, kept validating it.

  A user can author on any site they belong to, and the name names no page, so
  every site's payloads go (`KilnCMS.Cache.bust_payloads/1` with `nil`). Only
  when the name actually changed, which is rare: a profile save, accepting an
  invitation over an unconfirmed account, an erasure.

  After the commit (`KilnCMS.AfterCommit`), so a page rebuilt between the bust
  and the commit cannot cache the old name again. The name is read off the
  final changeset in the hook, so a change declared after this one that sets
  it (`AnonymizeUser`'s scrub) still counts.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, &bust/2)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp bust(changeset, {:ok, _record} = result) do
    if Ash.Changeset.changing_attribute?(changeset, :name),
      do: KilnCMS.AfterCommit.run(fn -> KilnCMS.Cache.bust_payloads(nil) end)

    result
  end

  # A failed write changed nothing, so there is nothing to invalidate.
  defp bust(_changeset, result), do: result
end
