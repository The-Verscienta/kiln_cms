defmodule KilnCMS.Federation.HttpSignatureTest do
  @moduledoc """
  HTTP Signatures (#491) — the only thing standing between a site's follower
  list and anyone who can send it a POST.

  The round-trip tests matter less than the rejection tests: a signature scheme
  that verifies valid requests but also verifies invalid ones is worse than
  none, because it looks like authentication.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Federation.HttpSignature
  alias KilnCMS.Keys

  @url "https://remote.example/users/alice/inbox"
  @path "/users/alice/inbox"
  @key_id "https://kiln.example/actor#main-key"

  setup_all do
    private_pem = Keys.generate_rsa_pem()
    {:ok, private_key} = Keys.rsa_private_key(private_pem)

    %{private_pem: private_pem, public_pem: Keys.rsa_public_key_pem(private_key)}
  end

  defp signature_header(covered),
    do:
      "keyId=" <>
        inspect("k") <>
        ",algorithm=" <>
        inspect("rsa-sha256") <>
        ",headers=" <> inspect(covered) <> ",signature=" <> inspect("AAAA")

  defp follow_body(actor \\ "https://remote.example/users/alice"),
    do: Jason.encode!(%{"type" => "Follow", "actor" => actor})

  # `sign/4` deliberately omits `host` — `KilnCMS.SafeFetch` appends the real
  # one, and a second would make the signed value ambiguous. So the bytes that
  # reach the wire carry it, and a verifier that never sees it rebuilds a
  # different signing string. Adding it here is simulating the transport, not
  # working around the assertion.
  defp on_the_wire(headers), do: headers ++ [{"host", "remote.example"}]

  # What `sign/4` itself returns.
  defp sign!(body, ctx, opts \\ []) do
    {:ok, headers} =
      HttpSignature.sign(@url, @key_id, body, [private_key_pem: ctx.private_pem] ++ opts)

    headers
  end

  # Those headers as a verifier would actually receive them.
  defp signed(body, ctx, opts \\ []), do: body |> sign!(ctx, opts) |> on_the_wire()

  describe "signing" do
    test "produces the headers a fediverse server expects", ctx do
      headers = sign!(follow_body(), ctx)
      names = headers |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      assert names == ~w(content-type date digest signature)

      signature = headers |> List.keyfind("signature", 0) |> elem(1)
      assert signature =~ "keyId=" <> inspect(@key_id)
      assert signature =~ "algorithm=" <> inspect("rsa-sha256")
      assert signature =~ "headers=" <> inspect("(request-target) host date digest")
    end

    test "the digest is over the exact body bytes", ctx do
      body = follow_body()
      digest = ctx |> then(&sign!(body, &1)) |> List.keyfind("digest", 0) |> elem(1)

      assert digest == "SHA-256=" <> Base.encode64(:crypto.hash(:sha256, body))
    end

    # SafeFetch appends the real hostname itself; a second `host` header would
    # leave the signed value ambiguous.
    test "does not emit a host header of its own", ctx do
      refute ctx |> then(&sign!("{}", &1)) |> List.keyfind("host", 0)
    end

    test "reports a missing or unusable key rather than signing with nothing" do
      assert {:error, message} = HttpSignature.sign(@url, @key_id, "{}", [])
      assert message =~ "no signing key"

      assert {:error, message} =
               HttpSignature.sign(@url, @key_id, "{}", private_key_pem: "not a pem")

      assert message =~ "unusable signing key"
    end
  end

  describe "verifying" do
    test "a signature this module produced round-trips", ctx do
      body = follow_body()

      assert :ok =
               HttpSignature.verify("post", @path, signed(body, ctx), body, ctx.public_pem)
    end

    test "an unsigned request is refused", ctx do
      assert {:error, message} =
               HttpSignature.verify("post", @path, [{"date", "x"}], "{}", ctx.public_pem)

      assert message =~ "missing signature"
    end

    # The whole point: the signature must be worthless against bytes it did not
    # cover, or a proxy could swap the payload under a valid header.
    test "a tampered body is refused even with an intact signature", ctx do
      headers = signed(follow_body(), ctx)

      assert {:error, message} =
               HttpSignature.verify(
                 "post",
                 @path,
                 headers,
                 Jason.encode!(%{"type" => "Delete"}),
                 ctx.public_pem
               )

      assert message =~ "digest does not match"
    end

    test "a signature from a different key is refused", ctx do
      other_pem = Keys.generate_rsa_pem()
      {:ok, other_key} = Keys.rsa_private_key(other_pem)
      body = follow_body()

      assert {:error, message} =
               HttpSignature.verify(
                 "post",
                 @path,
                 signed(body, ctx),
                 body,
                 Keys.rsa_public_key_pem(other_key)
               )

      assert message =~ "does not verify"
    end

    test "a signature over a different path is refused", ctx do
      body = follow_body()

      assert {:error, message} =
               HttpSignature.verify(
                 "post",
                 "/some/other/inbox",
                 signed(body, ctx),
                 body,
                 ctx.public_pem
               )

      assert message =~ "does not verify"
    end

    # A captured request must not be replayable forever. The window is what
    # bounds it, since phase 1 has no nonce store.
    test "a stale date is refused", ctx do
      body = follow_body()
      stale = DateTime.utc_now() |> DateTime.add(-3600, :second) |> HttpSignature.http_date()

      assert {:error, message} =
               HttpSignature.verify(
                 "post",
                 @path,
                 signed(body, ctx, date: stale),
                 body,
                 ctx.public_pem
               )

      assert message =~ "outside the accepted window"
    end

    test "a future date beyond the window is refused too", ctx do
      body = follow_body()
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> HttpSignature.http_date()

      assert {:error, _message} =
               HttpSignature.verify(
                 "post",
                 @path,
                 signed(body, ctx, date: future),
                 body,
                 ctx.public_pem
               )
    end

    # The signature must COVER the request, not merely exist. Each of these is a
    # header whose absence from the signed set breaks a specific property.
    for {covered, missing} <- [
          {"host date digest", "(request-target)"},
          {"(request-target) date digest", "host"},
          {"(request-target) host digest", "date"},
          {"(request-target) host date", "digest"}
        ] do
      test "a signature not covering #{missing} is refused", ctx do
        headers = [
          {"signature", signature_header(unquote(covered))},
          {"date", HttpSignature.http_date()},
          {"digest", "SHA-256=" <> Base.encode64(:crypto.hash(:sha256, "{}"))}
        ]

        assert {:error, message} =
                 HttpSignature.verify("post", @path, headers, "{}", ctx.public_pem)

        assert message =~ "does not cover"
        assert message =~ unquote(missing)
      end
    end

    # The attack the coverage floor exists for. An attacker who captures any
    # signed request from an actor — from a relay, a proxy, a log — replays it
    # with a body of their choosing and a freshly computed Digest. Without
    # `digest` in the signed set the signing string is unchanged, so the
    # signature still verifies and the substituted activity would execute as
    # that actor.
    test "a captured signature cannot be replayed over a substituted body", ctx do
      substituted = Jason.encode!(%{"type" => "Delete", "actor" => "https://remote.example/x"})

      headers = [
        {"signature", signature_header("date")},
        {"date", HttpSignature.http_date()},
        {"digest", "SHA-256=" <> Base.encode64(:crypto.hash(:sha256, substituted))}
      ]

      assert {:error, message} =
               HttpSignature.verify("post", @path, headers, substituted, ctx.public_pem)

      assert message =~ "does not cover"
    end

    test "a malformed signature header is refused rather than raising", ctx do
      headers = [{"signature", "garbage"}, {"date", HttpSignature.http_date()}]

      assert {:error, _message} =
               HttpSignature.verify("post", @path, headers, "{}", ctx.public_pem)
    end
  end

  describe "key_id/1" do
    test "reads the claimed key without verifying anything", ctx do
      assert {:ok, @key_id} = HttpSignature.key_id(signed("{}", ctx))
    end

    test "refuses a request with no signature" do
      assert {:error, _message} = HttpSignature.key_id([])
    end
  end

  test "http_date/1 emits an IMF-fixdate" do
    assert HttpSignature.http_date(~U[2026-08-07 09:05:00Z]) == "Fri, 07 Aug 2026 09:05:00 GMT"
  end
end
