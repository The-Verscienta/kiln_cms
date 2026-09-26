defmodule KilnCMS.CMS.Validations.StorageEndpoint do
  @moduledoc """
  A site's object-storage endpoint and public base URL
  (`KilnCMS.CMS.StorageProfile`) have to be URLs this server may use.

    * **`endpoint`** is a connection this server opens, with a signed request,
      on a site admin's say-so — and the error that comes back is shown to
      them. So it must be `https://host[:port]` with nothing after the host,
      and the host must pass the SSRF rules (`KilnCMS.Webhooks.SafeUrl`): no
      private, loopback, link-local or metadata address. It is checked again at
      every connection (`KilnCMS.Storage.SiteProfiles`), because DNS can change
      between the save and the upload. Blank is AWS S3, so it is required for
      a region AWS doesn't have (`auto`, R2's).
    * **`public_base_url`** is only ever put in front of visitors, never
      fetched here, so it is not resolved. It must be `https://`: an `http://`
      image on an `https://` page is mixed content, blocked by browsers.

  `allow_private_hosts: true` (`config :kiln_cms, KilnCMS.Storage.SiteProfiles`)
  lifts both for development against a MinIO on localhost.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.Storage.SiteProfiles
  alias KilnCMS.Webhooks.SafeUrl

  @impl true
  def validate(changeset, _opts, _context) do
    endpoint = Ash.Changeset.get_attribute(changeset, :endpoint)

    with :ok <- endpoint(endpoint),
         :ok <- aws_region(endpoint, Ash.Changeset.get_attribute(changeset, :region)) do
      public_base_url(Ash.Changeset.get_attribute(changeset, :public_base_url))
    end
  end

  # With no endpoint the host is AWS's for the region, so the region has to be
  # one AWS has — `auto` (R2) needs R2's endpoint.
  defp aws_region(blank, region) when blank in [nil, ""] and is_binary(region) do
    case SiteProfiles.target(nil, region) do
      {:ok, _target} -> :ok
      :error -> error(:endpoint, "is required for region #{region}")
    end
  end

  defp aws_region(_endpoint, _region), do: :ok

  defp endpoint(blank) when blank in [nil, ""], do: :ok

  defp endpoint(url) do
    case URI.new(url) do
      {:ok, %URI{host: host, path: path, query: nil, fragment: nil, userinfo: nil} = uri}
      when is_binary(host) and host != "" and path in [nil, "", "/"] ->
        if scheme_ok?(uri.scheme),
          do: safe_host(host),
          else: error(:endpoint, "must start with https://")

      _other ->
        error(:endpoint, "must be a URL like https://s3.example.com, with nothing after the host")
    end
  end

  defp safe_host(host) do
    if SiteProfiles.allow_private_hosts?() do
      :ok
    else
      case SafeUrl.resolve_host_pinned(host) do
        {:ok, _address} -> :ok
        {:error, message} -> error(:endpoint, message)
      end
    end
  end

  defp public_base_url(blank) when blank in [nil, ""], do: :ok

  defp public_base_url(url) do
    case URI.new(url) do
      {:ok, %URI{host: host, query: nil, fragment: nil, userinfo: nil} = uri}
      when is_binary(host) and host != "" ->
        cond do
          not scheme_ok?(uri.scheme) -> error(:public_base_url, "must start with https://")
          # It goes into the site's CSP header (`Plugs.SiteStorageCsp`).
          not SiteProfiles.csp_host?(host) -> error(:public_base_url, "must use a host name")
          true -> :ok
        end

      _other ->
        error(:public_base_url, "must be a URL like https://cdn.example.com/my-bucket")
    end
  end

  defp scheme_ok?("https"), do: true
  defp scheme_ok?("http"), do: SiteProfiles.allow_private_hosts?()
  defp scheme_ok?(_scheme), do: false

  defp error(field, message),
    do: {:error, InvalidAttribute.exception(field: field, message: message)}
end
