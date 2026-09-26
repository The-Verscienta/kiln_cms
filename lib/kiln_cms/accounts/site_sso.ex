defmodule KilnCMS.Accounts.SiteSso do
  @moduledoc """
  A site's own single sign-on provider (#1561): OpenID Connect against the
  issuer a site admin set at `/editor/site-sso`
  (`KilnCMS.CMS.SiteSsoProvider`), beside — never instead of — the operator's
  provider (`OIDC_*`, the `:sso` strategy compiled into
  `KilnCMS.Accounts.User`).

  ## Why this is not an AshAuthentication strategy

  AshAuthentication's strategies are declared on the resource at compile time,
  one per name. A strategy whose secrets resolved per request from the site
  would still share one strategy name, one `UserIdentity` namespace and one
  registration action with the operator's provider — so a site's provider
  asserting a `sub` that the operator's provider had already linked would sign
  in as that linked account. The site's flow is therefore its own, small and
  separate: `Assent.Strategy.OIDC` for the protocol (state, nonce, PKCE, ID
  token signature, `iss`/`aud`/`exp`/`azp`), `KilnCMS.Accounts.SiteSso.Admission`
  for who may sign in, and `KilnCMSWeb.SiteSsoController` for the two routes.
  The operator's provider is untouched by any of it.

  ## Fail direction

  A two-layer setting has a third case: the row exists but cannot be used
  (`KilnCMS.OrgSettings`' "pick a fail direction"). The row cannot be read (a
  pool timeout, a table missing mid-deploy), or the client secret cannot be
  decrypted (`SECRET_KEY_BASE` rotated, see `docs/secrets-rotation.md`). In
  every such case the site's single sign-on is **unavailable**, and the sign-in
  page says so. It never falls back to the operator's provider: a site that
  chose its own identity provider did not choose the operator's, and a button
  that quietly sent its staff somewhere else would be the wrong answer to a
  question nobody asked. Password and magic-link sign-in are unaffected.

  ## SSRF

  Every server-side request — discovery, the token endpoint, the signing keys —
  goes through `KilnCMS.Accounts.SiteSso.HttpAdapter`, i.e. `KilnCMS.SafeFetch`:
  `https://` only, resolved once and pinned, no private/loopback/link-local/
  metadata address, no redirects, a byte cap. The discovery document's
  `issuer` must equal the configured issuer exactly (OIDC Discovery §4.3), and
  its endpoints must all be `https://`.

  The ID token must be signed with `RS256` by a key from the provider's
  `jwks_uri`. `alg: none` and the `HS*` family (which would verify with the
  client secret, i.e. with a value this server also holds) are refused.
  """

  require Logger

  alias Assent.Strategy.OIDC
  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.SiteSso.Admission
  alias KilnCMS.Accounts.SiteSso.HttpAdapter
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Validations.SsoIssuer
  alias KilnCMS.Keys.Vault

  @type provider :: %{
          org_id: String.t(),
          issuer: String.t(),
          client_id: String.t(),
          client_secret: String.t(),
          label: String.t() | nil
        }

  @type error ::
          :not_configured
          | :unavailable
          | :credentials_unreadable
          | {:provider, term()}
          | Admission.refusal()

  @discovery_path "/.well-known/openid-configuration"

  @doc """
  The site's provider, decrypted and ready to use; `:none` when the site has
  none switched on; `{:error, reason}` when it has one that cannot be used —
  see the moduledoc's fail direction.
  """
  @spec resolve(Ash.UUID.t()) :: {:ok, provider()} | :none | {:error, error()}
  def resolve(org_id) when is_binary(org_id) do
    case read_provider(org_id) do
      {:ok, nil} -> :none
      {:ok, %{enabled: false}} -> :none
      {:ok, row} -> build(row, org_id)
      :error -> {:error, :unavailable}
    end
  end

  @doc """
  What the sign-in page on this site offers:

    * `nil` — nothing: no provider, a provider switched off, or no verified
      domain yet (a button that could admit nobody is a button that only fails);
    * `{:ok, label}` — a "Sign in with …" button;
    * `:unavailable` — the site has a provider that cannot be used right now.
      The page says single sign-on is unavailable; it offers no other provider
      in its place.
  """
  @spec sign_in_option(Accounts.Organization.t() | Ash.UUID.t() | nil) ::
          nil | {:ok, String.t() | nil} | :unavailable
  def sign_in_option(org) do
    org_id = Accounts.org_id(org)

    case resolve(org_id) do
      :none ->
        nil

      {:error, _reason} ->
        :unavailable

      {:ok, provider} ->
        case Admission.verified_domains(org_id) do
          {:ok, []} -> nil
          {:ok, _domains} -> {:ok, provider.label}
          :error -> :unavailable
        end
    end
  end

  @doc """
  Start a sign-in: the provider's authorization URL to redirect the browser to,
  and the session parameters (state, nonce, PKCE verifier) the callback needs.
  The caller keeps those in the (encrypted) session, bound to this org.
  """
  @spec authorize(Ash.UUID.t(), String.t()) ::
          {:ok, %{url: String.t(), session_params: map()}} | {:error, error()}
  def authorize(org_id, redirect_uri) when is_binary(org_id) and is_binary(redirect_uri) do
    with {:ok, provider} <- require_provider(org_id),
         {:ok, discovery} <- discover(provider.issuer) do
      provider
      |> assent_config(discovery, redirect_uri)
      |> Keyword.put(:nonce, random_token())
      |> OIDC.authorize_url()
      |> case do
        {:ok, %{url: url, session_params: session_params}} ->
          {:ok, %{url: url, session_params: session_params}}

        {:error, reason} ->
          {:error, {:provider, reason}}
      end
    end
  end

  @doc """
  Finish a sign-in: exchange the code, verify the ID token, and hand its claims
  to `KilnCMS.Accounts.SiteSso.Admission`. `{:ok, user}` carries a freshly
  minted session token in `user.__metadata__.token`.
  """
  @spec sign_in(Ash.UUID.t(), String.t(), map(), map()) ::
          {:ok, Accounts.User.t()} | {:error, error()}
  def sign_in(org_id, redirect_uri, params, session_params)
      when is_binary(org_id) and is_binary(redirect_uri) and is_map(params) and
             is_map(session_params) do
    with {:ok, provider} <- require_provider(org_id),
         {:ok, discovery} <- discover(provider.issuer),
         {:ok, claims} <- exchange(provider, discovery, redirect_uri, params, session_params) do
      Admission.admit(org_id, claims)
    end
  end

  @doc "Whether the stored client secret decrypts — for the settings page."
  @spec secret_readable?(CMS.SiteSsoProvider.t()) :: boolean()
  def secret_readable?(%{client_secret_encrypted: nil}), do: true

  def secret_readable?(%{client_secret_encrypted: encrypted}),
    do: match?({:ok, _}, Vault.decrypt(encrypted))

  @doc "A sentence fragment for an `error()`, for logs."
  @spec describe_error(error()) :: String.t()
  def describe_error(:not_configured), do: "no provider is switched on for this site"
  def describe_error(:unavailable), do: "its settings could not be read"

  def describe_error(:credentials_unreadable),
    do: "its client secret could not be decrypted (was SECRET_KEY_BASE rotated?)"

  def describe_error({:provider, reason}), do: "the provider failed: #{format(reason)}"
  def describe_error(refusal), do: Admission.describe_refusal(refusal)

  @doc """
  The OIDC discovery document for `issuer`, fetched through `KilnCMS.SafeFetch`
  and checked: the same `issuer`, and `https://` endpoints.
  """
  @spec discover(String.t()) :: {:ok, map()} | {:error, {:provider, term()}}
  def discover(issuer) when is_binary(issuer) do
    url = String.trim_trailing(issuer, "/") <> @discovery_path

    with :ok <- wrap(SsoIssuer.issuer_error(issuer)),
         {:ok, %{status: status, body: body}} <- fetch(url),
         :ok <- ok_status(status),
         {:ok, %{} = document} <- decode(body),
         :ok <- same_issuer(document, issuer),
         :ok <- https_endpoints(document) do
      {:ok, document}
    else
      {:error, {:provider, _reason}} = error -> error
      {:error, reason} -> {:error, {:provider, reason}}
      {:ok, _not_a_map} -> {:error, {:provider, "discovery document is not a JSON object"}}
    end
  end

  # -- the protocol --------------------------------------------------------

  defp exchange(provider, discovery, redirect_uri, params, session_params) do
    config =
      provider
      |> assent_config(discovery, redirect_uri)
      |> Keyword.put(:session_params, atomize_session_params(session_params))

    case OIDC.callback(config, params) do
      {:ok, %{user: claims}} when is_map(claims) -> {:ok, claims}
      {:error, reason} -> {:error, {:provider, reason}}
    end
  rescue
    # Assent raises on some malformed provider answers (a JWKS entry JOSE
    # cannot read, say). A provider's bad answer is a failed sign-in, not a 500.
    exception -> {:error, {:provider, Exception.message(exception)}}
  end

  defp assent_config(provider, discovery, redirect_uri) do
    [
      client_id: provider.client_id,
      client_secret: provider.client_secret,
      base_url: provider.issuer,
      redirect_uri: redirect_uri,
      # Handing Assent the checked document means it never fetches discovery
      # itself; the token endpoint and the keys still go through the adapter.
      openid_configuration: discovery,
      http_adapter: {HttpAdapter, req_options: req_options()},
      client_authentication_method: "client_secret_basic",
      id_token_signed_response_alg: "RS256",
      code_verifier: true,
      authorization_params: [scope: "email profile"]
    ]
  end

  # Assent stores these as atom-keyed; a session round-trip through
  # `:erlang.term_to_binary` keeps them, but be tolerant of string keys anyway.
  # Only the four keys Assent reads, so no client-chosen atom is ever made.
  @session_keys ~w(state nonce code_verifier code_challenge_method)a
  defp atomize_session_params(params) do
    Map.new(@session_keys, fn key ->
      {key, Map.get(params, key) || Map.get(params, Atom.to_string(key))}
    end)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # -- reading the row -----------------------------------------------------

  defp require_provider(org_id) do
    case resolve(org_id) do
      {:ok, provider} -> {:ok, provider}
      :none -> {:error, :not_configured}
      {:error, _reason} = error -> error
    end
  end

  # `authorize?: false` — a system read on the sign-in path, where there is no
  # actor yet. Safe: the tenant is the request's own org, and nothing read here
  # is shown to the visitor except the button label.
  defp read_provider(org_id) do
    case CMS.list_site_sso_provider(tenant: org_id, authorize?: false) do
      {:ok, [row | _rest]} ->
        {:ok, row}

      {:ok, []} ->
        {:ok, nil}

      {:error, error} ->
        Logger.warning("Site single sign-on for #{org_id} unreadable: #{inspect(error)}")
        :error
    end
  rescue
    exception ->
      Logger.warning(
        "Site single sign-on for #{org_id} unreadable: #{Exception.message(exception)}"
      )

      :error
  end

  defp build(%{client_secret_encrypted: nil}, _org_id), do: {:error, :credentials_unreadable}

  defp build(row, org_id) do
    case Vault.decrypt(row.client_secret_encrypted) do
      {:ok, secret} ->
        {:ok,
         %{
           org_id: org_id,
           issuer: row.issuer,
           client_id: row.client_id,
           client_secret: secret,
           label: blank_to_nil(row.label)
         }}

      {:error, _reason} ->
        {:error, :credentials_unreadable}
    end
  end

  # -- discovery helpers -----------------------------------------------------

  defp fetch(url) do
    case HttpAdapter.https_only(url) do
      :ok ->
        KilnCMS.SafeFetch.get(url,
          headers: [{"accept", "application/json"}],
          max_bytes: 256 * 1024,
          max_redirects: 0,
          req_options: req_options()
        )

      error ->
        error
    end
  end

  defp ok_status(200), do: :ok
  defp ok_status(status), do: {:error, "discovery answered HTTP #{status}"}

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, document} -> {:ok, document}
      {:error, _error} -> {:error, "discovery document is not JSON"}
    end
  end

  defp same_issuer(%{"issuer" => issuer}, issuer), do: :ok

  defp same_issuer(_document, _issuer),
    do: {:error, "discovery document names a different issuer"}

  @endpoints ~w(authorization_endpoint token_endpoint jwks_uri)
  defp https_endpoints(document) do
    Enum.reduce_while(@endpoints, :ok, fn key, :ok ->
      case endpoint_error(key, document[key]) do
        nil -> {:cont, :ok}
        message -> {:halt, {:error, message}}
      end
    end)
  end

  defp endpoint_error(key, url) when is_binary(url) do
    if HttpAdapter.https_only(url) == :ok, do: nil, else: "#{key} must be https://"
  end

  defp endpoint_error(key, _missing), do: "discovery document has no #{key}"

  defp wrap(:ok), do: :ok
  defp wrap({:error, message}), do: {:error, "issuer refused: #{message}"}

  defp random_token, do: 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil

  defp format(reason) when is_binary(reason), do: reason
  defp format(%{__exception__: true} = exception), do: Exception.message(exception)
  defp format(reason), do: inspect(reason, limit: 10, printable_limit: 200)

  @doc false
  # `config :kiln_cms, KilnCMS.Accounts.SiteSso, req_options: [...]` — the test
  # env points every provider request at a `Req.Test` stub.
  @spec req_options() :: keyword()
  def req_options do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])
  end
end
