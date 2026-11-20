defmodule KilnCMS.CMS.Changes.BustTaxonomyPayloads do
  @moduledoc """
  Drops the site's cached delivery payloads after a taxonomy term is renamed
  (#2765).

  A page's `<title>`, meta description and Open Graph tags can name its
  category through the `[category]` SEO pattern token
  (`KilnCMS.Seo.Pattern`), resolved at render time from the category loaded
  into the cached payload. A rename moves nothing on the page's own row, so
  without this the payload kept the old name until its TTL, and the ETag,
  which hashes the payload, kept validating the old `<title>`.

  A term names no page, so the site's payloads go by prefix
  (`KilnCMS.Cache.bust_payloads/1`). Only when a category's stored name
  actually changed: renames are rare, and a description edit renders nowhere.
  Declared on every taxonomy resource's `:update` by `KilnCMS.CMS.Taxonomy`,
  but a no-op on tags and tag groups, which no delivered page renders. A term
  in use cannot be deleted (the content foreign key restricts it), so
  `:destroy` needs none.

  After the commit (`KilnCMS.AfterCommit`), so a page rebuilt between the bust
  and the commit cannot cache the old name again. Atomic like the change it
  sits beside: it adds a hook and writes nothing.
  """
  use Ash.Resource.Change

  @impl true
  def change(%{resource: KilnCMS.CMS.Category} = changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, &bust/2)
  end

  # Only a category's name renders (the `[category]` token); tags and tag
  # groups reach no delivered page, so their renames bust nothing.
  def change(changeset, _opts, _context), do: changeset

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  # The stored name before and after, not `changing_attribute?/2`: on the
  # atomic path a submitted name equal to the stored one is still an atomic
  # update, so the editor's form (which always posts the name) would flush the
  # site on every description edit.
  defp bust(changeset, {:ok, %{org_id: org_id, name: name}} = result) do
    if changeset.data.name != name,
      do: KilnCMS.AfterCommit.run(fn -> KilnCMS.Cache.bust_payloads(org_id) end)

    result
  end

  # A failed write changed nothing, so there is nothing to invalidate.
  defp bust(_changeset, result), do: result
end
