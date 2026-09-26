defmodule KilnCMS.Accounts.SiteSso.HttpAdapter do
  @moduledoc """
  Assent's HTTP adapter for a **site's** identity provider (#1561): every
  request goes through `KilnCMS.SafeFetch`.

  A site's provider is a URL a tenant chose, and the OIDC flow makes several
  requests to it: discovery, the token endpoint (which is sent the client
  secret), and the signing keys (`jwks_uri`). The last two are named by the
  discovery document, so they are chosen by whoever runs the provider, not even
  by the admin who typed the issuer. Each one is therefore:

    * `https://` only — a plain-HTTP token endpoint would put the client secret
      and the authorization code on the wire;
    * resolved once, SSRF-checked and pinned (`KilnCMS.SafeFetch`), so no
      private, loopback, link-local or metadata address is ever dialled, before
      or after a DNS change;
    * not redirected — a followed redirect is a fresh resolution the pin never
      sees;
    * capped at 256 KB, since the provider writes the response.

  The operator's own provider (`OIDC_*`, the compiled `:sso` strategy) does not
  use this adapter: the operator is trusted, and an internal IdP on `10.x` is
  legitimately theirs.
  """
  @behaviour Assent.HTTPAdapter

  alias Assent.HTTPAdapter.HTTPResponse

  @max_bytes 256 * 1024

  @impl Assent.HTTPAdapter
  def request(method, url, body, headers, opts) do
    opts = opts || []

    with :ok <- https_only(url) do
      fetch_opts = [
        headers: headers ++ [Assent.HTTPAdapter.user_agent_header()],
        max_bytes: @max_bytes,
        max_redirects: 0,
        req_options: Keyword.get(opts, :req_options, [])
      ]

      result =
        case method do
          :get -> KilnCMS.SafeFetch.get(url, fetch_opts)
          :post -> KilnCMS.SafeFetch.post(url, body || "", fetch_opts)
        end

      case result do
        {:ok, %{status: status, headers: response_headers, body: response_body}} ->
          {:ok,
           %HTTPResponse{
             status: status,
             headers: flatten_headers(response_headers),
             body: response_body
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc false
  # Also used by `KilnCMS.Accounts.SiteSso` for the discovery document's URLs.
  @spec https_only(term()) :: :ok | {:error, String.t()}
  def https_only(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> :ok
      _other -> {:error, "blocked URL: an identity provider URL must be https://"}
    end
  end

  def https_only(_url), do: {:error, "blocked URL: an identity provider URL must be https://"}

  # Req gives `%{name => [values]}`; Assent reads `[{name, value}]` and looks up
  # `content-type` with `List.keyfind/3`, so the first value of each is enough.
  defp flatten_headers(headers) when is_map(headers) do
    Enum.flat_map(headers, fn
      {name, [value | _rest]} -> [{String.downcase(to_string(name)), to_string(value)}]
      {name, value} when is_binary(value) -> [{String.downcase(to_string(name)), value}]
      _other -> []
    end)
  end

  defp flatten_headers(headers) when is_list(headers), do: headers
end
