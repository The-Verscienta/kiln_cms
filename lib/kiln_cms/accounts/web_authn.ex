defmodule KilnCMS.Accounts.WebAuthn do
  @moduledoc """
  The WebAuthn (passkey) ceremony for #331 — challenge minting plus
  attestation/assertion verification over `Wax`, wired to the
  `KilnCMS.Accounts.Passkey` store.

  Two ceremonies:

    * **Registration** (authenticated, from `/editor/settings` over the
      LiveView socket): mint a challenge, have the browser create a
      *discoverable* credential with *user verification* required, verify the
      attestation, store the credential.
    * **Authentication** (anonymous, from the sign-in page via
      `KilnCMSWeb.PasskeyController`): mint a challenge with no credential
      allow-list (the browser picks a discoverable credential), verify the
      assertion + clone-detection counter, and return the account with a
      session token minted — a passkey sign-in is complete on its own.

  Because every credential is registered with user verification required and
  every assertion must carry the UV flag, a passkey is possession *and*
  knowledge/biometric in one step — which is why passkey sign-in does not
  divert to the TOTP prompt (see `PasskeyController`).

  Verification is seam-injectable for tests
  (`config :kiln_cms, KilnCMS.Accounts.WebAuthn, verifier: MyStub`): the
  verifier implements `register/3` and `authenticate/6` with `Wax`'s
  signatures. Everything around the seam — base64url plumbing, uniqueness,
  counter regression, token minting — runs for real in tests.
  """

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Passkey

  @doc "Mint a registration challenge (discoverable credential, UV required)."
  @spec registration_challenge() :: Wax.Challenge.t()
  def registration_challenge do
    Wax.new_registration_challenge(
      origin: origin(),
      rp_id: rp_id(),
      user_verification: "required",
      attestation: "none"
    )
  end

  @doc """
  The client-side `navigator.credentials.create/1` options for `challenge`,
  JSON-safe (binaries as unpadded base64url).
  """
  @spec registration_options(Wax.Challenge.t(), KilnCMS.Accounts.User.t()) :: map()
  def registration_options(challenge, user) do
    %{
      challenge: b64(challenge.bytes),
      rp: %{id: challenge.rp_id, name: "KilnCMS"},
      user: %{
        id: b64(user.id),
        name: to_string(user.email),
        displayName: user.name || to_string(user.email)
      },
      pubKeyCredParams: [
        # ES256 and RS256 — the WebAuthn-recommended baseline pair.
        %{type: "public-key", alg: -7},
        %{type: "public-key", alg: -257}
      ],
      authenticatorSelection: %{
        residentKey: "required",
        userVerification: "required"
      },
      attestation: "none",
      timeout: challenge.timeout * 1000
    }
  end

  @doc """
  Verify a registration attestation and store the credential.

  `payload` carries the browser response, base64url-encoded:
  `"attestation_object"`, `"client_data_json"`, and an optional `"name"`.
  """
  @spec register_passkey(KilnCMS.Accounts.User.t(), Wax.Challenge.t(), map()) ::
          {:ok, Passkey.t()} | {:error, term()}
  def register_passkey(user, challenge, payload) do
    with {:ok, attestation} <- decode(payload["attestation_object"]),
         {:ok, client_data} <- decode(payload["client_data_json"]),
         {:ok, {auth_data, _attestation_result}} <-
           verifier().register(attestation, client_data, challenge) do
      credential = auth_data.attested_credential_data

      Accounts.register_passkey_credential(
        %{
          user_id: user.id,
          name: presence(payload["name"]) || "Passkey",
          credential_id: b64(credential.credential_id),
          public_key: :erlang.term_to_binary(credential.credential_public_key),
          sign_count: auth_data.sign_count
        },
        authorize?: false
      )
    else
      :error -> {:error, :invalid_encoding}
      {:error, _reason} = error -> error
    end
  end

  @doc "Mint an authentication challenge (no allow-list — discoverable credentials)."
  @spec authentication_challenge() :: Wax.Challenge.t()
  def authentication_challenge do
    Wax.new_authentication_challenge(
      origin: origin(),
      rp_id: rp_id(),
      user_verification: "required",
      allow_credentials: []
    )
  end

  @doc "The client-side `navigator.credentials.get/1` options for `challenge`."
  @spec authentication_options(Wax.Challenge.t()) :: map()
  def authentication_options(challenge) do
    %{
      challenge: b64(challenge.bytes),
      rpId: challenge.rp_id,
      allowCredentials: [],
      userVerification: "required",
      timeout: challenge.timeout * 1000
    }
  end

  @doc """
  Verify a sign-in assertion and return the credential's account, with a
  session token in its metadata (via the `:sign_in_with_passkey` action).

  `payload` carries `"credential_id"`, `"authenticator_data"`, `"signature"`,
  and `"client_data_json"`, base64url-encoded. Fails closed on unknown
  credentials, verification errors, and signature-counter regressions
  (a cloned-authenticator signal).
  """
  @spec authenticate(Wax.Challenge.t(), map()) ::
          {:ok, KilnCMS.Accounts.User.t()} | {:error, term()}
  def authenticate(challenge, payload) do
    with {:ok, credential_raw} <- decode(payload["credential_id"]),
         {:ok, auth_data_bin} <- decode(payload["authenticator_data"]),
         {:ok, signature} <- decode(payload["signature"]),
         {:ok, client_data} <- decode(payload["client_data_json"]),
         {:ok, passkey} <- lookup(b64(credential_raw)),
         {:ok, auth_data} <-
           verifier().authenticate(
             credential_raw,
             auth_data_bin,
             signature,
             client_data,
             challenge,
             [{credential_raw, decode_cose_key(passkey.public_key)}]
           ),
         :ok <- check_sign_count(passkey, auth_data.sign_count) do
      bump_usage(passkey, auth_data.sign_count)
      sign_in(passkey.user_id)
    else
      :error -> {:error, :invalid_encoding}
      {:error, _reason} = error -> error
    end
  end

  # The stored key is our own `term_to_binary` of Wax's CBOR-decoded COSE map
  # (see register_passkey/3) — decoded non-executably as defense-in-depth.
  defp decode_cose_key(binary), do: Plug.Crypto.non_executable_binary_to_term(binary, [:safe])

  defp lookup(credential_id) do
    case Accounts.get_passkey_by_credential_id(credential_id,
           authorize?: false,
           not_found_error?: false
         ) do
      {:ok, %Passkey{} = passkey} -> {:ok, passkey}
      _ -> {:error, :unknown_credential}
    end
  end

  # WebAuthn §6.1.1: a counter that fails to advance (when either side is
  # non-zero) signals a cloned credential. Synced passkeys report 0/0 — pass.
  defp check_sign_count(%{sign_count: stored}, reported) do
    if (stored == 0 and reported == 0) or reported > stored do
      :ok
    else
      {:error, :sign_count_regression}
    end
  end

  defp bump_usage(passkey, sign_count) do
    Accounts.bump_passkey_usage(passkey, %{sign_count: sign_count}, authorize?: false)
  end

  # The dedicated sign-in read mints the session token (metadata) exactly like
  # the built-in strategies — see User.sign_in_with_passkey.
  defp sign_in(user_id) do
    case Accounts.complete_passkey_sign_in(user_id, authorize?: false, not_found_error?: false) do
      {:ok, %KilnCMS.Accounts.User{} = user} -> {:ok, user}
      _ -> {:error, :account_unavailable}
    end
  end

  @doc "The user's registered passkeys, for the settings page."
  @spec list(KilnCMS.Accounts.User.t()) :: [Passkey.t()]
  def list(user) do
    Accounts.list_passkeys!(user.id, actor: user, query: [sort: [inserted_at: :asc]])
  end

  @challenge_cache :kiln_cms_passkey_challenges

  @doc "The dedicated Cachex instance for in-flight challenges (supervised)."
  @spec challenge_cache() :: atom()
  def challenge_cache, do: @challenge_cache

  @doc """
  Park a challenge server-side for its Wax timeout, returning an opaque
  nonce. `take_challenge/1` consumes it atomically — a challenge is verified
  at most once even if the request (cookies included) is replayed.
  """
  @spec stash_challenge(Wax.Challenge.t()) :: String.t()
  def stash_challenge(challenge) do
    nonce = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    Cachex.put(@challenge_cache, nonce, challenge, expire: :timer.seconds(challenge.timeout))
    nonce
  end

  @doc "Consume a parked challenge (single use). `nil` when absent/expired."
  @spec take_challenge(term()) :: Wax.Challenge.t() | nil
  def take_challenge(nonce) when is_binary(nonce) do
    case Cachex.take(@challenge_cache, nonce) do
      {:ok, %Wax.Challenge{} = challenge} -> challenge
      _ -> nil
    end
  end

  def take_challenge(_nonce), do: nil

  # Relying-party identity from the endpoint's canonical URL — passkeys are
  # scoped to this host (subdomain-site setups authenticate on the main host).
  # The WebAuthn origin is scheme://host[:port] with NO path and no default
  # port — the browser's clientDataJSON origin is compared by exact string, so
  # a URL config carrying a path or an explicit :443 would fail every
  # ceremony.
  defp origin do
    uri = URI.parse(KilnCMSWeb.Endpoint.url())

    port =
      case {uri.scheme, uri.port} do
        {"https", 443} -> ""
        {"http", 80} -> ""
        {_, nil} -> ""
        {_, port} -> ":#{port}"
      end

    "#{uri.scheme}://#{uri.host}#{port}"
  end

  defp rp_id, do: URI.parse(KilnCMSWeb.Endpoint.url()).host

  defp verifier do
    :kiln_cms
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:verifier, Wax)
  end

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)

  defp decode(value) when is_binary(value), do: Base.url_decode64(value, padding: false)
  defp decode(_value), do: :error

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_value), do: nil
end
