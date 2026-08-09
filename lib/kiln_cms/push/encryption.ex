defmodule KilnCMS.Push.Encryption do
  @moduledoc """
  Web Push payload encryption — RFC 8291, over the `aes128gcm` content encoding
  of RFC 8188 (#628).

  A push service is a third party (Google, Mozilla, Apple). It routes the
  message and can read anything not encrypted, so the spec puts the payload
  under a key derived from the subscription's own ECDH public key: only the
  browser that created the subscription can decrypt it. That is the whole
  reason this module exists rather than a `Jason.encode!` and a POST.

  ## Why this is hand-rolled

  `web_push_encryption` on Hex was last released in 2021 and brings its own HTTP
  client, which this project deliberately does not have a second of (see the
  `:sentry` note in `mix.exs`). Everything below is `:crypto` composing
  primitives the OTP distribution already ships — ECDH on P-256, HKDF-SHA256,
  AES-128-GCM — in the order two RFCs specify. It is not new cryptography, and
  `test/kiln_cms/push/encryption_test.exs` checks it against the published test
  vectors in RFC 8291 §5 and RFC 8188 §3.1, which is what makes that claim
  checkable rather than a hope.

  ## The shape

      salt (16) ‖ record size (4) ‖ key id length (1) ‖ our public key (65) ‖ ciphertext

  and the key schedule:

      ecdh   = ECDH(our private key, the subscription's p256dh)
      prk    = HKDF(salt: auth_secret, ikm: ecdh,
                    info: "WebPush: info\\0" ‖ their key ‖ our key, 32)
      cek    = HKDF(salt: salt, ikm: prk, info: "Content-Encoding: aes128gcm\\0", 16)
      nonce  = HKDF(salt: salt, ikm: prk, info: "Content-Encoding: nonce\\0", 12)

  The plaintext is padded with a single `0x02` delimiter — the "last record"
  marker. One record only: a review notification is a few hundred bytes and the
  multi-record framing buys nothing.

  ## Sizes are checked, not assumed

  `p256dh` and `auth` arrive from a browser via our own endpoint, and a caller
  could hand us a truncated or hostile pair. A wrong-length `auth` silently
  changes the key schedule and produces a payload the browser drops without
  telling anyone, so both are validated up front and a bad subscription is an
  error rather than an undeliverable message.
  """

  # Uncompressed P-256 point: 0x04 ‖ X(32) ‖ Y(32).
  @public_key_bytes 65
  @auth_secret_bytes 16
  @salt_bytes 16
  @key_bytes 16
  @nonce_bytes 12
  @sha256_bytes 32

  # RFC 8188 §2.1: the record size covers plaintext + delimiter + the 16-byte
  # GCM tag. 4096 is what every push service accepts and what the browser API
  # advertises; a review notification is nowhere near it.
  @record_size 4096

  # salt(16) + record size(4) + key id length(1) + our public key(65).
  @header_bytes @salt_bytes + 4 + 1 + @public_key_bytes

  # The largest plaintext whose *encoded body* still fits the 4096-byte cap a
  # push service enforces. The delimiter and the GCM tag come out of the same
  # budget, and so does the RFC 8188 header — which is what makes this 86 bytes
  # smaller than the record size alone suggests. A caller that trusted the
  # looser number got a 413 after this function had said the size was fine.
  @max_plaintext @record_size - @header_bytes - 1 - 16

  @typedoc "The `p256dh` and `auth` a browser's `PushSubscription` exposes, raw."
  @type keys :: %{p256dh: binary(), auth: binary()}

  @doc """
  Encrypt `plaintext` for a subscription's keys.

  Returns the RFC 8188 message body, ready to POST with
  `Content-Encoding: aes128gcm`.

  `:salt` and `:key_pair` exist only so the test can replay the RFC's vectors;
  every real call generates both fresh, and reusing a salt across messages to
  the same subscription would leak plaintext structure.
  """
  @spec encrypt(binary(), keys(), keyword()) :: {:ok, binary()} | {:error, term()}
  def encrypt(plaintext, keys, opts \\ []) when is_binary(plaintext) do
    do_encrypt(plaintext, keys, opts)
  rescue
    # `:crypto.compute_key/4` RAISES for a 65-byte, `0x04`-prefixed point that
    # is not actually on the curve — there is no arithmetic check we can do
    # cheaply here, and OpenSSL does it inside. Without this the exception
    # escapes a function whose contract is `{:ok, _} | {:error, _}`, the
    # caller's `else` never sees it, and the poisoned row is never pruned: it
    # burns every retry and every Sentry report, per notification, forever.
    error -> {:error, {:invalid_key, :p256dh, Exception.message(error)}}
  end

  defp do_encrypt(plaintext, keys, opts) do
    with :ok <- validate(keys, plaintext) do
      salt = Keyword.get_lazy(opts, :salt, fn -> :crypto.strong_rand_bytes(@salt_bytes) end)
      {public, private} = Keyword.get_lazy(opts, :key_pair, &generate_key_pair/0)

      shared = compute_shared(keys.p256dh, private)
      prk = hkdf(keys.auth, shared, key_info(keys.p256dh, public), @sha256_bytes)
      content_key = hkdf(salt, prk, "Content-Encoding: aes128gcm\0", @key_bytes)
      nonce = hkdf(salt, prk, "Content-Encoding: nonce\0", @nonce_bytes)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :aes_128_gcm,
          content_key,
          nonce,
          # RFC 8188 §2: `0x02` marks the last (here, only) record. `0x01`
          # would say "more records follow" and the browser would wait for one.
          plaintext <> <<2>>,
          "",
          true
        )

      {:ok,
       <<salt::binary, @record_size::unsigned-big-32, @public_key_bytes::unsigned-8,
         public::binary, ciphertext::binary, tag::binary>>}
    end
  end

  defp compute_shared(their_public, our_private),
    do: :crypto.compute_key(:ecdh, their_public, our_private, :prime256v1)

  @doc "A fresh ephemeral P-256 key pair, as `{uncompressed public point, private}`."
  @spec generate_key_pair() :: {binary(), binary()}
  def generate_key_pair, do: :crypto.generate_key(:ecdh, :prime256v1)

  @doc "The largest plaintext one record can carry."
  @spec max_plaintext_bytes() :: pos_integer()
  def max_plaintext_bytes, do: @max_plaintext

  # RFC 8291 §3.3. The trailing NUL is part of the label, and the two public
  # keys are concatenated raw — receiver first. Getting the order backwards
  # produces a valid-looking payload the browser cannot decrypt.
  defp key_info(receiver, sender),
    do: <<"WebPush: info", 0, receiver::binary, sender::binary>>

  # HKDF (RFC 5869) at the two lengths this needs, both under one hash block,
  # so the expand step is a single iteration with the `0x01` counter.
  defp hkdf(salt, ikm, info, length) when length <= @sha256_bytes do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)

    :hmac
    |> :crypto.mac(:sha256, prk, <<info::binary, 1>>)
    |> binary_part(0, length)
  end

  defp validate(%{p256dh: p256dh, auth: auth}, plaintext) do
    cond do
      not is_binary(p256dh) or byte_size(p256dh) != @public_key_bytes ->
        {:error, {:invalid_key, :p256dh}}

      # An uncompressed point, which is the only form the browser emits.
      # `compute_key/4` would accept a compressed one, but nothing produces it
      # and admitting it here would mean the length check above proves nothing.
      not match?(<<4, _rest::binary>>, p256dh) ->
        {:error, {:invalid_key, :p256dh}}

      not is_binary(auth) or byte_size(auth) != @auth_secret_bytes ->
        {:error, {:invalid_key, :auth}}

      byte_size(plaintext) > @max_plaintext ->
        {:error, {:payload_too_large, byte_size(plaintext), @max_plaintext}}

      true ->
        :ok
    end
  end

  defp validate(_keys, _plaintext), do: {:error, {:invalid_key, :missing}}
end
