defmodule KilnCMS.Billing.Providers.Stripe.SignatureTest do
  @moduledoc """
  Webhook signature verification. Pure — no DataCase, no HTTP.

  These assertions are the boundary between "a signed event from our payment
  provider" and "arbitrary bytes from the internet on a CSRF-free public route",
  so every malformed-input case asserts an `{:error, _}` rather than a raise: a
  crash here would be a 500 on an unauthenticated endpoint, and the provider
  would retry it for days.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Billing.Providers.Stripe.Signature

  @secret "whsec_test_secret"
  @body ~s({"id":"evt_123","type":"checkout.session.completed"})
  @now 1_700_000_000

  defp header(timestamp, signature), do: "t=#{timestamp},v1=#{signature}"

  defp valid_header(timestamp \\ @now, body \\ @body),
    do: header(timestamp, Signature.sign(timestamp, body, @secret))

  defp verify(body, header, opts \\ []),
    do: Signature.verify(body, header, @secret, Keyword.put_new(opts, :now, @now))

  describe "valid signatures" do
    test "verifies and returns the decoded event" do
      assert {:ok, event} = verify(@body, valid_header())
      assert event["id"] == "evt_123"
      assert event["type"] == "checkout.session.completed"
    end

    test "accepts a rotation candidate when an earlier v1 is garbage" do
      good = Signature.sign(@now, @body, @secret)
      rotating = "t=#{@now},v1=#{String.duplicate("0", 64)},v1=#{good}"

      assert {:ok, _event} = verify(@body, rotating)
    end

    test "ignores a v0 signature alongside a valid v1" do
      good = Signature.sign(@now, @body, @secret)

      assert {:ok, _event} = verify(@body, "t=#{@now},v0=deadbeef,v1=#{good}")
    end

    test "is case-insensitive about the hex candidate" do
      upper = @now |> Signature.sign(@body, @secret) |> String.upcase()

      assert {:ok, _event} = verify(@body, header(@now, upper))
    end
  end

  describe "rejected signatures" do
    test "a body mutated by one byte fails" do
      # The raw-body assertion: re-encoding or altering a single byte must break
      # verification. This is what `KilnCMSWeb.Plugs.RawBodyReader` exists for.
      tampered = String.replace(@body, "evt_123", "evt_124")

      assert {:error, :invalid_signature} = verify(tampered, valid_header())
    end

    test "a signature over a different body fails" do
      other = Signature.sign(@now, ~s({"id":"evt_999"}), @secret)

      assert {:error, :invalid_signature} = verify(@body, header(@now, other))
    end

    test "a signature made with a different secret fails" do
      wrong = "t=#{@now},v1=#{Signature.sign(@now, @body, "whsec_other")}"

      assert {:error, :invalid_signature} = verify(@body, wrong)
    end
  end

  describe "timestamp tolerance" do
    test "a stale timestamp is rejected" do
      stale = @now - 400

      assert {:error, :timestamp_out_of_tolerance} =
               verify(@body, valid_header(stale))
    end

    test "the same event passes with a widened tolerance" do
      stale = @now - 400

      assert {:ok, _event} = verify(@body, valid_header(stale), tolerance: 600)
    end

    test "a far-future timestamp is rejected too" do
      # Not just staleness: a forged or clock-skewed future `t` must not buy an
      # unbounded replay window.
      future = @now + 400

      assert {:error, :timestamp_out_of_tolerance} =
               verify(@body, valid_header(future))
    end

    test "a timestamp exactly at the tolerance edge is accepted" do
      assert {:ok, _event} = verify(@body, valid_header(@now - 300))
    end
  end

  describe "malformed input never raises" do
    for {label, value} <- [
          {"nil", nil},
          {"empty", ""},
          {"no t component", "v1=abcdef"},
          {"no v1 component", "t=1700000000"},
          {"non-integer t", "t=notanumber,v1=abcdef"},
          {"empty v1", "t=1700000000,v1="},
          {"garbage", "totally-not-a-signature"},
          {"only commas", ",,,"}
        ] do
      test "#{label} is a malformed-signature error" do
        assert {:error, :malformed_signature} = verify(@body, unquote(Macro.escape(value)))
      end
    end

    test "an odd-length hex candidate is a signature error, not a crash" do
      # `:crypto.hash_equals/2` raises on a size mismatch, so a truncated
      # candidate must be length-checked before comparison.
      assert {:error, :invalid_signature} = verify(@body, header(@now, "abc"))
    end

    test "an over-long candidate is a signature error, not a crash" do
      assert {:error, :invalid_signature} =
               verify(@body, header(@now, String.duplicate("a", 200)))
    end
  end

  describe "payload decoding" do
    test "a correctly signed non-JSON body is a payload error" do
      body = "not json at all"

      assert {:error, :malformed_payload} = verify(body, valid_header(@now, body))
    end

    test "a correctly signed JSON array is a payload error" do
      # Events are objects; an array would break every downstream match.
      body = "[1,2,3]"

      assert {:error, :malformed_payload} = verify(body, valid_header(@now, body))
    end

    test "an invalid signature over invalid JSON reports the signature, not the payload" do
      # Verification must happen BEFORE decoding, so unauthenticated bytes never
      # reach the decoder.
      assert {:error, :invalid_signature} = verify("not json", valid_header())
    end
  end
end
