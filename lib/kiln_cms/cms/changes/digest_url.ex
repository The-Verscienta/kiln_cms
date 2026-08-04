defmodule KilnCMS.CMS.Changes.DigestUrl do
  @moduledoc """
  Derives `url_digest` and `host` from `url` on every `ExternalLink` write
  (#474).

  Both are functions of the URL, and neither is writable, for the same reason
  `Changes.HashInlineScripts` derives its hashes: the digest is what decides
  which rows share a verdict, so a caller able to set it directly could make one
  URL's 404 land on a different URL's rows.

  The digest is over the URL **as stored**, trimmed and no more. Canonicalizing
  first (lowercasing the path, sorting the query, dropping a trailing slash) is
  tempting and wrong: `/A` and `/a` are different documents on a
  case-sensitive server, and collapsing them would check one and report the
  verdict against both.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :url) do
      url when is_binary(url) ->
        url = String.trim(url)

        changeset
        |> Ash.Changeset.force_change_attribute(:url, url)
        |> Ash.Changeset.force_change_attribute(:url_digest, digest(url))
        |> Ash.Changeset.force_change_attribute(:host, KilnCMS.Links.External.host(url))

      _other ->
        changeset
    end
  end

  @doc "The stored digest for `url` — hex SHA-256 of the trimmed string."
  @spec digest(String.t()) :: String.t()
  def digest(url) when is_binary(url) do
    :sha256 |> :crypto.hash(String.trim(url)) |> Base.encode16(case: :lower)
  end
end
