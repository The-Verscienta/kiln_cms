defmodule KilnCMS.CMS.Validations.SearchUrl do
  @moduledoc """
  A site's Meilisearch URL (`KilnCMS.CMS.SiteMeilisearch.url`) has to be an
  HTTPS URL whose host the SSRF rules allow.

  A site admin is not the operator. The URL is a server this deployment sends
  requests to — carrying the site's content and its API key — and the error
  that comes back is shown to them. So a private address is refused here, where
  the admin can see why. It is checked again on every request
  (`KilnCMS.SafeFetch`), because DNS can change between the save and the send.

  HTTPS only: the request carries a bearer key. Userinfo, a query string and a
  fragment are refused rather than silently dropped, because each would
  change where or how the request is made in a way the admin can't see.

  `allow_private_hosts: true` (`config :kiln_cms,
  KilnCMS.Search.Meilisearch.SiteInstance`) lifts the address and scheme
  checks for development, where the instance is on `http://localhost:7700`.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.Search.Meilisearch.SiteInstance

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :url) do
      url when is_binary(url) and url != "" -> check(String.trim(url))
      _blank -> :ok
    end
  end

  defp check(url) do
    uri = URI.parse(url)
    dev? = SiteInstance.allow_private_hosts?()

    with :ok <- shape(uri),
         :ok <- scheme(uri.scheme, dev?) do
      if dev?, do: :ok, else: address(url)
    end
  end

  defp shape(%URI{host: host}) when not is_binary(host) or host == "",
    do: error("must be a URL like https://search.example.com")

  defp shape(%URI{userinfo: nil, query: nil, fragment: nil}), do: :ok
  defp shape(_uri), do: error("must not contain a user name, query string or fragment")

  defp scheme("https", _dev?), do: :ok
  defp scheme("http", true), do: :ok
  defp scheme(_scheme, _dev?), do: error("must use HTTPS")

  defp address(url) do
    case KilnCMS.Webhooks.SafeUrl.resolve_pinned(url) do
      {:ok, _address} -> :ok
      {:error, message} -> error(message)
    end
  end

  defp error(message), do: {:error, InvalidAttribute.exception(field: :url, message: message)}
end
