defmodule KilnCMS.CMS.Validations.SsoIssuer do
  @moduledoc """
  A site's OIDC issuer (`KilnCMS.CMS.SiteSsoProvider.issuer`) has to be an
  `https://` URL that the SSRF rules allow.

  A site admin is not the operator. The issuer is a URL this server fetches
  (discovery), and whatever comes back — or the error, or the time it took — is
  visible to the admin. So a private, loopback, link-local or metadata address
  is refused here, where the admin can see why (`KilnCMS.Webhooks.SafeUrl`).
  It is checked again on every fetch (`KilnCMS.Accounts.SiteSso.HttpAdapter`,
  through `KilnCMS.SafeFetch`), because DNS can change between the save and the
  sign-in, and because the discovery document names further URLs of its own.

  `https://` is required in every environment, unlike `SafeUrl`'s own scheme
  rule (which allows plain HTTP outside production): the token endpoint is sent
  the client secret, and the ID token's signing keys come from the same host.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :issuer) do
      issuer when is_binary(issuer) and issuer != "" -> check(issuer)
      _blank -> :ok
    end
  end

  @doc """
  `:ok`, or `{:error, message}` for an issuer URL a site may not use. Public so
  the sign-in path (`KilnCMS.Accounts.SiteSso`) applies the same rule to the
  stored value, rather than trusting a row written before a rule changed.
  """
  @spec issuer_error(String.t()) :: :ok | {:error, String.t()}
  def issuer_error(issuer) when is_binary(issuer) do
    case URI.parse(issuer) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}
      when is_binary(host) and host != "" ->
        KilnCMS.Webhooks.SafeUrl.validate(issuer)

      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        {:error, "must not carry a user name, query or fragment"}

      _other ->
        {:error, "must be an https:// URL"}
    end
  end

  defp check(issuer) do
    case issuer_error(issuer) do
      :ok -> :ok
      {:error, message} -> {:error, InvalidAttribute.exception(field: :issuer, message: message)}
    end
  end
end
