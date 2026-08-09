defmodule KilnCMS.Push.EncryptionTest do
  @moduledoc """
  Web Push payload encryption (#628).

  The first test is the one that matters: RFC 8291 §5 publishes a complete
  worked example — subscription keys, salt, server key pair and the exact
  expected output — and this replays it byte for byte. Hand-written crypto that
  is not checked against a published vector is a guess, and the failure mode is
  silent (a push service accepts the request, the browser cannot decrypt, and
  nothing anywhere reports it).
  """
  use ExUnit.Case, async: true

  import Bitwise, only: []

  alias KilnCMS.Push.Encryption

  describe "RFC 8291 §5" do
    # https://www.rfc-editor.org/rfc/rfc8291#section-5
    @plaintext "When I grow up, I want to be a watermelon"
    @p256dh Base.url_decode64!(
              "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
              padding: false
            )
    @auth Base.url_decode64!("BTBZMqHH6r4Tts7J_aSIgg", padding: false)
    @salt Base.url_decode64!("DGv6ra1nlYgDCS1FRnbzlw", padding: false)
    @server_public Base.url_decode64!(
                     "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8",
                     padding: false
                   )
    @server_private Base.url_decode64!("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw",
                      padding: false
                    )
    @expected Base.url_decode64!(
                "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN",
                padding: false
              )

    test "reproduces the published ciphertext exactly" do
      assert {:ok, body} =
               Encryption.encrypt(@plaintext, %{p256dh: @p256dh, auth: @auth},
                 salt: @salt,
                 key_pair: {@server_public, @server_private}
               )

      assert body == @expected
    end

    test "the header carries the salt, record size and the sender's public key" do
      {:ok, body} =
        Encryption.encrypt(@plaintext, %{p256dh: @p256dh, auth: @auth},
          salt: @salt,
          key_pair: {@server_public, @server_private}
        )

      assert <<salt::binary-16, record_size::unsigned-big-32, key_length::unsigned-8,
               public::binary-65, _ciphertext::binary>> = body

      assert salt == @salt
      assert record_size == 4096
      assert key_length == 65
      assert public == @server_public
    end
  end

  describe "encrypt/3" do
    setup do
      {public, _private} = Encryption.generate_key_pair()
      %{keys: %{p256dh: public, auth: :crypto.strong_rand_bytes(16)}}
    end

    test "a fresh salt per call, so the same plaintext never encrypts the same way", %{
      keys: keys
    } do
      {:ok, first} = Encryption.encrypt("same", keys)
      {:ok, second} = Encryption.encrypt("same", keys)

      refute first == second
    end

    test "refuses a p256dh that is not a 65-byte uncompressed point", %{keys: keys} do
      assert {:error, {:invalid_key, :p256dh}} =
               Encryption.encrypt("x", %{keys | p256dh: :crypto.strong_rand_bytes(64)})

      # Right length, wrong form: a compressed point would be accepted by
      # `compute_key/4`, which would make the length check prove nothing.
      compressed = <<2>> <> binary_part(keys.p256dh, 1, 64)

      assert {:error, {:invalid_key, :p256dh}} =
               Encryption.encrypt("x", %{keys | p256dh: compressed})
    end

    test "refuses an auth secret that is not 16 bytes", %{keys: keys} do
      # The killer case: a short secret silently changes the key schedule and
      # produces a payload the browser drops without telling anyone.
      assert {:error, {:invalid_key, :auth}} =
               Encryption.encrypt("x", %{keys | auth: :crypto.strong_rand_bytes(12)})
    end

    test "refuses keys that are missing entirely" do
      assert {:error, {:invalid_key, :missing}} = Encryption.encrypt("x", %{})
    end

    test "refuses a plaintext that will not fit one record", %{keys: keys} do
      max = Encryption.max_plaintext_bytes()

      assert {:ok, body} = Encryption.encrypt(String.duplicate("a", max), keys)

      # The advertised maximum must produce a BODY inside the 4096-byte cap push
      # services enforce — not just a record inside it. Counting only the record
      # overstated the limit by the 86-byte header, so a caller that trusted it
      # got a 413 after this function said the size was fine.
      assert byte_size(body) <= 4096

      assert {:error, {:payload_too_large, _size, ^max}} =
               Encryption.encrypt(String.duplicate("a", max + 1), keys)
    end

    test "an off-curve point is an error, not a raise", %{keys: keys} do
      # 65 bytes and 0x04-prefixed, so it passes every cheap check — but it is
      # not on the curve, and `:crypto.compute_key/4` raises for it. Escaping
      # the ok/error contract means the caller's else never runs and the
      # poisoned row is never pruned: five Oban attempts and five Sentry
      # reports, per notification, forever.
      <<4, x::binary-32, y::binary-32>> = keys.p256dh
      <<first, rest::binary>> = y
      off_curve = <<4, x::binary, Bitwise.bxor(first, 1), rest::binary>>

      assert {:error, {:invalid_key, :p256dh, _detail}} =
               Encryption.encrypt("x", %{keys | p256dh: off_curve})
    end
  end
end
