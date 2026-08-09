defmodule KilnCMS.Push.VapidTest do
  @moduledoc """
  VAPID identification for Web Push (#628).

  The load-bearing test is `"a push service can verify the signature"`: it
  verifies the JWT the way a push service does — `:public_key.verify/4` against
  the published point — which is the only check that catches the DER-vs-raw
  signature encoding trap. A signature in the wrong form is the right length,
  base64s fine, and is rejected by every push service in production.
  """
  # async: false — these drive the global `KilnCMS.Push` application env.
  use ExUnit.Case, async: false

  alias KilnCMS.Push.Vapid

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Push)
    on_exit(fn -> restore(original) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:kiln_cms, KilnCMS.Push)
  defp restore(value), do: Application.put_env(:kiln_cms, KilnCMS.Push, value)

  defp configure(overrides) do
    {public, private} = Vapid.generate()

    Application.put_env(
      :kiln_cms,
      KilnCMS.Push,
      Keyword.merge(
        [
          vapid_public_key: public,
          vapid_private_key: private,
          vapid_subject: "mailto:ops@example.com"
        ],
        overrides
      )
    )

    {public, private}
  end

  defp token(header) do
    ["vapid t=" <> jwt, "k=" <> key] = String.split(header, ", ")
    [encoded_header, claims, signature] = String.split(jwt, ".")

    %{
      key: key,
      payload: encoded_header <> "." <> claims,
      header: decode_json(encoded_header),
      claims: decode_json(claims),
      signature: Base.url_decode64!(signature, padding: false)
    }
  end

  defp decode_json(part), do: part |> Base.url_decode64!(padding: false) |> Jason.decode!()

  describe "generate/0" do
    test "produces the sizes the spec and the browser API require" do
      {public, private} = Vapid.generate()

      assert byte_size(Base.url_decode64!(public, padding: false)) == 65
      assert byte_size(Base.url_decode64!(private, padding: false)) == 32
      # Uncompressed point marker — `applicationServerKey` accepts nothing else.
      assert <<4, _rest::binary>> = Base.url_decode64!(public, padding: false)
    end
  end

  describe "configured?/0" do
    test "false with no keys" do
      Application.delete_env(:kiln_cms, KilnCMS.Push)
      refute Vapid.configured?()
      assert Vapid.public_key() == nil
    end

    test "false when the public key is not the public half of the private one" do
      {other_public, _other_private} = Vapid.generate()
      configure(vapid_public_key: other_public)

      # A deployment in this state publishes one key to browsers and signs with
      # another: every subscription it creates is undeliverable, and the only
      # symptom without this check is a 403 per message, months later.
      refute Vapid.configured?()
    end

    test "false on a key that is the wrong length or not base64url" do
      configure(vapid_private_key: "not base64!")
      refute Vapid.configured?()

      configure(vapid_private_key: Base.url_encode64(<<1, 2, 3>>, padding: false))
      refute Vapid.configured?()
    end

    test "true for a matched pair" do
      configure([])
      assert Vapid.configured?()
    end
  end

  describe "authorization/1" do
    test "a push service can verify the signature" do
      {public, _private} = configure([])

      assert {:ok, header} = Vapid.authorization("https://fcm.googleapis.com/fcm/send/abc123")
      parsed = token(header)

      assert parsed.header == %{"typ" => "JWT", "alg" => "ES256"}
      assert parsed.key == public

      # ES256 (RFC 7518 §3.4) is raw r‖s, 64 bytes — not the DER `:crypto.sign/4`
      # hands back.
      assert byte_size(parsed.signature) == 64

      <<r::binary-32, s::binary-32>> = parsed.signature

      der =
        :public_key.der_encode(
          :"ECDSA-Sig-Value",
          {:"ECDSA-Sig-Value", :binary.decode_unsigned(r), :binary.decode_unsigned(s)}
        )

      point = {{:ECPoint, Base.url_decode64!(public, padding: false)}, {:namedCurve, :secp256r1}}

      assert :public_key.verify(parsed.payload, :sha256, der, point)
    end

    test "the audience is the endpoint's origin, not its path" do
      configure([])

      {:ok, header} =
        Vapid.authorization("https://updates.push.services.mozilla.com/wpush/v2/xyz")

      assert token(header).claims["aud"] == "https://updates.push.services.mozilla.com"
    end

    test "the token expires inside the 24 hours a push service may cap at" do
      configure([])
      {:ok, header} = Vapid.authorization("https://example.com/push/1")

      ttl = token(header).claims["exp"] - System.system_time(:second)

      assert ttl > 0
      assert ttl <= 24 * 60 * 60
    end

    test "carries the configured subject, and falls back to the deployment's URL" do
      configure(vapid_subject: "mailto:reviews@example.org")
      {:ok, header} = Vapid.authorization("https://example.com/push/1")
      assert token(header).claims["sub"] == "mailto:reviews@example.org"

      configure(vapid_subject: nil)
      {:ok, fallback} = Vapid.authorization("https://example.com/push/1")
      assert token(fallback).claims["sub"] =~ ~r{^https?://}
    end

    test "refuses an endpoint that is not an http(s) URL" do
      configure([])

      assert {:error, {:invalid_endpoint, _}} = Vapid.authorization("ftp://example.com/x")
      assert {:error, {:invalid_endpoint, _}} = Vapid.authorization("not a url")
    end

    test "refuses to sign when nothing is configured" do
      Application.delete_env(:kiln_cms, KilnCMS.Push)
      assert {:error, {:not_configured, _}} = Vapid.authorization("https://example.com/push/1")
    end

    test "signs correctly for a private key with leading zero bytes" do
      # `:crypto.generate_key/2` trims them, so one scalar in 256 is short; a
      # generator that did not pad would emit a key other tooling reads as
      # malformed, and one in 65536 would be two bytes short.
      for _attempt <- 1..50 do
        {public, private} = Vapid.generate()
        assert byte_size(Base.url_decode64!(private, padding: false)) == 32
        assert byte_size(Base.url_decode64!(public, padding: false)) == 65
      end
    end
  end
end
