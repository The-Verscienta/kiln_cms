defmodule KilnCMS.Push.Vapid do
  @moduledoc """
  VAPID — "Voluntary Application Server Identification" for Web Push, RFC 8292
  (#628).

  A push service will not accept a message from an anonymous sender. VAPID is
  how the application server identifies itself: an ES256 JWT signed with a
  P-256 key the deployment holds, whose public half the browser was given when
  it created the subscription. The push service checks that the signature
  matches that key, which is what stops anyone who learns an endpoint URL from
  pushing to it.

  ## Configuration

  Runtime, not compile-time, so a prebuilt image can be configured by an
  operator (`config/runtime.exs`, `KILN_VAPID_*`). Absent keys mean push is
  **off** — `configured?/0` is false, the client is never offered the toggle,
  and the sender no-ops. That is the same posture the rest of the PWA takes:
  degrade silently where the capability is not there.

      config :kiln_cms, KilnCMS.Push,
        vapid_public_key: "BEl…",   # base64url, uncompressed P-256 point (65 bytes)
        vapid_private_key: "yfW…",  # base64url, the 32-byte scalar
        vapid_subject: "mailto:ops@example.com"

  Generate a pair with `mix kiln.vapid.gen`. The format is the one
  `web-push generate-vapid-keys` emits, so an existing pair carries over.

  ## The public key is checked against the private one at boot

  A deployment that publishes one public key to browsers while signing with a
  different private key produces subscriptions that can never be delivered to —
  and the failure surfaces months later as a 403 from the push service, per
  message, with nothing pointing at the config. `configured?/0` derives the
  public point from the private scalar and refuses a mismatched pair, so the
  error lands at the one moment somebody can act on it.

  ## Why the signature needs converting

  `:crypto.sign/4` emits ECDSA signatures in the ASN.1 DER form X.509 uses:
  a SEQUENCE of two INTEGERs, variable length, sign-padded. JWS ES256
  (RFC 7518 §3.4) wants the raw fixed-width form — `r ‖ s`, 32 bytes each, no
  wrapper. Passing DER through produces a signature every push service
  rejects, and the two forms are similar enough in length that it looks like it
  should work.
  """

  require Logger

  @public_key_bytes 65
  @private_key_bytes 32
  @coordinate_bytes 32

  # RFC 8292 §2: a push service MAY reject a token good for more than 24 hours.
  # Short enough to stay inside that, long enough that a retrying Oban job
  # reuses the same token rather than re-signing per attempt.
  @token_ttl_seconds 12 * 60 * 60

  @doc "Is a usable VAPID key pair configured?"
  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _keys}, keys())

  @doc """
  The public key browsers need for `pushManager.subscribe/1`, base64url.

  `nil` when push is not configured, which is what the client checks before
  offering the opt-in.
  """
  @spec public_key() :: String.t() | nil
  def public_key do
    case keys() do
      {:ok, %{public_b64: public}} -> public
      _absent -> nil
    end
  end

  @doc """
  The `Authorization` header value for a request to `endpoint`.

  The audience is the endpoint's **origin**, not the full URL — a token scoped
  to one endpoint path would have to be re-signed per subscription, and the
  spec asks for the origin.
  """
  @spec authorization(String.t()) :: {:ok, String.t()} | {:error, term()}
  def authorization(endpoint) when is_binary(endpoint) do
    with {:ok, keys} <- keys(),
         {:ok, audience} <- origin(endpoint) do
      claims = %{
        "aud" => audience,
        "exp" => System.system_time(:second) + @token_ttl_seconds,
        "sub" => subject()
      }

      {:ok, "vapid t=#{sign(claims, keys)}, k=#{keys.public_b64}"}
    end
  end

  @doc """
  A fresh key pair as `{public_b64, private_b64}`, for `mix kiln.vapid.gen`.
  """
  @spec generate() :: {String.t(), String.t()}
  def generate do
    {public, private} = :crypto.generate_key(:ecdh, :prime256v1)
    {encode(public), encode(pad_scalar(private))}
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp sign(claims, keys) do
    payload =
      encode(Jason.encode!(%{"typ" => "JWT", "alg" => "ES256"})) <>
        "." <> encode(Jason.encode!(claims))

    signature =
      :ecdsa
      |> :crypto.sign(:sha256, payload, [keys.private, :prime256v1])
      |> der_to_raw()

    payload <> "." <> encode(signature)
  end

  # base64url without padding, which is what JWS and the browser's
  # `applicationServerKey` both expect.
  defp encode(value), do: Base.url_encode64(value, padding: false)

  # DER `SEQUENCE { INTEGER r, INTEGER s }` → `r ‖ s`, each left-padded to 32
  # bytes. DER INTEGERs are signed, so a coordinate whose top bit is set gains a
  # leading zero byte that has to come back off; one shorter than 32 bytes has
  # to be padded back up.
  defp der_to_raw(<<0x30, _len, 0x02, r_len, rest::binary>>) do
    <<r::binary-size(^r_len), 0x02, s_len, s::binary-size(s_len)>> = rest
    coordinate(r) <> coordinate(s)
  end

  defp coordinate(<<0, rest::binary>>) when byte_size(rest) == @coordinate_bytes, do: rest

  defp coordinate(value) when byte_size(value) < @coordinate_bytes,
    do: String.duplicate(<<0>>, @coordinate_bytes - byte_size(value)) <> value

  defp coordinate(value), do: value

  # `:crypto.generate_key/2` returns the scalar with leading zero bytes trimmed,
  # so one key in 256 is 31 bytes and would encode to a base64url string other
  # tooling reads as malformed.
  defp pad_scalar(scalar) when byte_size(scalar) < @private_key_bytes,
    do: String.duplicate(<<0>>, @private_key_bytes - byte_size(scalar)) <> scalar

  defp pad_scalar(scalar), do: scalar

  # Decoded and validated on every call rather than cached: this runs once per
  # push job, the work is a single point multiplication, and a cache would mean
  # a key rotation needed a restart to take effect.
  defp keys do
    with {:ok, public_b64} <- fetch(:vapid_public_key),
         {:ok, private_b64} <- fetch(:vapid_private_key),
         {:ok, public} <- decode(public_b64, @public_key_bytes, :vapid_public_key),
         {:ok, private} <- decode(private_b64, @private_key_bytes, :vapid_private_key),
         :ok <- check_pair(public, private) do
      {:ok, %{public: public, public_b64: public_b64, private: private}}
    end
  end

  defp fetch(key) do
    case :kiln_cms |> Application.get_env(KilnCMS.Push, []) |> Keyword.get(key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _absent -> {:error, {:not_configured, key}}
    end
  end

  defp decode(value, bytes, key) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} when byte_size(decoded) == bytes -> {:ok, decoded}
      _malformed -> {:error, {:invalid_key, key}}
    end
  end

  defp check_pair(public, private) do
    {derived, _private} = :crypto.generate_key(:ecdh, :prime256v1, private)

    if derived == public do
      :ok
    else
      Logger.error(
        "VAPID keys do not match: the configured public key is not the public half of " <>
          "the configured private key. Push notifications are disabled — regenerate the " <>
          "pair with `mix kiln.vapid.gen`."
      )

      {:error, :mismatched_keys}
    end
  end

  # RFC 8292 §2.1 requires a contactable `mailto:` or `https:` so a push service
  # operator can reach whoever is sending. The fallback is the deployment's own
  # base URL, which is at least true.
  defp subject do
    :kiln_cms
    |> Application.get_env(KilnCMS.Push, [])
    |> Keyword.get(:vapid_subject)
    |> case do
      value when is_binary(value) and value != "" -> value
      _absent -> Application.get_env(:kiln_cms, :public_base_url, "http://localhost:4000")
    end
  end

  defp origin(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        {:ok, URI.to_string(%URI{scheme: scheme, host: host, port: nil})}

      _malformed ->
        {:error, {:invalid_endpoint, endpoint}}
    end
  end
end
