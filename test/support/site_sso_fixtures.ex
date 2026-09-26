defmodule KilnCMS.SiteSsoFixtures do
  @moduledoc """
  A site's own identity provider, for tests (#1561): a provider row, a
  verified domain whose TXT record is "published" (`KilnCMS.Test.StubDNS`), and
  a `Req.Test` OpenID provider that answers discovery, the token endpoint and
  the signing keys with a real RS256-signed ID token.

  Nothing here short-circuits the protocol: `KilnCMS.Accounts.SiteSso` runs
  Assent's real callback — state, nonce, PKCE, signature, `iss`/`aud`/`exp` —
  against these answers, through `KilnCMS.SafeFetch`.
  """

  alias KilnCMS.Accounts.SiteSso.DomainCheck
  alias KilnCMS.CMS

  @issuer "https://idp.example.test"
  @client_id "site-client"
  @client_secret "site-client-secret"

  def issuer, do: @issuer
  def client_id, do: @client_id
  def client_secret, do: @client_secret

  @doc "An RSA signing key and its public JWK (with `kid`)."
  def signing_key(kid \\ "test-key") do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_fields, public} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()

    %{
      jwk: jwk,
      kid: kid,
      public: Map.merge(public, %{"kid" => kid, "alg" => "RS256", "use" => "sig"})
    }
  end

  @doc "A switched-on provider for `org`."
  def provider!(org, attrs \\ %{}) do
    %{issuer: @issuer, client_id: @client_id, client_secret: @client_secret, label: "Acme staff"}
    |> Map.merge(attrs)
    |> CMS.save_site_sso_provider!(tenant: org, authorize?: false)
  end

  @doc """
  A domain row for `org`. `verified: true` also stamps `verified_at` through the
  real `:verify` action, with its TXT record planted for the duration of the
  test (`published: false` to plant nothing).
  """
  def domain!(org, domain, opts \\ []) do
    row = CMS.add_site_sso_domain!(domain, tenant: org, authorize?: false)

    if Keyword.get(opts, :published, Keyword.get(opts, :verified, false)) do
      publish!(row)
    end

    if Keyword.get(opts, :verified, false) do
      CMS.verify_site_sso_domain!(row, tenant: org, authorize?: false)
    else
      row
    end
  end

  @doc "Publish a domain row's TXT record in the stub resolver (until `unpublish!/1`)."
  def publish!(row) do
    name = DomainCheck.record_name(row.domain)
    KilnCMS.Test.StubDNS.put_txt(name, [DomainCheck.record_value(row.verification_token)])
    ExUnit.Callbacks.on_exit(fn -> KilnCMS.Test.StubDNS.delete_txt(name) end)
    row
  end

  def unpublish!(row), do: KilnCMS.Test.StubDNS.delete_txt(DomainCheck.record_name(row.domain))

  @doc "A domain no other test uses."
  def unique_domain(prefix \\ "acme"),
    do: "#{prefix}-#{System.unique_integer([:positive])}.example"

  @doc "The discovery document the stub serves (override keys with `overrides`)."
  def discovery(overrides \\ %{}) do
    Map.merge(
      %{
        "issuer" => @issuer,
        "authorization_endpoint" => @issuer <> "/authorize",
        "token_endpoint" => @issuer <> "/token",
        "jwks_uri" => @issuer <> "/jwks",
        "token_endpoint_auth_methods_supported" => ["client_secret_basic"]
      },
      overrides
    )
  end

  @doc """
  Serve the provider from `Req.Test`: discovery, keys, and a token endpoint
  whose ID token carries `claims` (merged over a valid default set, `nonce`
  included when given). `opts`: `:discovery` overrides, `:jwks` (defaults to the
  key's own), `:sign_with` (a different key), `:alg`, `:test_pid` (receives
  `{:token_request, conn_body}`).
  """
  def stub_provider!(key, claims, opts \\ []) do
    discovery = discovery(Keyword.get(opts, :discovery, %{}))
    jwks = Keyword.get(opts, :jwks, %{"keys" => [key.public]})
    signer = Keyword.get(opts, :sign_with, key)
    test_pid = Keyword.get(opts, :test_pid)

    Req.Test.stub(KilnCMS.Accounts.SiteSso, fn conn ->
      case conn.request_path do
        "/.well-known/openid-configuration" -> Req.Test.json(conn, discovery)
        "/jwks" -> Req.Test.json(conn, jwks)
        "/token" -> token_response(conn, signer, claims, test_pid, opts)
      end
    end)
  end

  defp token_response(conn, signer, claims, test_pid, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    if test_pid, do: send(test_pid, {:token_request, body, conn.req_headers})

    Req.Test.json(conn, %{
      "access_token" => "at-#{System.unique_integer([:positive])}",
      "token_type" => "Bearer",
      "id_token" => id_token(signer, claims, opts)
    })
  end

  @doc "An ID token signed by `key`, over valid defaults merged with `claims`."
  def id_token(key, claims, opts \\ []) do
    now = System.system_time(:second)

    payload =
      Map.merge(
        %{
          "iss" => @issuer,
          "sub" => "sub-#{System.unique_integer([:positive])}",
          "aud" => @client_id,
          "iat" => now,
          "exp" => now + 300,
          "email_verified" => true
        },
        claims
      )

    case Keyword.get(opts, :alg, "RS256") do
      "HS256" ->
        hmac = JOSE.JWK.from_oct(@client_secret)

        {_meta, token} =
          hmac |> JOSE.JWT.sign(%{"alg" => "HS256"}, payload) |> JOSE.JWS.compact()

        token

      "RS256" ->
        {_meta, token} =
          key.jwk
          |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => key.kid}, payload)
          |> JOSE.JWS.compact()

        token
    end
  end
end
